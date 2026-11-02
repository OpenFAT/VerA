//! `benchmark`: the depth pass (compile, build and run every testbench) and
//! the timing table (one row per fixture, walk order, so two runs diff;
//! times from a separate sequential accept/reject pass). `main` is the
//! suite's entry point and dispatches on the mode word.
const Fixtures = @import("Fixtures.zig");
const Analog = @import("Analog.zig");
const Canary = @import("Canary.zig");
const CFixtures = @import("CFixtures.zig");
const Devices = @import("Devices.zig");
const Golden = @import("Golden.zig");
const SpiceDecks = @import("SpiceDecks.zig");
const SizeSweep = @import("SizeSweep.zig");
const std = @import("std");
const tb = @import("exe");
const harness = Fixtures;
const torture = Analog;
const size_sweep = SizeSweep;
const devices = Devices;
const c_fixtures = CFixtures;
const spice_decks = SpiceDecks;
const golden = Golden;
const canary = Canary;

const Io = std.Io;

const Allocator = std.mem.Allocator;
const Args = std.process.Args.Iterator;

/// Entry point. argv[1] is the `vera` executable (`run.addArtifactArg2`), which
/// `devices` spawns. Then either a
/// mode word (`devices`, `ieee1364`, `vpi`, `spice`, `golden`) or
/// benchmark arguments:
///
///   zig build suite                         # the suite, timed
///   zig build suite -- ch04                 # only paths matching `ch04`
///   zig build suite -- --strict             # unasserted fixtures FAIL
///   zig build suite -- --fixture-root=DIR   # another tree laid out like the suite's tests/
///   zig build suite -- --sweep              # the generated size sweep instead
///   zig build suite -Doptimize=ReleaseFast  # the timing that ships
///
/// Returns the process exit code.
pub fn main(init: std.process.Init) !u8 {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    // The `vera` binary, from `run.addArtifactArg(exe)`.
    const vera_exe = args.next() orelse return harness.usage(init.io, "missing the vera executable path");
    // The other runs of this executable, matched exactly: any other word,
    // including a bare filter, is a benchmark argument.
    const first = args.next();
    if (first) |a| {
        if (std.mem.eql(u8, a, "ams")) return benchmark(init, vera_exe, "--strict", &args, false);
        if (std.mem.eql(u8, a, "devices")) return devices.run(init, vera_exe, &args, &devices.digital_dirs);
        if (std.mem.eql(u8, a, "ieee1364")) return devices.run(init, vera_exe, &args, &.{devices.ieee1364_dir});
        if (std.mem.eql(u8, a, "vpi")) return c_fixtures.run(init, &args);
        if (std.mem.eql(u8, a, "spice")) return spice_decks.run(init, vera_exe, &args);
        if (std.mem.eql(u8, a, "golden")) return golden.run(init, vera_exe, &args);
        if (std.mem.eql(u8, a, "canary")) return canary.run(init);
    }
    return benchmark(init, vera_exe, first, &args, true);
}

// The oracle is the log `zig build suite -- ams > log 2>&1` writes: a
// positional writer on a redirected stdio file writes from offset 0, under
// the build's own summary, and the first FAIL lines of every run were lost.
// Every file of the runner is read; the root's imports must all be listed.
test "every stdout and stderr writer of the runner streams" {
    const files = [_][]const u8{ "../suite.zig", "Suite.zig", "Fixtures.zig", "Analog.zig", "Canary.zig", "CFixtures.zig", "Child.zig", "Devices.zig", "Digital.zig", "Fuzz.zig", "Golden.zig", "Lint.zig", "Native.zig", "SpiceDecks.zig", "SizeSweep.zig" };
    const root = @embedFile("../suite.zig");
    const import = "@import(\"suite/";
    var at: usize = 0;
    while (std.mem.findPos(u8, root, at, import)) |i| {
        const name = root[i + import.len .. std.mem.findScalarPos(u8, root, i, ')').? - 1];
        try std.testing.expect(for (files) |f| {
            if (std.mem.eql(u8, f, name)) break true;
        } else false);
        at = i + import.len;
    }
    inline for (files) |file| {
        const source = @embedFile(file);
        for ([_][]const u8{ "stdout", "stderr" }) |stream| {
            var buf: [32]u8 = undefined;
            const positional = try std.fmt.bufPrint(&buf, "{s}().{s}(", .{ stream, "writer" });
            try std.testing.expect(std.mem.find(u8, source, positional) == null);
        }
    }
}

/// N per fixture, smaller than `harness/sweep.zig`'s `reps` because every fixture is timed. The min
/// is still the estimator; the report's distribution is over fixtures, the
/// variation that is about the compiler. One outside ReleaseFast: those
/// numbers are not the shipping ones (the report says so), and the CI gate
/// runs Debug, where four more passes over every fixture time nothing.
const fixture_reps = if (@import("builtin").mode == .fast) 5 else 1;

/// `harness/sweep.zig`'s `mode` and `elapsed`: the optimize mode on every
/// report row, and the monotonic timer both reports read.
const mode = size_sweep.mode;
const elapsed = size_sweep.elapsed;

// ---------------------------------------------------------------------------
// The step
// ---------------------------------------------------------------------------

fn benchmark(init: std.process.Init, vera_exe: []const u8, first: ?[]const u8, args: *Args, timed: bool) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `harness.takeArg` owns every knob the SUITE has, and takes them first, so
    // that a filter word cannot shadow one. What is left is this step's own.
    var cfg: harness.Config = .init();
    harness.vera_exe = vera_exe; // `//! expect vcd` runs it
    var do_sweep = false;
    var a = first;
    while (a) |arg| : (a = args.next()) {
        if (harness.takeArg(&cfg, arg)) continue;
        if (std.mem.eql(u8, arg, "--sweep")) do_sweep = true //
        else if (std.mem.startsWith(u8, arg, "-")) {
            var e_buf: [256]u8 = undefined;
            var e = Io.File.stderr().writerStreaming(io, &e_buf);
            try e.interface.print("benchmark: unknown flag `{s}`\n", .{arg});
            try e.interface.flush();
            return 2;
        } else cfg.filter = arg;
    }
    // `--fixture-root=DIR` is how a human writes it; resolved once, so every
    // FAIL line names an absolute path.
    cfg.root = std.fs.path.resolveAlloc(arena, &.{cfg.root}) catch cfg.root;

    var out_buf: [1 << 16]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    if (do_sweep) return size_sweep.report(gpa, io, arena, w);

    var tctx: torture.Ctx = .{ .cfg = &cfg };
    defer tctx.deinit(gpa);

    // THE DEPTH PASS: VerA compiles, builds a testbench, runs it and reads the
    // `ok=` columns. It owns the exit code, because it is the only pass that
    // can fail — a wall clock has no verdict.
    var depth: harness.Counts = .{};
    const code = try harness.run(init, torture.compiler(&tctx), cfg, &depth);

    if (timed) try report(gpa, io, arena, w, cfg, depth);
    return code;
}

// ---------------------------------------------------------------------------
// The timing table. VerA's accept/refuse verdict is `harness.judge`'s; its
// `ok=` columns print in the depth pass.
// ---------------------------------------------------------------------------

fn report(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    w: *Io.Writer,
    cfg: harness.Config,
    depth: harness.Counts,
) !void {
    const fixtures = try harness.collect(arena, io, cfg.root, &harness.ams_dirs, cfg.filter);
    if (fixtures.len == 0) return;

    // VerA's accept/reject prose is discarded: the depth pass already printed
    // a stronger report of the same fixtures.
    var sink: [256]u8 = undefined;
    var discard: Io.Writer.Discarding = .init(&sink);

    try w.print(
        \\# VerA benchmark — engine built {s}, min of {d} runs per fixture, sequential.
        \\# The timed unit is ONE accept/reject compilation: source in, device text out.
        \\# The testbench build and run that decide the verdicts are NOT in these
        \\# numbers — that is `zig build-exe`, whose wall clock is not VerA's.
        \\
    , .{ mode, fixture_reps });
    if (@import("builtin").mode != .fast) try w.print(
        "# {s}: NOT the shipping number (~8x slow). Re-run with -Doptimize=ReleaseFast.\n",
        .{mode},
    );
    try w.writeAll("fixture\tdemands\tvera_ns\tvera_out\tvera_ok\n");

    const times = try arena.alloc(u64, fixtures.len);
    var per_arena: std.heap.ArenaAllocator = .init(gpa);
    defer per_arena.deinit();

    for (fixtures, times) |f, *time| {
        _ = per_arena.reset(.retain_capacity);
        const pa = per_arena.allocator();
        const source = try Io.Dir.cwd().readFileAlloc(io, f.path, pa, .limited(1 << 20));
        // A fixture whose directives do not parse is FAILED by `judge` below,
        // which is where that defect belongs; here it just times as one.
        const d = tb.Spec.parse(pa, source, null) catch tb.Spec{};

        var vera_ns: u64 = std.math.maxInt(u64);
        var vera_out: ?usize = null;
        for (0..fixture_reps) |_| {
            const t0: Io.Timestamp = .now(io, .awake);
            vera_out = torture.compileOnce(gpa, f, source, d) catch null;
            vera_ns = @min(vera_ns, elapsed(io, t0));
        }
        const vera_ok = try harness.judge(
            gpa,
            io,
            pa,
            torture.acceptRejectCompiler(),
            f,
            false,
            &discard.writer,
        ) == .pass;
        time.* = vera_ns;

        try w.print("{s}\t{s}\t{d}\t", .{
            relative(f.path, cfg.root),
            if (d.harness.reject.len != 0) "refuse" else "compile",
            vera_ns,
        });
        try optional(w, vera_out);
        try w.print("\t{d}\n", .{@intFromBool(vera_ok)});
        try w.flush();
    }

    try summary(w, arena, times, depth);
}

/// `-` and not `0`: "there is no number" and "the number is zero" are different
/// facts, and a refused fixture emits no device rather than an empty one.
fn optional(w: *Io.Writer, v: anytype) !void {
    if (v) |n| try w.print("{d}", .{n}) else try w.writeAll("-");
}

fn relative(path: []const u8, root: []const u8) []const u8 {
    return path[@min(root.len + 1, path.len)..];
}

fn summary(w: *Io.Writer, arena: Allocator, times: []const u64, depth: harness.Counts) !void {
    try w.writeAll(
        \\
        \\# SPEED — total and distribution.
        \\
    );
    try w.writeAll("scope\tcompiler\tn\ttotal_ns\tp50_ns\tp90_ns\tp99_ns\tmax_ns\n");
    try stats(w, arena, "all", "vera", times);

    try w.writeAll(
        \\
        \\# VERA ONLY — the `ok=` assertions, and the depth no foreign compiler is
        \\#   measured at. Only VerA's testbench is built and run, so these are a
        \\#   question an accept/reject-only compiler was never asked and never a score
        \\#   it lost. A fixture passes here only if every `ok=` column its own
        \\#   transcript printed came out 1 — the compile and the refusal columns above
        \\#   are a strictly weaker claim than this one.
        \\
    );
    try w.writeAll("pass\tfail\tunasserted\txfail\n");
    try w.print("{d}\t{d}\t{d}\t{d}\n", .{
        depth.passed,
        depth.failed,
        depth.unasserted,
        depth.xfail,
    });
}

/// One speed row. The samples are COPIED before sorting: they are also the
/// caller's.
fn stats(w: *Io.Writer, arena: Allocator, scope: []const u8, name: []const u8, samples: []const u64) !void {
    if (samples.len == 0) return;
    const s = try arena.dupe(u64, samples);
    var total: u64 = 0;
    for (s) |v| total +%= v;
    std.mem.sort(u64, s, {}, std.sort.asc(u64));
    try w.print("{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        scope, name, s.len, total, pct(s, 50), pct(s, 90), pct(s, 99), s[s.len - 1],
    });
}

fn pct(sorted: []const u64, p: usize) u64 {
    return sorted[@min(sorted.len * p / 100, sorted.len - 1)];
}
