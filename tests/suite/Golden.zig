//! The `golden` mode: what the compiler SAYS about every fixture, snapshotted,
//! so a refactor can prove it changed nothing.
//!
//!   zig build suite -- golden before        # on the pre-change tree
//!   zig build suite -- golden after         # ... the change ...
//!   zig build suite -- golden diff          # before vs after; exit 1 on a difference
//!   zig build suite -- golden diff A B      # two tags, or two snapshot directories
//!   zig build suite -- golden before ch05   # only fixture paths holding `ch05`
//!
//! A snapshot is `.zig-cache/vera-golden/<tag>/`, per `.va` and `.v` under
//! the fixture root (the suite's `tests/`, not its `netlist/`) and under VerA's own
//! `tests/rtlil` and `tests/beh_verilog` (as `vera/<dir>/`, `own_dirs`):
//!
//!   <path>.txt           `vera --emit-zig` stdout, then a last line `exit=<code>`
//!   <path>.stderr        its stderr: the message text is held too, and vera
//!                        writes the device at offset 0, so one file would
//!                        lose the warnings
//!   <path>.verilog.txt   a `.va`: `vera --emit-verilog`, laid out as `.txt`
//!   <path>.verilog.stderr
//!   <path>.rtlil.txt     a `.v`: `vera --emit-rtlil`, laid out as `.txt`
//!   <path>.rtlil.stderr
//!   <path>.runner.txt    a `.va` with a `//!` line: the testbench runner
//!                        `tb.writeRunner` gives `--emit-exe` (`runner`)
//!   <path>.so/...        a `.va`: the tree `--emit-so` writes before `zig`
//!                        runs, `shim.zig` and the split device (`soTree`)
//!   <path>.vpi.so/...    the same tree with `vpi_contribs` on, as the VPI
//!                        host builds it: only its files that differ from
//!                        `.so/`'s (`vpiContribs`, `vpiShares`), so a path
//!                        only the VPI host reaches is snapshotted too
//!   <path>.program.txt   a `.v`: the executable root `--emit-exe` builds
//!                        (`digital.program`)
//!
//! The last three are made in-process through `vera`'s and `sim`'s API, not by
//! spawning. A kind that fails is `error=<name>` in its own file (a `.so` tree
//! is then `<path>.so.error.txt`), so it hides no other kind.
//!
//! Every file is written with the checkout's root cut out (`unrooted`), for
//! the suite's fixtures and VerA's own alike: the fixture's absolute path
//! reaches diagnostics, device and program text (`$fopen`, `$readmem`, the
//! fallback's `file_name`), so two worktrees' snapshots are equal byte for
//! byte. `diff` cuts it again, for snapshots an older tree wrote.
//!
//! Not a cacheable build step: the build graph cannot see fixture contents, so
//! a cached run would compare nothing (`build.zig`'s note on the `suite` step).

const Fixtures = @import("Fixtures.zig");
const std = @import("std");
const options = @import("suite_options");
const harness = Fixtures;
const vera = @import("vera");
const tb = @import("exe");
const zigbuild = @import("zigbuild");
const digital = @import("sim").digital;
/// The native emitter (src/codegen/digital/).
const native = @import("digital");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Args = std.process.Args.Iterator;

/// Dispatches `before`/`after`/any tag to `snapshot`, `diff` to `compare`.
pub fn run(init: std.process.Init, vera_exe: []const u8, args: *Args) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    const store = try std.fs.path.join(arena, &.{ options.repo_root, ".zig-cache", "vera-golden" });
    const word = args.next() orelse {
        try w.writeAll("usage: zig build suite -- golden <tag> | diff [<a> <b>]\n");
        return 2;
    };
    if (std.mem.eql(u8, word, "diff")) {
        const a = args.next() orelse "before";
        const b = args.next() orelse "after";
        return compare(arena, io, try snapDir(arena, store, a), try snapDir(arena, store, b), w);
    }
    return snapshot(gpa, io, arena, vera_exe, try std.fs.path.join(arena, &.{ store, word }), args.next(), w);
}

/// A tag names `.zig-cache/vera-golden/<tag>`; anything with a `/` is a path,
/// so a snapshot from another checkout can be compared.
fn snapDir(arena: Allocator, store: []const u8, arg: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, arg, '/') != null) return arg;
    return std.fs.path.join(arena, &.{ store, arg });
}

/// The work list and its cursor: one fixture per take, any number of hands.
const Pool = struct {
    io: Io,
    gpa: Allocator,
    vera: []const u8,
    out: []const u8,
    rels: []const []const u8,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(usize) = .init(0),

    fn work(pool: *Pool) void {
        while (true) {
            const k = pool.next.fetchAdd(1, .monotonic);
            if (k >= pool.rels.len) return;
            pool.one(pool.rels[k]) catch {
                _ = pool.failed.fetchAdd(1, .monotonic);
            };
        }
    }

    /// One fixture's files (the header lists them): `vera --emit-zig`, then
    /// the in-process kinds. The include path is the suite's `include/`
    /// (`harness.include_dir`) and the fixture's own directory. Only an I/O failure of the snapshot
    /// itself is returned; a kind's own failure is its `error=` file.
    fn one(pool: *Pool, rel: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(pool.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const io = pool.io;
        const src = try sourceOf(arena, rel);
        const base = try std.mem.concat(arena, u8, &.{ pool.out, "/", rel });
        const txt = try std.mem.concat(arena, u8, &.{ base, ".txt" });
        const err = try std.mem.concat(arena, u8, &.{ base, ".stderr" });
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(txt).?);
        const includes: []const []const u8 = &.{ harness.include_dir, std.fs.path.dirname(src).? };

        try pool.emit(arena, src, "--emit-zig", txt, err);

        const source = try readAll(io, arena, src);
        if (std.mem.endsWith(u8, rel, ".v")) {
            try pool.emit(arena, src, "--emit-rtlil", try std.mem.concat(arena, u8, &.{ base, ".rtlil.txt" }), try std.mem.concat(arena, u8, &.{ base, ".rtlil.stderr" }));
            const text = program(arena, io, src, includes, source) catch |e| try arena.print("error={t}\n", .{e});
            return save(io, arena, try std.mem.concat(arena, u8, &.{ base, ".program.txt" }), text);
        }
        try pool.emit(arena, src, "--emit-verilog", try std.mem.concat(arena, u8, &.{ base, ".verilog.txt" }), try std.mem.concat(arena, u8, &.{ base, ".verilog.stderr" }));
        if (harness.hasDirective(source)) {
            const text = runner(pool.gpa, arena, src, includes, source) catch |e| try arena.print("error={t}\n", .{e});
            try save(io, arena, try std.mem.concat(arena, u8, &.{ base, ".runner.txt" }), text);
        }
        const so = try std.mem.concat(arena, u8, &.{ base, ".so" });
        if (soTree(pool.gpa, io, arena, src, includes, source, so, .{})) |_| {
            for (try fileList(arena, io, so)) |p| {
                const path = try std.fs.path.join(arena, &.{ so, p });
                try save(io, arena, path, try readAll(io, arena, path));
            }
        } else |e| return save(io, arena, try std.mem.concat(arena, u8, &.{ so, ".error.txt" }), try arena.print("error={t}\n", .{e}));

        // The VPI host's tree: written whole, then cut to the files that differ.
        const vpi = try std.mem.concat(arena, u8, &.{ base, ".vpi.so" });
        if (soTree(pool.gpa, io, arena, src, includes, source, vpi, .{ .vpi_contribs = true })) |_| {
            for (try fileList(arena, io, vpi)) |p| {
                const path = try std.fs.path.join(arena, &.{ vpi, p });
                const plain = readAll(io, arena, try std.fs.path.join(arena, &.{ so, p })) catch "";
                const text = try unrooted(arena, try readAll(io, arena, path));
                if (std.mem.eql(u8, text, try unrooted(arena, plain)))
                    try Io.Dir.cwd().deleteFile(io, path)
                else
                    try save(io, arena, path, text);
            }
        } else |e| try save(io, arena, try std.mem.concat(arena, u8, &.{ vpi, ".error.txt" }), try arena.print("error={t}\n", .{e}));
    }

    /// `vera <flag>` on `src`: its stdout then a last line `exit=<code>` to
    /// `txt`, its stderr to `err`, both `unrooted`.
    fn emit(pool: *Pool, arena: Allocator, src: []const u8, flag: []const u8, txt: []const u8, err: []const u8) !void {
        const io = pool.io;
        const code: u32 = code: {
            const out_file = try Io.Dir.cwd().createFile(io, txt, .{});
            defer out_file.close(io);
            const err_file = try Io.Dir.cwd().createFile(io, err, .{});
            defer err_file.close(io);
            var child = try std.process.spawn(io, .{
                .argv = &.{
                    pool.vera,                  flag,                "--color=never",
                    "-I",                       harness.include_dir, "-I",
                    std.fs.path.dirname(src).?, src,
                },
                .cwd = .{ .path = options.repo_root },
                .stdin = .ignore,
                .stdout = .{ .file = out_file },
                .stderr = .{ .file = err_file },
            });
            // bash's `$?`: the exit code, or 128 + the signal.
            break :code switch (try child.wait(io)) {
                .exited => |c| c,
                .signal, .stopped => |s| 128 + @as(u32, @backingInt(s)),
                .unknown => |u| u,
            };
        };
        try save(io, arena, txt, try arena.print("{s}exit={d}\n", .{ try readAll(io, arena, txt), code }));
        try save(io, arena, err, try readAll(io, arena, err));
    }
};

fn readAll(io: Io, arena: Allocator, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
}

/// Writes `text` to `path` with the checkout's root cut out (`unrooted`).
fn save(io: Io, arena: Allocator, path: []const u8, text: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try unrooted(arena, text) });
}

/// The runner `vera --emit-exe` renders for a `//!` fixture, from the inputs
/// the fixture suite gives it (`analog.zig`'s `runAndCheck`): display on, the
/// directives' SPICE text and discipline resolution, the shape cards compiled
/// in, the contract checks on.
fn runner(gpa: Allocator, arena: Allocator, src: []const u8, includes: []const []const u8, source: []const u8) ![]const u8 {
    const d = try tb.Spec.parse(arena, source, null);
    var bag: vera.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var opts: vera.Settings = .{
        .file_name = src,
        .include_dirs = includes,
        .require_std_includes = true,
        .display = if (d.harness.display_record) .record else .emit,
        .spice_netlist = d.harness.spice,
        .spice_path = src,
        .discipline_resolution = d.harness.discipline_resolution,
    };
    var result = try vera.analyze(gpa, source, opts, &bag);
    defer result.deinit(gpa);
    // §3.4 a shape card is a compile-time value: compile again, as vera does.
    opts.param_overrides = try tb.shapeCards(arena, d.bench.params, result.lowered);
    if (opts.param_overrides.len != 0) {
        bag.deinit(gpa);
        bag = .init(gpa);
        const again = try vera.analyze(gpa, source, opts, &bag);
        result.deinit(gpa);
        result = again;
    }
    var facts = try tb.compileFacts(arena, result.lowered, result.mir);
    facts.validate_contract = true;
    var text: Io.Writer.Allocating = .init(arena);
    tb.writeRunner(&text.writer, arena, std.fs.path.stem(src), &d.bench, facts) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return text.written();
}

/// The tree `vera --emit-so` writes for a `.va` device before `zig` runs
/// (`zigbuild.writeTree`): `shim.zig`, and the split `device.zig`, `h.zig`
/// and `u/*.zig`. A split LLVM build's part and chunk shims and the engine
/// root are written only beside a `zig` child; `zigbuild/shim.zig`'s whole-file
/// tests pin those.
fn soTree(gpa: Allocator, io: Io, arena: Allocator, src: []const u8, includes: []const []const u8, source: []const u8, dir: []const u8, codegen: vera.Codegen) !void {
    var bag: vera.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    // `.record` is `vera`'s default display (`args.Cli`), not `Settings`'.
    var result = try vera.analyze(gpa, source, .{ .file_name = src, .include_dirs = includes, .require_std_includes = true, .display = .record }, &bag);
    defer result.deinit(gpa);
    var device = try result.generate(gpa, codegen, &bag);
    defer device.deinit(gpa);
    if (device.refused) return error.CodegenRefused;
    _ = try zigbuild.writeTree(gpa, io, .{
        .work_dir = dir,
        .name = try zigbuild.fileStem(arena, result.mir.name),
    }, device.output);
}

/// The executable root `vera --emit-exe` builds for a `.v` design with default
/// flags (`src/cli/digital.zig`'s `emitDigital`): native, or the interpreter
/// fallback, whose reason is in its header.
fn program(arena: Allocator, io: Io, src: []const u8, includes: []const []const u8, source: []const u8) ![]const u8 {
    var bag: vera.diag.Bag = .init(arena);
    const opts: digital.Options = .{ .file_name = src, .include_dirs = includes, .io = io };
    var sink: Io.Writer.Discarding = .init(&.{});
    var r = try digital.elaborate(arena, source, opts, &bag, &sink.writer);
    if (bag.failed()) return error.DigitalFailed;
    const prog = try native.program(arena, &r, .{
        .source = source,
        .file_name = opts.file_name,
        .include_dirs = opts.include_dirs,
        .language = opts.language,
        .lib = opts.lib,
        .more = opts.more,
        .search = opts.search,
    }, .static, .auto);
    return prog.text;
}

/// Every `.va` and `.v` under the fixture root but its `netlist/` (ESPice's
/// decks), relative to the root, then `own_dirs`'; those holding `filter`.
fn fixtureList(arena: Allocator, io: Io, filter: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try walkInto(arena, io, &list, options.fixture_root, "", filter);
    for (own_dirs) |sub| try walkInto(arena, io, &list, try std.fs.path.join(arena, &.{ options.repo_root, "tests", sub }), try std.mem.concat(arena, u8, &.{ own_prefix, sub, "/" }), filter);
    std.mem.sort([]const u8, list.items, {}, harness.strLess);
    return list.items;
}

/// VerA's own `--emit-rtlil` and `--emit-verilog` inputs (`tests/rtlil`,
/// `tests/beh_verilog`): the designs those backends accept whole, which
/// the suite's testbenches mostly are not. Snapshotted as `vera/<dir>/...`.
const own_dirs = [_][]const u8{ "rtlil", "beh_verilog" };
const own_prefix = "vera/";

/// The source a snapshot path `rel` (`fixtureList`'s) names.
fn sourceOf(arena: Allocator, rel: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, rel, own_prefix)) return std.fs.path.join(arena, &.{ options.repo_root, "tests", rel[own_prefix.len..] });
    return std.fs.path.join(arena, &.{ options.fixture_root, rel });
}

/// Appends `prefix` ++ each `.va` and `.v` path under `root` but its
/// `netlist/` whose path holds `filter`.
fn walkInto(arena: Allocator, io: Io, list: *std.ArrayList([]const u8), root: []const u8, prefix: []const u8, filter: ?[]const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or std.mem.startsWith(u8, e.path, "netlist" ++ std.fs.path.sep_str)) continue;
        if (!std.mem.endsWith(u8, e.path, ".va") and !std.mem.endsWith(u8, e.path, ".v")) continue;
        const rel = try std.mem.concat(arena, u8, &.{ prefix, e.path });
        if (filter) |f| if (std.mem.find(u8, rel, f) == null) continue;
        try list.append(arena, rel);
    }
}

/// Replaces the snapshot at `out` with a fresh one, one `vera` per CPU, of
/// every fixture whose path holds `filter` (all when null).
fn snapshot(gpa: Allocator, io: Io, arena: Allocator, vera_exe: []const u8, out: []const u8, filter: ?[]const u8, w: *Io.Writer) !u8 {
    Io.Dir.cwd().deleteTree(io, out) catch {};
    try Io.Dir.cwd().createDirPath(io, out);
    // Absolute, because each child runs from the repository root.
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, vera_exe, arena);
    var pool: Pool = .{ .io = io, .gpa = gpa, .vera = exe, .out = out, .rels = try fixtureList(arena, io, filter) };
    // The suite's default, not one per core: 32 concurrent `vera` runs and
    // their device builds exhausted the host's memory (harness.defaultJobs).
    const jobs = harness.defaultJobs();
    var group: Io.Group = .init;
    var hands: usize = 0;
    while (hands < jobs) : (hands += 1) group.concurrent(io, Pool.work, .{&pool}) catch break;
    if (hands == 0) pool.work();
    try group.await(io);
    const failed = pool.failed.load(.monotonic);
    if (failed != 0) {
        try w.print("golden: {d} fixtures could not be snapshotted\n", .{failed});
        return 1;
    }
    try w.print("{d} fixtures snapshotted -> {s}\n", .{ pool.rels.len, out });
    return 0;
}

/// Every file under `root`, relative to it, sorted.
fn fileList(arena: Allocator, io: Io, root: []const u8) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var list: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind == .file) try list.append(arena, try arena.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, list.items, {}, harness.strLess);
    return list.items;
}

/// `diff -r a b` with every fixture root's checkout cut out on both sides
/// (`unrooted`). Prints one line per file that is missing or differs, then
/// IDENTICAL or the count; exit 1 on any difference.
fn compare(arena: Allocator, io: Io, a: []const u8, b: []const u8, w: *Io.Writer) !u8 {
    const left = try fileList(arena, io, a);
    const right = try fileList(arena, io, b);
    var differ: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.len or j < right.len) {
        const order: std.math.Order = if (i == left.len) .gt else if (j == right.len) .lt else std.mem.order(u8, left[i], right[j]);
        switch (order) {
            .lt => {
                try w.print("only in {s}: {s}\n", .{ a, left[i] });
                i += 1;
                differ += 1;
            },
            .gt => {
                try w.print("only in {s}: {s}\n", .{ b, right[j] });
                j += 1;
                differ += 1;
            },
            .eq => {
                const x = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ a, left[i] }), arena, .unlimited);
                const y = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ b, right[j] }), arena, .unlimited);
                if (!std.mem.eql(u8, try unrooted(arena, x), try unrooted(arena, y))) {
                    try w.print("differs: {s}\n", .{left[i]});
                    differ += 1;
                }
                i += 1;
                j += 1;
            },
        }
    }
    if (differ == 0) {
        try w.print("IDENTICAL: {d} files\n", .{left.len});
        return 0;
    }
    try w.print("{d} of {d} files differ\n", .{ differ, @max(left.len, right.len) });
    return 1;
}

/// The fixture roots a snapshot holds, each as it follows the checkout's root:
/// the suite's, then `own_dirs`'.
const roots = [_][]const u8{"/tests/conformance/tests"} ++ own: {
    var keys: [own_dirs.len][]const u8 = undefined;
    for (&keys, own_dirs) |*key, sub| key.* = "/tests/" ++ sub;
    break :own keys;
};

/// `text` with each absolute path's checkout cut out, back to the fixture
/// root it lies under (`roots`, so `tests/conformance/tests/...` or
/// `tests/rtlil/...`). A path starts after a space, quote, backtick or
/// parenthesis, or at a line start, and must start with `/`. It may name the
/// fixture root itself, as the include-search note does
/// (`searched: <root>/tests/conformance/tests, ...`).
fn unrooted(arena: Allocator, text: []const u8) ![]const u8 {
    var cut = text;
    inline for (roots) |key| {
        var out: std.ArrayList(u8) = .empty;
        var rest = cut;
        while (std.mem.find(u8, rest, key)) |at| {
            const end = at + key.len;
            const whole = end == rest.len or std.mem.findScalar(u8, "/ \t\n,;:'\"`)", rest[end]) != null;
            var start = at;
            while (start > 0 and std.mem.findScalar(u8, " \t\n'\"`(", rest[start - 1]) == null) start -= 1;
            if (whole and rest[start] == '/') {
                try out.appendSlice(arena, rest[0..start]);
                try out.appendSlice(arena, key[1..]);
            } else {
                try out.appendSlice(arena, rest[0..end]);
            }
            rest = rest[end..];
        }
        try out.appendSlice(arena, rest);
        cut = out.items;
    }
    return cut;
}

test "unrooted: two checkouts' diagnostics compare equal" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = "  --> /home/a/VerA/tests/conformance/tests/verilog-a/ch02/x.va:3:5\n`/home/a/VerA/tests/conformance/tests/include/y.vh`\n";
    const b = "  --> /tmp/wt/b/tests/conformance/tests/verilog-a/ch02/x.va:3:5\n`/tmp/wt/b/tests/conformance/tests/include/y.vh`\n";
    try std.testing.expectEqualStrings(try unrooted(arena, a), try unrooted(arena, b));
    try std.testing.expectEqualStrings("  --> tests/conformance/tests/verilog-a/x.va:3:5\n", try unrooted(arena, "  --> /r/tests/conformance/tests/verilog-a/x.va:3:5\n"));
    // The include-search note names the root itself, with no slash after it.
    try std.testing.expectEqualStrings(
        "searched: tests/conformance/tests, tests/conformance/tests/include\n",
        try unrooted(arena, "searched: /a/b/tests/conformance/tests, /a/b/tests/conformance/tests/include\n"),
    );
    // A longer name is not the fixture root.
    try std.testing.expectEqualStrings("/r/tests/conformance/tests2/x", try unrooted(arena, "/r/tests/conformance/tests2/x"));
    // A relative mention is not a root and stays as written.
    try std.testing.expectEqualStrings("see tests/conformance/tests/a.va", try unrooted(arena, "see tests/conformance/tests/a.va"));
    // VerA's own fixtures (`own_dirs`): a diagnostic and the program header.
    try std.testing.expectEqualStrings(
        "  --> tests/beh_verilog/x.va:3:5\n// DO NOT EDIT. tests/rtlil/c.v\n",
        try unrooted(arena, "  --> /home/a/VerA/tests/beh_verilog/x.va:3:5\n// DO NOT EDIT. /tmp/wt/b/tests/rtlil/c.v\n"),
    );
}
