//! The conformance harness: the suite's AMS fixtures (`ams_dirs`) and a plugged-in
//! `Compiler` -> one verdict per fixture and a report. Everything that is not
//! about a particular compiler lives here: the fixture walk (`collect`), the
//! verdict algebra (`judge`, `decide`) and the parallel run (`run`, the
//! spine). Plugs: `analog.zig`'s full compiler (runs the model) and its
//! accept/refuse-only one. `suite.zig` owns `main`.
//!
//! Sub-files under `harness/`, each a table of free functions:
//!   `lint.zig`      the assertion lint `decide` runs before compiling
//!   `digital.zig`   the `.v` runner metadata both digital runners read
//! The other runners import the sub-file they need directly.
//!
//! The verdict algebra is frozen behaviour: an `ok=1`
//! transcript is `met` only through the compiler plug, `//! xfail` (or a
//! `xfail_list` line) turns `unmet` into XFAIL and `met` into an XPASS FAIL,
//! and `--strict` fails unasserted fixtures. An XFAIL never fails a run:
//! the list of them is the checked-in marker list, compared by name.
//!
//! Contents:
//! - `pub const include_dir`
//! - `pub const Fixture = struct`
//! - `pub fn Fixture.stem(f: Fixture) []const u8`
//! - `pub fn Fixture.dir(f: Fixture) []const u8`
//! - `pub const Result = union`
//! - `pub const Config = struct`
//! - `pub fn Config.init() Config`
//! - `pub const Verdict = enum`
//! - `pub const Counts = struct`
//! - `pub var perturb`
//! - `pub var certify`
//! - `pub var probe_reject_only`
//! - `pub var vera_exe`
//! - `pub fn listedXfail(arena: std.mem.Allocator, io: Io, root: []const u8, path: []const u8) !?[]const u8`
//! - `pub fn strLess(_: void, a: []const u8, b: []const u8) bool`
//! - `pub fn defaultJobs() usize`
//! - `pub fn usage(io: Io, why: []const u8) !u8`
//! - `pub fn takeArg(cfg: *Config, a: []const u8) bool`
//! - `pub fn hasDirective(source: []const u8) bool`

const Devices = @import("Devices.zig");
const Digital = @import("Digital.zig");
const Lint = @import("Lint.zig");
const std = @import("std");
const tb = @import("exe");
const zigbuild = @import("zigbuild");
/// `fixture_root` and `repo_root`, from `build.zig`; shared by every runner
/// so all compilers are judged on the same fixtures.
const options = @import("suite_options");

const Io = std.Io;

/// The directories under the fixture root the AMS walk (`collect`) covers:
/// Verilog-A, Verilog-AMS and annex E's SPICE, plus the `.va` sources under
/// `verilog/` (an analog design a `pli/` `.c` drives, with its own cites); the
/// IEEE 1364 `.v` there is the `devices` modes' (`Devices.ieee1364_dir`). Never
/// `netlist/` (ESPice's decks) or `include/`.
pub const ams_dirs = [_][]const u8{ "verilog-a", "verilog-ams", "spice", Devices.ieee1364_dir };

/// `check.vh` and `erfc.vh`: the include dir of every compile, after the
/// fixture's own directory.
pub const include_dir = options.fixture_root ++ "/include";

/// VerA's own expected failures. The suite carries no `//! xfail` lines (a
/// tool's known failures are its `tools/<tool>.xfail`), so this list is VerA's:
/// one path a line, relative to the suite root (`tests/verilog/16_sdf/x.v`),
/// the reason after `#`; a line starting `#` is a comment. A fixture listed
/// here is judged exactly as if it carried `//! xfail <reason>`.
pub const xfail_list = options.repo_root ++ "/tests/suite.xfail";

/// Everything one fixture needs, all with the same lifetime (the arena
/// `collect` was given). One row per collected fixture; the stem and the
/// directory are slices of `path`, derived rather than stored.
pub const Fixture = struct {
    /// `<root>/verilog-a/ch04_expressions/01_arithmetic.va`; ends in `.va` or `.v`.
    path: []const u8,
    /// The fixture root this fixture was collected from (the suite's `tests/`,
    /// or another under `--fixture-root=`): what a printed path is relative
    /// to, the key `listedXfail` reads, and the scratch namespace.
    root: []const u8,
    /// `verilog-a_ch04_expressions_01_arithmetic` — the scratch directory name.
    ///
    /// Not the stem: stems repeat across chapters, and fixtures sharing a
    /// scratch directory race in parallel.
    slug: []const u8,

    /// `01_arithmetic`: the file name without its `.va` or `.v`.
    pub fn stem(f: Fixture) []const u8 {
        const base = std.fs.path.basename(f.path);
        const ext: usize = if (std.mem.endsWith(u8, base, ".va")) ".va".len else ".v".len;
        return base[0 .. base.len - ext];
    }

    /// `<root>/verilog-a/ch04_expressions`, the first include dir.
    pub fn dir(f: Fixture) []const u8 {
        return std.fs.path.dirname(f.path) orelse ".";
    }
};

// Budget: three slices. `stem` and `dir` are slices of `path`, so storing
// them cost 32 B a row for nothing.
comptime {
    std.debug.assert(@sizeOf(Fixture) == 48);
}

/// What the compiler under test did with one fixture, in the only vocabulary
/// both sides can speak.
///
/// The question is "did it do what the fixture says?", not accepted/rejected.
/// A runner writes its detail only to the report writer, which the harness may
/// suppress (for an xfail).
pub const Result = union(enum) {
    /// Did what the fixture says it must.
    met,
    /// Did not. The reason is already in the report writer.
    unmet,
    /// Compiled and ran and asserted NOTHING. Only a runner whose compiler
    /// actually runs a model can return this; for the rest, a fixture that
    /// compiles has said all it can say.
    unasserted,
};

/// One compiler, plugged in.
pub const Compiler = struct {
    /// Names the compiler in the report.
    name: []const u8,
    /// Whether this compiler runs a fixture or only accepts or refuses it. When
    /// false, an unasserted fixture is not held against it and the summary says
    /// no `ok=` column was checked.
    runs: bool,
    /// Whether `//! xfail` describes this compiler. Markers record VerA's gaps;
    /// honouring them for another compiler would excuse its failures and fail
    /// its passes as XPASS.
    owns_xfail: bool,
    /// Passed back to `check`; type-erased so `run` is one function.
    ctx: *anyopaque,
    /// Judges one fixture; writes any detail to `w` and nowhere else.
    check: *const fn (
        ctx: *anyopaque,
        gpa: std.mem.Allocator,
        io: Io,
        arena: std.mem.Allocator,
        f: Fixture,
        source: []const u8,
        d: tb.Spec,
        w: *Io.Writer,
    ) anyerror!Result,
    /// Runs once over the whole fixture list before any `check`, on `jobs`
    /// workers: work `check` can share across fixtures (VerA builds its
    /// testbenches in batches here). Null: nothing to share.
    prepare: ?*const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: Io, fixtures: []const Fixture, jobs: usize) anyerror!void = null,
};

/// Every suite knob, parsed once by `tests/suite.zig` and shared by all the
/// compilers in a run, so a head-to-head never walks two fixture sets.
pub const Config = struct {
    /// The fixture tree to walk: its `ams_dirs`.
    root: []const u8 = options.fixture_root,
    /// A plain substring over the whole path.
    filter: ?[]const u8 = null,
    strict: bool = false,
    /// Worker threads, default one per core. `-j1` prints as it goes, which
    /// shows the fixture a run is stuck on.
    jobs: usize = 0,
    /// Optimize mode of the per-fixture testbench binaries (`-Doptimize` builds
    /// the runner). Debug: a testbench compiles for seconds and runs for
    /// microseconds, and safety checks make a codegen bug trap instead of
    /// printing a plausible wrong number. Zig floats are strict IEEE in every
    /// mode, so `--fixture-opt=ReleaseFast` asks only about optimization.
    fixture_opt: std.lang.Optimize = .debug,
    /// `--fixture-backend=llvm|native`; null is `Backend.auto(fixture_opt, <host>)`.
    fixture_backend: ?zigbuild.Backend = null,
    /// `--no-batch` builds every fixture testbench alone (`Compiler.prepare`
    /// is skipped): the escape hatch, and the baseline a batched run is
    /// compared against.
    batch: bool = true,

    /// Returns the defaults, with `jobs` from `defaultJobs`.
    pub fn init() Config {
        return .{ .jobs = defaultJobs() };
    }
};

/// A fixture's outcome after the verdict algebra.
pub const Verdict = enum {
    /// Behaved as the fixture said it would.
    pass,
    /// Did not.
    fail,
    /// Compiled, ran, and asserted NOTHING. Green under a suite that only looks
    /// for a crash, and the reason this harness exists.
    unasserted,
    /// Did not behave as the fixture said — and the fixture said so in advance
    /// with `//! xfail`. The rule is real, this compiler does not meet it yet.
    /// Not a pass either.
    ///
    /// This is the only meaning an xfail has.
    xfail,
};

/// Tally of verdicts over one run.
pub const Counts = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    unasserted: u32 = 0,
    xfail: u32 = 0,

    fn add(c: *Counts, v: Verdict) void {
        switch (v) {
            .pass => c.passed += 1,
            .fail => c.failed += 1,
            .unasserted => c.unasserted += 1,
            .xfail => c.xfail += 1,
        }
    }
};

/// `--perturb[=δ]`: the perturbation pass. Every fixture is compiled with
/// `VERA_PERTURB` defined to δ, which makes `check.vh` move each want by a
/// relative δ, and a check that still prints `ok=1` is LOOSE: it cannot see an
/// error of that size. Null: an ordinary run. Set once by `takeArg`.
pub var perturb: ?f64 = null;

/// `--certify`: the device certificates. Every testbench also runs the derivative
/// gate (`fdCheck`, L4a): each Jacobian entry against a central difference;
/// the prover-soundness gate (`finiteCheck`, L4b): a proved-finite device's
/// rows at random unknowns; and the state gate (`stateCheck`, L4c): revert
/// after `updateState` restores every field. Set once by `takeArg`.
pub var certify: bool = false;

/// `--probe-reject-only`: judges each `//! reject` fixture as if it were
/// `//! reject-only` and prints `ONLY-OK <path>` or `ONLY-NO <path>: <code>`,
/// the worklist for promoting refusals that already refuse alone
/// (`tools/conformance.py promote-reject-only`). Positive fixtures are not run.
pub var probe_reject_only: bool = false;

/// The `vera` executable, for the one fixture no in-process runner can judge:
/// a `//! expect vcd` digital run, whose evidence is a FILE the run writes.
/// Set once by `tests/suite.zig`, which is handed the path; read-only after.
pub var vera_exe: ?[]const u8 = null;

const lint = Lint;
const digital = Digital;

/// `--fixture-opt=` names. Zig 0.17 renamed `std.lang.Optimize`'s tags
/// (`fast`, ...); the flag keeps the names it always took.
const optimize_names = std.StaticStringMap(std.lang.Optimize).initComptime(.{
    .{ "Debug", .debug },
    .{ "ReleaseSafe", .safe },
    .{ "ReleaseFast", .fast },
    .{ "ReleaseSmall", .small },
});

/// The default never exceeds this many concurrent fixture builds, whatever
/// the core and RAM count. 2026-10-17: a gate's suite (15 jobs by `job_ram`),
/// a second suite and other projects' builds on the same 31 GB host ran it out
/// of memory overnight: `job_ram` sizes against TOTAL memory, so two suites
/// each assume the whole machine. `-j` still overrides.
const max_default_jobs = 8;

/// RAM budgeted per concurrent fixture build: 4x the measured mean, for the
/// large devices and the other processes on the host.
const job_ram: u64 = 2 << 30;

/// One fixture's whole report, held rather than printed.
const Slot = struct {
    verdict: Verdict = .pass,
    /// Everything the fixture printed, owned by `gpa`. Held as ONE block so a
    /// FAIL keeps its diagnostics, its LRM cites and its transcript together
    /// instead of being shredded across whatever else finished at the time.
    output: []const u8 = "",
};

/// The work queue, shared by every worker.
///
/// Fixtures share nothing (source, scratch directory, output slot), so the only
/// synchronisation is which one to take next.
const Job = struct {
    gpa: std.mem.Allocator,
    io: Io,
    compiler: Compiler,
    fixtures: []const Fixture,
    slots: []Slot,
    strict: bool,
    next: std.atomic.Value(usize) = .init(0),

    fn work(job: *Job) void {
        // Per-worker, and reset per fixture: an arena is not threadsafe, and
        // the shared one the sequential path uses would grow to the whole run.
        var arena_state: std.heap.ArenaAllocator = .init(job.gpa);
        defer arena_state.deinit();

        while (true) {
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.fixtures.len) return;
            _ = arena_state.reset(.retain_capacity);
            const f = job.fixtures[i];

            var aw: Io.Writer.Allocating = .init(job.gpa);
            const verdict = judge(
                job.gpa,
                job.io,
                arena_state.allocator(),
                job.compiler,
                f,
                job.strict,
                &aw.writer,
            ) catch |err| blk: {
                aw.writer.print("FAIL {s}: the runner itself failed: {t}\n", .{ f.path, err }) catch {};
                break :blk .fail;
            };
            var list = aw.toArrayList();
            job.slots[i] = .{
                .verdict = verdict,
                .output = list.toOwnedSlice(job.gpa) catch "",
            };
        }
    }
};

/// The reason `xfail_list` gives the fixture at `path` under `root` (the
/// suite's `tests/`, so the key is `path` relative to `root`'s parent): ""
/// for a bare line, null when it is not listed. Read per call: the file is a
/// few lines, and a run's workers then share nothing.
pub fn listedXfail(arena: std.mem.Allocator, io: Io, root: []const u8, path: []const u8) !?[]const u8 {
    const suite_root = std.fs.path.dirname(root) orelse return null;
    if (!std.mem.startsWith(u8, path, suite_root)) return null;
    const text = Io.Dir.cwd().readFileAlloc(io, xfail_list, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return xfailIn(text, std.mem.trimStart(u8, path[suite_root.len..], "/"));
}

/// `std.mem.sort` order for strings: bytewise.
pub fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Concurrent fixture builds by default: the CPU count, capped at one per
/// `job_ram` of physical memory. Each job is a Zig compile (measured
/// 2026-10-01: the strict suite peaked at 16.2 GB with 32 jobs, ~0.5 GB each,
/// larger devices more), and a CPU-sized fan-out on a 32-thread, 31 GB host
/// beside other builds exhausted RAM and froze the machine (zram swap lives
/// in RAM, so nothing was OOM-killed). `-j` still overrides.
pub fn defaultJobs() usize {
    const cpus = std.Thread.getCpuCount() catch 1;
    const ram = std.process.totalSystemMemory() catch return @min(cpus, max_default_jobs);
    return @max(1, @min(cpus, ram / job_ram, max_default_jobs));
}

/// Prints `why` and the usage line to stderr; returns exit code 2.
pub fn usage(io: Io, why: []const u8) !u8 {
    var buf: [256]u8 = undefined;
    var e = Io.File.stderr().writerStreaming(io, &buf);
    try e.interface.print(
        "suite: {s}\nusage: <vera-exe> [devices | ieee1364 | vpi | spice | benchmark args]\n",
        .{why},
    );
    try e.interface.flush();
    return 2;
}

/// Consumes one argument if it is the suite's; false leaves it to the caller,
/// which decides whether it is a filter. Exits 2 on a malformed value.
pub fn takeArg(cfg: *Config, a: []const u8) bool {
    if (std.mem.eql(u8, a, "--strict")) cfg.strict = true //
    else if (std.mem.eql(u8, a, "--no-batch")) cfg.batch = false //
    else if (std.mem.startsWith(u8, a, "--fixture-root=")) cfg.root = a["--fixture-root=".len..] //
    else if (std.mem.eql(u8, a, "--certify")) certify = true //
    else if (std.mem.eql(u8, a, "--probe-reject-only")) probe_reject_only = true //
    else if (std.mem.eql(u8, a, "--perturb")) perturb = 1e-3 //
    else if (std.mem.startsWith(u8, a, "--perturb=")) {
        perturb = std.fmt.parseFloat(f64, a["--perturb=".len..]) catch {
            std.debug.print("suite: not a number: {s}\n", .{a});
            std.process.exit(2);
        };
    } //
    else if (std.mem.startsWith(u8, a, "--fixture-opt=")) {
        const name = a["--fixture-opt=".len..];
        cfg.fixture_opt = optimize_names.get(name) orelse {
            std.debug.print("suite: not an optimize mode: {s}\n", .{name});
            std.process.exit(2);
        };
    } else if (std.mem.startsWith(u8, a, "--fixture-backend=")) {
        const name = a["--fixture-backend=".len..];
        cfg.fixture_backend = if (std.mem.eql(u8, name, "llvm")) .llvm else if (std.mem.eql(u8, name, "native")) .self_hosted else {
            std.debug.print("suite: not llvm|native: {s}\n", .{name});
            std.process.exit(2);
        };
    } else if (numeric(a, "-j") orelse numeric(a, "--jobs=")) |n| cfg.jobs = @max(n, 1) //
    else return false;
    return true;
}

/// The judged pass: every fixture through this compiler, the report on stderr.
/// `tally` receives the counts the summary prints, for the head-to-head table.
pub fn run(
    init: std.process.Init,
    compiler: Compiler,
    cfg: Config,
    tally: ?*Counts,
) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &stderr_buf);
    const w = &stderr.interface;

    const fixtures = try collect(arena, io, cfg.root, &ams_dirs, cfg.filter);
    if (fixtures.len == 0) {
        try w.print("{s}: no fixtures under {s}\n", .{ compiler.name, cfg.root });
        try w.flush();
        return 1;
    }

    if (compiler.prepare) |prepare| if (cfg.batch) try prepare(compiler.ctx, gpa, io, fixtures, @max(cfg.jobs, 1));

    const strict = cfg.strict;
    var counts: Counts = .{};
    const verdicts = try arena.alloc(Verdict, fixtures.len);
    if (cfg.jobs <= 1) {
        // Sequential: prints as it goes, showing the fixture a run is stuck on.
        for (fixtures, verdicts) |f, *v| {
            v.* = try judge(gpa, io, arena, compiler, f, strict, w);
            counts.add(v.*);
            try w.flush();
        }
    } else {
        const slots = try arena.alloc(Slot, fixtures.len);
        var job: Job = .{
            .gpa = gpa,
            .io = io,
            .compiler = compiler,
            .fixtures = fixtures,
            .slots = slots,
            .strict = strict,
        };
        var group: Io.Group = .init;
        var hands: usize = 0;
        while (hands < cfg.jobs) : (hands += 1) {
            // A narrower pool than asked for is fine — the queue does not care
            // how many hands take from it. None at all is not, so this thread
            // does the work itself.
            group.concurrent(io, Job.work, .{&job}) catch break;
        }
        if (hands == 0) job.work();
        try group.await(io);

        // Emit in SLOT order, i.e. the sorted walk, whatever order the pool
        // finished in. This is the whole reason the workers buffer.
        for (slots, verdicts) |s, *v| {
            v.* = s.verdict;
            counts.add(s.verdict);
            try w.writeAll(s.output);
            gpa.free(s.output);
        }
        try w.flush();
    }

    try summarize(compiler, counts, fixtures.len, w);
    try names(w, "FAIL", fixtures, verdicts, .fail);
    try names(w, "XFAIL", fixtures, verdicts, .xfail);
    try w.flush();
    if (tally) |t| t.* = counts;
    // An XFAIL is a named marker (`xfail_list`), and its XPASS already
    // failed: the run fails on an unlisted FAIL, never on a listed one.
    return if (counts.failed == 0 and !(strict and counts.unasserted != 0)) 0 else 1;
}

/// Every fixture under `dirs` of `root` (`ams_dirs`; `&.{""}` is the whole
/// root), sorted by path so the run is deterministic (`Dir.walk` order is
/// explicitly undefined) and a failing run is reproducible and diffable. A
/// test in two language directories is two fixtures. `filter` is a plain
/// substring over the whole path: `zig build suite -- ch04` runs one
/// group. The rows and their strings live in `arena`; a missing directory
/// contributes nothing.
pub fn collect(arena: std.mem.Allocator, io: Io, root: []const u8, dirs: []const []const u8, filter: ?[]const u8) ![]const Fixture {
    // `fixtureExt` reads each `.va` and golden-less `.v` whole to look for a directive.
    // Those reads are dead once it answers, so they go to a scratch arena
    // reset per file instead of living in `arena` for the whole run.
    var scratch: std.heap.ArenaAllocator = .init(arena);
    var list: std.ArrayList(Fixture) = .empty;
    for (dirs) |sub| {
        var dir = Io.Dir.cwd().openDir(io, try std.fs.path.join(arena, &.{ root, sub }), .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            // IEEE 1364's `.v` is the `devices` modes' own; only its `.va` is here.
            if (std.mem.eql(u8, sub, Devices.ieee1364_dir) and !std.mem.endsWith(u8, entry.path, ".va")) continue;
            _ = scratch.reset(.retain_capacity);
            const ext = fixtureExt(scratch.allocator(), io, dir, entry.path) orelse continue;
            const rel = try std.fs.path.join(arena, &.{ sub, entry.path });
            const path = try std.fs.path.join(arena, &.{ root, rel });
            if (filter) |f| if (std.mem.find(u8, path, f) == null) continue;
            const slug = try arena.dupe(u8, rel[0 .. rel.len - ext.len]);
            std.mem.replaceScalar(u8, slug, '/', '_');
            std.mem.replaceScalar(u8, slug, '\\', '_');
            try list.append(arena, .{ .path = path, .root = root, .slug = slug });
        }
    }
    std.mem.sort(Fixture, list.items, {}, struct {
        fn lt(_: void, a: Fixture, b: Fixture) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return list.items;
}

/// Does this source carry a `//!` directive? `tb.Spec.parse`'s own line rule, and it
/// must stay that rule: this decides whether a file is collected and `tb.Spec.parse`
/// decides whether it asserts anything, so a disagreement collects a fixture
/// that then reports nothing.
pub fn hasDirective(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, raw, " \t\r"), "//!")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The verdict algebra — the whole reason both runners share this file
// ---------------------------------------------------------------------------

/// One fixture, from source text to verdict. The runner answers met/unmet;
/// the rest (xfail, strict, the assertion lint) is here, so every compiler is
/// judged alike. The head-to-head in `tests/suite.zig` calls it per fixture.
pub fn judge(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    compiler: Compiler,
    f: Fixture,
    strict: bool,
    w: *Io.Writer,
) !Verdict {
    const source = try Io.Dir.cwd().readFileAlloc(io, f.path, arena, .limited(1 << 20));

    // A §18 dump fixture's evidence is the file its run writes, which no
    // `tb` directive describes; it is judged before `tb.Spec.parse` for that reason.
    if (digital.vcdExpectation(source)) |want| return judgeVcd(arena, io, compiler, f, want, w);

    // The `//!` lines are read from the RAW source: the preprocessor deletes
    // comments (§2.4), so after compilation they are gone.
    var d = tb.Spec.parse(arena, source, null) catch |err| {
        try w.print("FAIL {s}: `//!` directive: {t}\n", .{ f.path, err });
        return .fail;
    };
    // VerA's own list stands in for the `//! xfail` line the suite dropped.
    if (d.harness.xfail == null) d.harness.xfail = try listedXfail(arena, io, f.root, f.path);

    const verdict = try decide(gpa, io, arena, compiler, f, source, d, strict, w);

    // A verdict that names only the file makes the reader go and find the rule.
    // If the fixture said which clause it pins, say it here — for an xfail too,
    // where the cite IS the requirement being carried unmet.
    switch (verdict) {
        .fail, .xfail => if (d.harness.lrm.len != 0) {
            try w.print("  LRM", .{});
            for (d.harness.lrm) |section| try w.print(" §{s}", .{section});
            try w.print("\n", .{});
        },
        .pass, .unasserted => {},
    }
    return verdict;
}

// ---- private ----

/// `listedXfail`'s lookup of `rel` in the list's `text`.
fn xfailIn(text: []const u8, rel: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const hash = std.mem.findScalar(u8, line, '#') orelse line.len;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..hash], " \t"), rel)) continue;
        return std.mem.trim(u8, line[@min(hash + 1, line.len)..], " \t");
    }
    return null;
}

/// `-j8`, `--jobs=8`. Null when `a` is not that flag at all.
fn numeric(a: []const u8, prefix: []const u8) ?usize {
    if (!std.mem.startsWith(u8, a, prefix)) return null;
    return std.fmt.parseInt(usize, a[prefix.len..], 10) catch null;
}

/// The `verdict` fixtures' names after the summary, one a line, in walk
/// (path) order and in `xfail_list`'s key form, so a run's FAIL list is a
/// name list that diffs against the last one and pastes into the list.
fn names(w: *Io.Writer, label: []const u8, fixtures: []const Fixture, verdicts: []const Verdict, verdict: Verdict) !void {
    std.debug.assert(fixtures.len == verdicts.len);
    var any = false;
    for (fixtures, verdicts) |f, v| {
        if (v != verdict) continue;
        if (!any) try w.print("{s} names:\n", .{label});
        any = true;
        const suite_root = std.fs.path.dirname(f.root) orelse f.root;
        try w.print("  {s}\n", .{std.mem.trimStart(u8, f.path[@min(suite_root.len, f.path.len)..], "/")});
    }
}

fn summarize(compiler: Compiler, c: Counts, total: usize, w: *Io.Writer) !void {
    try w.print("\n{s}: {d}/{d} fixtures behave as they say they do", .{ compiler.name, c.passed, total });
    // Say which question the number answers. A compiler that only accepts or
    // refuses has not checked a single `ok=` column, and a bare score would
    // read as if it had.
    if (!compiler.runs) try w.print(
        "\n  ACCEPT/REJECT ONLY: {s} is not run against the fixtures' own assertions,\n" ++
            "  so a `pass` here means it compiled what must compile and refused what must\n" ++
            "  be refused — not that any computed value was checked.",
        .{compiler.name},
    );
    try w.print("\n", .{});
    if (c.failed != 0) try w.print("  {d} FAILED\n", .{c.failed});
    if (c.unasserted != 0) try w.print(
        "  {d} compiled and ran but ASSERT NOTHING — they prove only that {s} did\n" ++
            "  not crash. Give each a `CHECK(\"what this proves\", got, want, tol)`\n" ++
            "  from check.vh with an independently derived want. (`--strict` fails on these.)\n",
        .{ c.unasserted, compiler.name },
    );
    if (c.xfail != 0) try w.print(
        "  {d} XFAIL — the fixture is right and {s} is not: it states a real LRM\n" ++
            "  requirement that {s} is known not to meet yet, and said so on its\n" ++
            "  `//! xfail` line or its xfail list row (printed with the reason above).\n" ++
            "  Not a pass — nothing was proved. The day it starts meeting it the run\n" ++
            "  FAILs with an XPASS, so the marker cannot outlive the limitation and\n" ++
            "  quietly hide a regression.\n",
        .{ c.xfail, compiler.name, compiler.name },
    );
}

/// Is this path a fixture for the accept/reject walk, and if so what extension
/// does its stem end at? `null` means "not this walk's business".
///
/// `.va` is a fixture when it carries a directive: a `.va` with none is a
/// design a host test loads (a `//! device` line of a `*_host.zig`, the VPI walk's
/// `vpi_design.va`), the same rule as item 3 below. `.v` is the awkward one,
/// because three different things share that extension in
/// `verilog-ams/digital/` (IEEE 1364's `verilog/` is not walked for `.v`):
///
///   1. Files with a `<stem>.expected.txt` beside them, or a `//! reject`
///      line (`Digital.negative`), belong to `zig build suite -- devices`
///      (`Devices.digitalCases`), not here.
///   2. Other files with a directive are judged here: `//! expect vcd` rows
///      by `judgeVcd`, the rest by the usual algebra.
///   3. Files with no directive (VPI support designs such as `design.v`)
///      are not fixtures.
///
/// The whole file is scanned with `tb.Spec.parse`'s line rule (see `hasDirective`).
fn fixtureExt(arena: std.mem.Allocator, io: Io, dir: Io.Dir, rel: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, rel, ".va")) {
        const source = dir.readFileAlloc(io, rel, arena, .limited(1 << 20)) catch return null;
        return if (hasDirective(source)) ".va" else null;
    }
    if (!std.mem.endsWith(u8, rel, ".v")) return null;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const stem = rel[0 .. rel.len - ".v".len];
    const golden = std.mem.print(&buf, "{s}.expected.txt", .{stem}) catch return null;
    if (dir.access(io, golden, .{})) |_| return null else |_| {}

    const source = dir.readFileAlloc(io, rel, arena, .limited(1 << 20)) catch return null;
    // A digital negative belongs to the devices' `--run` runner.
    if (digital.negative(source)) return null;
    return if (hasDirective(source)) ".v" else null;
}

fn decide(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    compiler: Compiler,
    f: Fixture,
    source: []const u8,
    d: tb.Spec,
    strict: bool,
    w: *Io.Writer,
) !Verdict {
    // A perturbed run asks one question of a passing positive fixture: does
    // each check fail when its want is wrong? A refusal has no want, and an
    // xfail does not pass to begin with.
    if (perturb != null and (d.harness.reject.len != 0 or d.harness.reject_run.len != 0 or d.harness.xfail != null)) return .pass;
    if (probe_reject_only and (d.harness.reject.len == 0 or d.harness.reject_only or d.harness.xfail != null)) return .pass;

    // The other half of a refusal: each named neighbour is a collected
    // positive fixture, so the pair shows a restriction and not a blanket
    // refusal.
    for (d.harness.neighbours) |n| {
        const path = try std.fs.path.join(arena, &.{ f.dir(), n });
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch {
            try w.print("FAIL {s}: `//! neighbour {s}`: no such file\n", .{ f.path, n });
            return .fail;
        };
        // A digital transcript case is judged by its golden, not by `tb`
        // directives (`harness/digital.zig`), so only its polarity is read.
        const refusing = if (std.mem.endsWith(u8, n, ".v"))
            digital.negative(text)
        else
            refuses(tb.Spec.parse(arena, text, null) catch |err| {
                try w.print("FAIL {s}: `//! neighbour {s}`: its directives do not parse: {t}\n", .{ f.path, n, err });
                return .fail;
            });
        if (refusing or !hasDirective(text)) {
            try w.print("FAIL {s}: `//! neighbour {s}` is not a positive fixture\n", .{ f.path, n });
            return .fail;
        }
    }

    // A malformed assertion is the fixture's defect in every compiler, and no
    // `//! xfail` excuses it. Checked before compiling; not on a `//! reject`
    // fixture, which never reaches a transcript.
    const finding = if (d.harness.reject.len != 0) .ok else lint.checkAssertions(source);
    switch (finding) {
        .ok => {},
        // A run-time refusal is its own assertion: the run must end in the
        // named error, which may come before any check.
        .none => if (compiler.runs and strict and d.harness.reject_run.len == 0) {
            try w.print(
                "FAIL {s}: asserts nothing — compiling and running is not an expectation.\n" ++
                    "  Add `CHECK(\"what this proves\", got, want, tol)` from check.vh.\n",
                .{f.path},
            );
            return .fail;
        },
        // Still compiled below in non-strict mode: "does not crash" is a weak
        // claim but it is not nothing, and for an accept/reject-only compiler it
        // is the ONLY claim there was ever going to be.
        .tautology => |site| {
            try w.print(
                "FAIL {s}: assertion cannot fail — got and want are the same expression:\n" ++
                    "    {s}\n" ++
                    "  The want must be a NUMERIC LITERAL a human derived from the LRM.\n",
                .{ f.path, site },
            );
            return .fail;
        },
        .computed_want => |site| {
            try w.print(
                "FAIL {s}: want is an expression, not a literal:\n" ++
                    "    {s}\n" ++
                    "  An expression lets the compiler supply its own expectation, which is\n" ++
                    "  how a wrong answer gets frozen as correct. Write the digits.\n",
                .{ f.path, site },
            );
            return .fail;
        },
    }

    // Buffered: an xfail suppresses it (its reason is on the `//! xfail`
    // line); every other verdict emits it verbatim.
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const result = try compiler.check(compiler.ctx, gpa, io, arena, f, source, d, &aw.writer);
    const xfail = if (compiler.owns_xfail) d.harness.xfail else null;

    switch (result) {
        .met => {
            // Green, and the fixture said it would not be: the gap is closed.
            // A hard FAIL, not a quiet pass — a marker that outlives its
            // limitation silences the next regression at that rule.
            if (xfail != null) {
                try w.print(
                    "FAIL {s}: XPASS — marked xfail, but {s} now does exactly what the\n" ++
                        "  fixture says it must. Delete its `//! xfail` line or its row in\n" ++
                        "  {s}: the limitation is fixed, and a marker outliving it hides the\n" ++
                        "  next regression.\n",
                    .{ f.path, compiler.name, xfail_list },
                );
                return .fail;
            }
            // The probe's verdict is its `ONLY-` line, which a pass would hide.
            if (probe_reject_only) try w.writeAll(aw.written());
            return .pass;
        },
        .unmet => {
            if (xfail) |why| {
                try w.print("XFAIL {s}: known: {s}\n", .{ f.path, why });
                return .xfail;
            }
            try w.writeAll(aw.written());
            return .fail;
        },
        // Not a conformance answer, so the xfail marker does not touch it:
        // `unasserted` proves nothing and cannot show a gap is closed.
        .unasserted => {
            try w.writeAll(aw.written());
            return .unasserted;
        },
    }
}

/// Whether `d` is a refusal, by the compiler (`//! reject`) or by the run
/// (`//! reject-run`): not a legal neighbour.
fn refuses(d: tb.Spec) bool {
    return d.harness.reject.len != 0 or d.harness.reject_run.len != 0;
}

/// Run the fixture in a scratch directory of its own and compare the file it
/// wrote against the golden. Only a runner that RUNS a design is asked: for an
/// accept/reject-only one the fixture asserts nothing it could meet.
fn judgeVcd(arena: std.mem.Allocator, io: Io, compiler: Compiler, f: Fixture, want: digital.VcdExpect, w: *Io.Writer) !Verdict {
    if (!compiler.runs) return .unasserted;
    const given = vera_exe orelse {
        try w.print("FAIL {s}: `//! expect vcd` needs the vera executable, and none was given\n", .{f.path});
        return .fail;
    };
    // Absolute, because the run's working directory is not this one.
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, given, arena);
    const dir = try std.fs.path.join(arena, &.{ options.work_root, "vcd", f.slug });
    try Io.Dir.cwd().createDirPath(io, dir);
    const produced = try std.fs.path.join(arena, &.{ dir, want.produced });
    Io.Dir.cwd().deleteFile(io, produced) catch {};
    const r = try std.process.run(arena, io, .{
        .argv = &.{ exe, "--run", "-I", include_dir, "-I", f.dir(), f.path },
        .cwd = .{ .path = dir },
    });
    if (r.term != .exited or r.term.exited != 0) {
        try w.print("FAIL {s}: vera --run did not succeed ({any})\n{s}", .{ f.path, r.term, r.stderr });
        return .fail;
    }
    const got_text = Io.Dir.cwd().readFileAlloc(io, produced, arena, .limited(1 << 24)) catch {
        try w.print("FAIL {s}: the run wrote no `{s}`\n", .{ f.path, want.produced });
        return .fail;
    };
    const golden = try std.fs.path.join(arena, &.{ f.dir(), want.golden });
    const want_text = Io.Dir.cwd().readFileAlloc(io, golden, arena, .limited(1 << 24)) catch {
        try w.print("FAIL {s}: no golden VCD at {s}\n", .{ f.path, golden });
        return .fail;
    };
    const got = try digital.vcdTokens(arena, got_text);
    const expected = try digital.vcdTokens(arena, want_text);
    for (0..@max(got.len, expected.len)) |i| {
        const g = if (i < got.len) got[i] else "<end of file>";
        const e = if (i < expected.len) expected[i] else "<end of file>";
        if (std.mem.eql(u8, g, e)) continue;
        try w.print("FAIL {s}: VCD token {d} is `{s}`, the golden has `{s}`\n--- produced\n{s}\n", .{ f.path, i, g, e, got_text });
        return .fail;
    }
    return .pass;
}

test "the xfail list: a path, its reason after `#`, comments skipped" {
    const text = "# VerA's\ntests/verilog/16_sdf/a.v # SDF is refused.\n  tests/verilog/b.v\n";
    try std.testing.expectEqualStrings("SDF is refused.", xfailIn(text, "tests/verilog/16_sdf/a.v").?);
    try std.testing.expectEqualStrings("", xfailIn(text, "tests/verilog/b.v").?);
    try std.testing.expect(xfailIn(text, "tests/verilog/16_sdf") == null);
    try std.testing.expect(xfailIn(text, "# VerA's") == null);
}

test "a directive is found after the hand-derivation, not just in a header" {
    // Directives follow the header's LRM quote and derivation, often kilobytes
    // into the file, so the whole file must be scanned.
    var prose: [4096]u8 = @splat('x');
    const late = try std.testing.allocator.print(
        "// {s}\n//! reject E0205\n",
        .{prose[0..]},
    );
    defer std.testing.allocator.free(late);
    try std.testing.expect(hasDirective(late));

    try std.testing.expect(hasDirective("//! reject E0205\n"));
    try std.testing.expect(hasDirective("  \t //! lrm 9.4.1\r\n"));

    // A design a test loads is not a fixture: no directive, no collection.
    try std.testing.expect(!hasDirective("module m; endmodule\n"));
    try std.testing.expect(!hasDirective(""));

    // `//!` has to START the trimmed line. A plain substring search would take
    // this string literal for a directive and collect a file that asserts
    // nothing.
    try std.testing.expect(!hasDirective("initial $display(\"//! reject\");\n"));
}

test "digital opt-in is excluded from analog fixture collection" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const marked = "//! reject no arguments\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "negative.v", .data = marked });
    try tmp.dir.writeFile(io, .{ .sub_path = "dump.v", .data = "//! expect vcd a.vcd == a.golden.vcd\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "analog.va", .data = marked });
    try tmp.dir.writeFile(io, .{ .sub_path = "positive.v", .data = "//! lrm 9.10\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "positive.expected.txt", .data = "ok\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "host_design.va", .data = "module m; endmodule\n" });
    try std.testing.expect(fixtureExt(arena.allocator(), io, tmp.dir, "negative.v") == null);
    try std.testing.expectEqualStrings(".v", fixtureExt(arena.allocator(), io, tmp.dir, "dump.v").?);
    try std.testing.expectEqualStrings(".va", fixtureExt(arena.allocator(), io, tmp.dir, "analog.va").?);
    try std.testing.expect(fixtureExt(arena.allocator(), io, tmp.dir, "positive.v") == null);
    // A `.va` a host test loads carries no directive and is not collected.
    try std.testing.expect(fixtureExt(arena.allocator(), io, tmp.dir, "host_design.va") == null);
}

// The sub-files hold their own tests; Zig collects them only through a reference.
test {
    _ = lint;
    _ = digital;
}
