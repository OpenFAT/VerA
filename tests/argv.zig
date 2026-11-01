//! The degenerate-argv table: every flag `vera --help` documents, crossed
//! with the degenerate values a command line can carry, through the real
//! `vera` process -> one BAD line per row that misbehaves, exit 1 on any.
//!
//!   argv <vera> <scratch dir>        (`zig build test-argv`, and in `test`)
//!
//! The oracle is the process itself and `src/main.zig`'s exit contract: 0 on
//! success, 1 on a diagnosed error, 2 on a usage error, each nonzero exit
//! with its reason on stderr. A row is BAD when vera dies on a signal (an
//! assertion's abort, a panic), exits outside {0, 1, 2}, prints a panic, exits
//! nonzero with nothing on stderr, or runs past `timeout`. The class is
//! `valuedKey`'s `vera ""` abort and `simTree`'s `--work-dir ""` one: an
//! assertion on argv, which is input.
//!
//! The flags come from `--help` (and its `usage:` lines), so a new flag is in
//! the table the day it is documented. Values: "", "-", "=", the longest
//! argument the OS passes (`big`), a missing value and the flag repeated. A
//! NUL byte cannot reach argv (execve's strings end at the first one), so
//! that case is "" again and is not a row. Each line runs on no input, an
//! empty `.va`, a resistor `.va` and a one-module `.v`; a flag that builds
//! with `zig` gets only the inputs that stop before the build. On the empty
//! `.va` each line runs again after `--emit-so`, which carries every value
//! on to the engine tree's write.
//!
//! A known failure is a row of `known` with its reason; a known row that
//! passes is an XPASS and fails the run, as does a `known` row that names no
//! row of the table.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Rows that misbehave on a real bug, with the bug. Empty is the goal.
const known: []const struct { row: []const u8, why: []const u8 } = &.{};

/// The longest value the OS passes, less room for a `--name=` and the rest of
/// the line: Linux's MAX_ARG_STRLEN is 128 KiB per argument (so a 1 MiB value
/// cannot be passed), and Windows holds the whole command line to 32767 UTF-16
/// units (CreateProcessW), the paths of vera and its input included.
const big_len = if (builtin.os.tag == .windows) 24 * 1024 else 128 * 1024 - 1 - 64; // os: Windows' command-line limit

/// A row that runs longer than this hangs.
const timeout_s = 60;

/// The inputs a line runs on, written into the scratch dir. Null: no input.
const inputs = [_]?struct { name: []const u8, text: []const u8, builds: bool }{
    null,
    .{ .name = "e.va", .text = "", .builds = true },
    .{ .name = "r.va", .text = "`include \"disciplines.vams\"\nmodule r(p, n);\n  inout p, n;\n  electrical p, n;\n  analog I(p, n) <+ V(p, n) / 1k;\nendmodule\n", .builds = false },
    .{ .name = "t.v", .text = "module t;\nendmodule\n", .builds = false },
};

/// The flags that start a `zig` build once their input analyses: a row is
/// about argv, not a build, so they run only on inputs that stop before one.
const builders = [_][]const u8{ "--check", "--emit-so", "--emit-osdi", "--emit-exe", "--run" };

const Flag = struct {
    text: []const u8,
    form: enum { switch_, separate, inline_ },
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const vera = args.next() orelse return error.MissingVera;
    const dir = args.next() orelse return error.MissingScratchDir;

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    try Io.Dir.cwd().createDirPath(io, dir);
    for (inputs) |in| if (in) |f| try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, f.name }), .data = f.text });

    const help = try std.process.run(arena, io, .{ .argv = &.{ vera, "--help" } });
    const flags = try flagsOf(arena, help.stdout);
    if (flags.len < 40) {
        try w.print("argv: `vera --help` documents {d} flags; the table needs its option lines\n", .{flags.len});
        return 1;
    }
    const big = try arena.alloc(u8, big_len);
    @memset(big, 'a');
    const lines = try linesOf(arena, flags, big);

    var table: std.ArrayList(Row) = .empty;
    for (lines) |line| for (inputs) |in| for ([_]bool{ false, true }) |deep| {
        if (in) |f| if (!f.builds and buildsAny(line)) continue;
        // `--emit-so` first takes every value on to `contractTree`, which
        // writes under `--work-dir` before the input is analysed.
        if (deep and !(if (in) |f| f.builds else false)) continue;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, vera);
        if (deep) try argv.append(arena, "--emit-so");
        try argv.appendSlice(arena, line);
        if (in) |f| try argv.append(arena, f.name);
        try table.append(arena, .{ .argv = argv.items, .name = try rowName(arena, argv.items[1..], big) });
    };

    // The rows share nothing but the scratch dir's inputs, which none writes.
    var pool: Pool = .{ .arena = arena, .io = io, .dir = dir, .rows = table.items };
    var group: Io.Group = .init;
    const hands = @max(1, std.Thread.getCpuCount() catch 1);
    for (0..hands) |_| group.concurrent(io, Pool.work, .{&pool}) catch break;
    pool.work();
    try group.await(io);
    if (pool.failed) |e| return e;

    var bad: usize = 0;
    const seen = try arena.alloc(bool, known.len);
    @memset(seen, false);
    for (table.items) |row| {
        var marked: ?[]const u8 = null;
        for (known, seen) |k, *s| if (std.mem.eql(u8, k.row, row.name)) {
            s.* = true;
            marked = k.why;
        };
        if (row.why) |reason| {
            if (marked) |m| {
                try w.print("XFAIL {s}: {s} (known: {s})\n", .{ row.name, reason, m });
                continue;
            }
            try w.print("BAD {s}: {s}\n", .{ row.name, reason });
            bad += 1;
        } else if (marked != null) {
            try w.print("BAD {s}: XPASS, delete its `known` row\n", .{row.name});
            bad += 1;
        }
    }
    for (known, seen) |row, s| if (!s) {
        try w.print("BAD {s}: `known` names no row of the table\n", .{row.row});
        bad += 1;
    };
    // The census on stdout: `zig build` prints a passing step's stderr as noise.
    var out_buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const census = if (bad == 0) &stdout.interface else w;
    try census.print("argv: {d} rows over {d} flags, {d} BAD\n", .{ table.items.len, flags.len, bad });
    try census.flush();
    return if (bad == 0) 0 else 1;
}

/// One command line and, once run, why it broke the contract (null: it held).
const Row = struct { argv: []const []const u8, name: []const u8, why: ?[]const u8 = null };

/// The rows and their cursor: one row per take, any number of hands.
const Pool = struct {
    arena: Allocator,
    io: Io,
    dir: []const u8,
    rows: []Row,
    next: std.atomic.Value(usize) = .init(0),
    /// A row that could not be run at all (spawn failed): the run's error.
    failed: ?anyerror = null,

    fn work(pool: *Pool) void {
        while (true) {
            const i = pool.next.fetchAdd(1, .monotonic);
            if (i >= pool.rows.len) return;
            const row = &pool.rows[i];
            row.why = judge(pool.arena, pool.io, row.argv, pool.dir) catch |e| {
                pool.failed = e;
                return;
            };
        }
    }
};

/// Why the run of `argv` (in `cwd`) breaks the exit contract, or null.
fn judge(arena: Allocator, io: Io, argv: []const []const u8, cwd: []const u8) !?[]const u8 {
    const r = std.process.run(arena, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
    }) catch |e| switch (e) {
        error.Timeout => return try arena.print("ran past {d} s", .{timeout_s}),
        else => return e,
    };
    const code = switch (r.term) {
        .exited => |c| c,
        else => return try arena.print("did not exit: {any}\n{s}", .{ r.term, head(r.stderr) }),
    };
    if (std.mem.find(u8, r.stderr, "panic") != null or std.mem.find(u8, r.stderr, "reached unreachable") != null)
        return try arena.print("exit {d} with a panic\n{s}", .{ code, head(r.stderr) });
    if (code > 2) return try arena.print("exit {d}, outside 0, 1, 2\n{s}", .{ code, head(r.stderr) });
    // `cli/lsp.zig`: a session whose input closes before `exit` ends 1, silently.
    const lsp_closed = code == 1 and for (argv) |a| {
        if (std.mem.eql(u8, a, "--lsp")) break true;
    } else false;
    if (code != 0 and !lsp_closed and std.mem.trim(u8, r.stderr, " \n").len == 0) return try arena.print("exit {d} with nothing on stderr", .{code});
    return null;
}

/// The first 2 KiB of `text`: a panic's trace is long, its head is enough.
fn head(text: []const u8) []const u8 {
    return text[0..@min(text.len, 2048)];
}

/// Every flag the help text names, once, in first-seen order.
fn flagsOf(arena: Allocator, help: []const u8) ![]const Flag {
    var out: std.ArrayList(Flag) = .empty;
    var lines = std.mem.splitScalar(u8, help, '\n');
    while (lines.next()) |line| {
        const usage = std.mem.startsWith(u8, line, "usage:") or std.mem.startsWith(u8, line, "       vera");
        if (!usage and !std.mem.startsWith(u8, line, "  -")) continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        while (words.next()) |word| {
            if (word[0] != '-') {
                if (usage) continue else break; // an option line's first word is its flag
            }
            const after = line[words.index..];
            // `-o PATH`: one space, then the value's name in capitals.
            const separate = after.len >= 2 and after[0] == ' ' and std.ascii.isUpper(after[1]);
            // `--allow/--warn=CODE`: the `=` is every alternative's.
            const inline_ = std.mem.findScalar(u8, word, '=') != null;
            var alts = std.mem.splitAny(u8, word, "|/");
            while (alts.next()) |alt| {
                if (alt.len < 2 or alt[0] != '-') continue;
                const name = alt[0 .. std.mem.findScalar(u8, alt, '=') orelse alt.len];
                const flag: Flag = if (inline_)
                    .{ .text = try std.mem.concat(arena, u8, &.{ name, "=" }), .form = .inline_ }
                else
                    .{ .text = name, .form = if (separate) .separate else .switch_ };
                for (out.items) |f| {
                    if (std.mem.eql(u8, f.text, flag.text)) break;
                } else try out.append(arena, flag);
            }
            if (!usage) break;
        }
    }
    return out.items;
}

/// Each flag's degenerate command lines (without the input).
fn linesOf(arena: Allocator, flags: []const Flag, big: []const u8) ![]const []const []const u8 {
    var out: std.ArrayList([]const []const u8) = .empty;
    const values = [_][]const u8{ "", "-", "=", big };
    // A degenerate positional on its own: `vera ""` aborted once.
    for (values) |v| try out.append(arena, try arena.dupe([]const u8, &.{v}));
    for (flags) |f| switch (f.form) {
        .inline_ => {
            for (values) |v| try out.append(arena, try arena.dupe([]const u8, &.{try std.mem.concat(arena, u8, &.{ f.text, v })}));
            const x = try std.mem.concat(arena, u8, &.{ f.text, "x" });
            try out.append(arena, try arena.dupe([]const u8, &.{ x, x }));
        },
        .separate => {
            try out.append(arena, try arena.dupe([]const u8, &.{f.text}));
            for (values) |v| try out.append(arena, try arena.dupe([]const u8, &.{ f.text, v }));
            try out.append(arena, try arena.dupe([]const u8, &.{ f.text, "x", f.text, "x" }));
        },
        .switch_ => {
            try out.append(arena, try arena.dupe([]const u8, &.{ f.text, f.text }));
            try out.append(arena, try arena.dupe([]const u8, &.{try std.mem.concat(arena, u8, &.{ f.text, "=" })}));
            try out.append(arena, try arena.dupe([]const u8, &.{try std.mem.concat(arena, u8, &.{ f.text, "=", big })}));
            for (values) |v| try out.append(arena, try arena.dupe([]const u8, &.{ f.text, v }));
        },
    };
    return out.items;
}

fn buildsAny(line: []const []const u8) bool {
    for (line) |a| for (builders) |b| if (std.mem.eql(u8, a, b)) return true;
    return false;
}

/// `--work-dir "" e.va`: each argument as typed, `""` for an empty one and
/// `<big>` for `big` (or a `--name=` before it).
fn rowName(arena: Allocator, argv: []const []const u8, big: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |a, i| {
        if (i != 0) try out.append(arena, ' ');
        if (a.len == 0) try out.appendSlice(arena, "\"\"") //
        else if (std.mem.endsWith(u8, a, big)) {
            try out.appendSlice(arena, a[0 .. a.len - big.len]);
            try out.appendSlice(arena, "<big>");
        } else try out.appendSlice(arena, a);
    }
    return out.items;
}
