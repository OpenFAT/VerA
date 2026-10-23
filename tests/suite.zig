//! The suite runner behind `zig build suite -- <mode>`, `test-spice` and the canary in `test`:
//! fixtures -> verdicts on stderr and a timing table on stdout. `Suite.main`
//! dispatches on the mode word; each mode is one namespace below:
//!   (none)       `Suite`: `benchmark`, the depth pass and the timing table
//!   `--sweep`    `SizeSweep`, the generated size sweep
//!   `devices`    `Devices` (`--native`: `Native`, `--fuzz`: `Fuzz`,
//!   `ieee1364`     `--coverage`: `Ieee1364`)
//!   `vpi`        `CFixtures`
//!   `spice`      `SpiceDecks`
//!   `golden`     `Golden`, the before/after snapshot of what vera says
//!   `canary`     `Canary`, the wrong-on-purpose fixtures the judge must FAIL
//! `Fixtures` is the harness every mode shares (the fixture walk, the verdict
//! algebra, the parallel run); `Analog` plugs VerA into it; `Lint` and
//! `Digital` are its tables; `Child` runs a process to completion.
//!
//! One file: a nested namespace may not redeclare a name of the file scope
//! (`std`, say), so the file scope declares only `main`, the test below and
//! the namespaces, and each namespace keeps its own imports.
//!
//! `tools/conformance.py` parses the `pass fail unasserted xfail` row `Suite`
//! prints: that row's text is frozen.
//!
//! The fixtures are the VAMS Conformance Suite's `tests/` (`suite_options.fixture_root`,
//! the submodule `tests/conformance`): `verilog-a/`, `verilog-ams/` (its `digital/`
//! the digital-context cases), `spice/`, `verilog/` (IEEE 1364-2005) and `include/`
//! (`check.vh`); its `netlist/` is ESPice's. Every path a verdict prints is relative
//! to that root. The suite's conventions hold: a source `include`s the annex D files
//! it uses (every compile sets `require_std_includes`), a `.v` names its extra inputs
//! with `//@` lines, and no fixture carries `//! xfail`: VerA's own expected failures
//! are `<vera_root>/xfail`. `vera_root` (`tests/conformance/vera`) also holds the
//! canary and the per-chapter `CLAUSES.tsv`.

pub fn main(init: @import("std").process.Init) !u8 {
    return Suite.main(init);
}

// Zig collects `test` blocks only from the containers the root references, so
// every namespace's tests run through this block.
test {
    _ = Suite;
    _ = Fixtures;
    _ = Analog;
    _ = Canary;
    _ = CFixtures;
    _ = Child;
    _ = Devices;
    _ = Digital;
    _ = Fuzz;
    _ = Golden;
    _ = Ieee1364;
    _ = Lint;
    _ = Native;
    _ = SpiceDecks;
    _ = SizeSweep;
}

const Suite = struct {
    //! `benchmark`: the depth pass (compile, build and run every testbench) and
    //! the timing table (one row per fixture, walk order, so two runs diff;
    //! times from a separate sequential accept/reject pass). `main` is the
    //! suite's entry point and dispatches on the mode word.
    const std = @import("std");
    const vera = @import("vera");
    const harness = Fixtures;
    const torture = Analog;
    const ieee1364 = Ieee1364;
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
    ///   zig build suite -- --strict             # unasserted and xfail FAIL
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
                var e = Io.File.stderr().writer(io, &e_buf);
                try e.interface.print("benchmark: unknown flag `{s}`\n", .{arg});
                try e.interface.flush();
                return 2;
            } else cfg.filter = arg;
        }
        // `--fixture-root=DIR` is how a human writes it; resolved once, so every
        // FAIL line names an absolute path.
        cfg.root = std.fs.path.resolveAlloc(arena, &.{cfg.root}) catch cfg.root;

        var out_buf: [1 << 16]u8 = undefined;
        var stdout = Io.File.stdout().writer(io, &out_buf);
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
            const d = vera.tb.parse(pa, source) catch vera.tb.Directives{};

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
                if (d.reject.len != 0) "refuse" else "compile",
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
};

const Fixtures = struct {
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
    //! and `--strict` fails unasserted and XFAIL fixtures.

    const std = @import("std");
    const vera = @import("vera");
    /// `fixture_root` and `vera_root`, from `build.zig`; shared by every runner
    /// so all compilers are judged on the same fixtures.
    const options = @import("suite_options");
    const lint = Lint;
    const digital = Digital;

    const Io = std.Io;
    /// `--fixture-opt=` names. Zig 0.17 renamed `std.lang.Optimize`'s tags
    /// (`fast`, ...); the flag keeps the names it always took.
    const optimize_names = std.StaticStringMap(std.lang.Optimize).initComptime(.{
        .{ "Debug", .debug },
        .{ "ReleaseSafe", .safe },
        .{ "ReleaseFast", .fast },
        .{ "ReleaseSmall", .small },
    });

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
    pub const xfail_list = options.vera_root ++ "/xfail";

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

    test "the xfail list: a path, its reason after `#`, comments skipped" {
        const text = "# VerA's\ntests/verilog/16_sdf/a.v # SDF is refused.\n  tests/verilog/b.v\n";
        try std.testing.expectEqualStrings("SDF is refused.", xfailIn(text, "tests/verilog/16_sdf/a.v").?);
        try std.testing.expectEqualStrings("", xfailIn(text, "tests/verilog/b.v").?);
        try std.testing.expect(xfailIn(text, "tests/verilog/16_sdf") == null);
        try std.testing.expect(xfailIn(text, "# VerA's") == null);
    }

    /// `std.mem.sort` order for strings: bytewise.
    pub fn strLess(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

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
            d: vera.tb.Directives,
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
        /// `--list=<file>`: only the fixtures named in it, one path under the
        /// root per line (a mutation run judges a mutant by the fixtures that
        /// cite the mutated file's clauses, `tools/conformance.py mutate`).
        list: ?[]const u8 = null,
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
        fixture_backend: ?vera.orchestrator.Backend = null,
        /// `--no-batch` builds every fixture testbench alone (`Compiler.prepare`
        /// is skipped): the escape hatch, and the baseline a batched run is
        /// compared against.
        batch: bool = true,
        /// `--verdicts=<file>`: one `<verdict>\t<path under the root>` row per
        /// fixture, sorted, for `tools/conformance.py`'s ratchet and metric
        /// (§3.7).
        verdicts: ?[]const u8 = null,

        /// Returns the defaults, with `jobs` from `defaultJobs`.
        pub fn init() Config {
            return .{ .jobs = defaultJobs() };
        }
    };

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

    /// The default never exceeds this many concurrent fixture builds, whatever
    /// the core and RAM count. 2026-10-17: a gate's suite (15 jobs by `job_ram`),
    /// a second suite and other projects' builds on the same 31 GB host ran it out
    /// of memory overnight: `job_ram` sizes against TOTAL memory, so two suites
    /// each assume the whole machine. `-j` still overrides.
    const max_default_jobs = 8;

    /// RAM budgeted per concurrent fixture build: 4x the measured mean, for the
    /// large devices and the other processes on the host.
    const job_ram: u64 = 2 << 30;

    /// Prints `why` and the usage line to stderr; returns exit code 2.
    pub fn usage(io: Io, why: []const u8) !u8 {
        var buf: [256]u8 = undefined;
        var e = Io.File.stderr().writer(io, &buf);
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
        else if (std.mem.startsWith(u8, a, "--verdicts=")) cfg.verdicts = a["--verdicts=".len..] //
        else if (std.mem.startsWith(u8, a, "--list=")) cfg.list = a["--list=".len..] //
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

    /// `-j8`, `--jobs=8`. Null when `a` is not that flag at all.
    fn numeric(a: []const u8, prefix: []const u8) ?usize {
        if (!std.mem.startsWith(u8, a, prefix)) return null;
        return std.fmt.parseInt(usize, a[prefix.len..], 10) catch null;
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
        var stderr = Io.File.stderr().writer(io, &stderr_buf);
        const w = &stderr.interface;

        var fixtures = try collect(arena, io, cfg.root, &ams_dirs, cfg.filter);
        if (cfg.list) |path| fixtures = try keepListed(arena, io, path, cfg.root, fixtures);
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
        if (cfg.verdicts) |path| try writeVerdicts(io, path, cfg.root, fixtures, verdicts);

        try summarize(compiler, counts, fixtures.len, w);
        try w.flush();
        if (tally) |t| t.* = counts;
        return if (counts.failed == 0 and
            !(strict and (counts.unasserted != 0 or counts.xfail != 0))) 0 else 1;
    }

    /// `--list=`: the fixtures among `all` whose path under `root` is a line of
    /// the file at `path`.
    fn keepListed(arena: std.mem.Allocator, io: Io, path: []const u8, root: []const u8, all: []const Fixture) ![]const Fixture {
        const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 22));
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len != 0) try wanted.put(arena, line, {});
        }
        var kept: std.ArrayList(Fixture) = .empty;
        for (all) |f| {
            const rel = if (std.mem.startsWith(u8, f.path, root)) std.mem.trimStart(u8, f.path[root.len..], "/") else f.path;
            if (wanted.contains(rel)) try kept.append(arena, f);
        }
        return kept.items;
    }

    /// `--verdicts=`: the run's verdicts as `<verdict>\t<path under root>` rows,
    /// in walk (path) order, so two runs diff by name.
    fn writeVerdicts(io: Io, path: []const u8, root: []const u8, fixtures: []const Fixture, verdicts: []const Verdict) !void {
        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        for (fixtures, verdicts) |f, v| {
            const rel = if (std.mem.startsWith(u8, f.path, root)) std.mem.trimStart(u8, f.path[root.len..], "/") else f.path;
            try fw.interface.print("{t}\t{s}\n", .{ v, rel });
        }
        try fw.interface.flush();
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
                "  quietly hide a regression. (`--strict` fails on these.)\n",
            .{ c.xfail, compiler.name, compiler.name },
        );
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
    /// The whole file is scanned with `tb.parse`'s line rule (see `hasDirective`).
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

    /// Does this source carry a `//!` directive? `tb.parse`'s own line rule, and it
    /// must stay that rule: this decides whether a file is collected and `tb.parse`
    /// decides whether it asserts anything, so a disagreement collects a fixture
    /// that then reports nothing.
    pub fn hasDirective(source: []const u8) bool {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            if (std.mem.startsWith(u8, std.mem.trim(u8, raw, " \t\r"), "//!")) return true;
        }
        return false;
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
        // `tb` directive describes; it is judged before `tb.parse` for that reason.
        if (digital.vcdExpectation(source)) |want| return judgeVcd(arena, io, compiler, f, want, w);

        // The `//!` lines are read from the RAW source: the preprocessor deletes
        // comments (§2.4), so after compilation they are gone.
        var d = vera.tb.parse(arena, source) catch |err| {
            try w.print("FAIL {s}: `//!` directive: {t}\n", .{ f.path, err });
            return .fail;
        };
        // VerA's own list stands in for the `//! xfail` line the suite dropped.
        if (d.xfail == null) d.xfail = try listedXfail(arena, io, f.root, f.path);

        const verdict = try decide(gpa, io, arena, compiler, f, source, d, strict, w);

        // A verdict that names only the file makes the reader go and find the rule.
        // If the fixture said which clause it pins, say it here — for an xfail too,
        // where the cite IS the requirement being carried unmet.
        switch (verdict) {
            .fail, .xfail => if (d.lrm.len != 0) {
                try w.print("  LRM", .{});
                for (d.lrm) |section| try w.print(" §{s}", .{section});
                try w.print("\n", .{});
            },
            .pass, .unasserted => {},
        }
        return verdict;
    }

    fn decide(
        gpa: std.mem.Allocator,
        io: Io,
        arena: std.mem.Allocator,
        compiler: Compiler,
        f: Fixture,
        source: []const u8,
        d: vera.tb.Directives,
        strict: bool,
        w: *Io.Writer,
    ) !Verdict {
        // A perturbed run asks one question of a passing positive fixture: does
        // each check fail when its want is wrong? A refusal has no want, and an
        // xfail does not pass to begin with.
        if (perturb != null and (d.reject.len != 0 or d.reject_run.len != 0 or d.xfail != null)) return .pass;
        if (probe_reject_only and (d.reject.len == 0 or d.reject_only or d.xfail != null)) return .pass;

        // The other half of a refusal: each named neighbour is a collected
        // positive fixture, so the pair shows a restriction and not a blanket
        // refusal. Whether it passes is read from the same run's
        // verdicts by `tools/conformance.py`.
        for (d.neighbours) |n| {
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
                refuses(vera.tb.parse(arena, text) catch |err| {
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
        const finding = if (d.reject.len != 0) .ok else lint.checkAssertions(source);
        switch (finding) {
            .ok => {},
            // A run-time refusal is its own assertion: the run must end in the
            // named error, which may come before any check.
            .none => if (compiler.runs and strict and d.reject_run.len == 0) {
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
        const xfail = if (compiler.owns_xfail) d.xfail else null;

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

    /// Whether `d` is a refusal, by the compiler (`//! reject`) or by the run
    /// (`//! reject-run`): not a legal neighbour.
    fn refuses(d: vera.tb.Directives) bool {
        return d.reject.len != 0 or d.reject_run.len != 0;
    }

    /// `--probe-reject-only`: judges each `//! reject` fixture as if it were
    /// `//! reject-only` and prints `ONLY-OK <path>` or `ONLY-NO <path>: <code>`,
    /// the worklist for promoting refusals that already refuse alone
    /// (`tools/conformance.py promote-reject-only`). Positive fixtures are not run.
    pub var probe_reject_only: bool = false;

    /// The `vera` executable, for the one fixture no in-process runner can judge:
    /// a `//! expect vcd` digital run, whose evidence is a FILE the run writes.
    /// Set once by `tests/suite.zig`, which is handed the path; read-only after.
    pub var vera_exe: ?[]const u8 = null;

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
};

const Analog = struct {
    //! VerA as a harness `Compiler` for `zig build suite`: fixture -> verdict.
    //! `//! reject` must refuse with every substring in the diagnostic; `//! warn`
    //! must compile with each substring in a warning; anything else must compile,
    //! build a native testbench, run, and print `ok=1` for every assertion. The
    //! `want` of an assertion is a hand-derived literal, so VerA never supplies its
    //! own expectation and no golden transcript exists.

    const std = @import("std");
    const vera = @import("vera");
    const harness = Fixtures;
    const digital = Digital;
    const options = @import("suite_options");
    /// The suite's fixture root and LRM directory, shared with `Fixtures`.
    const suite = options;

    const Io = std.Io;
    const Fixture = harness.Fixture;
    const Result = harness.Result;

    /// VerA at full depth: compile, build a testbench, run it, read the `ok=`
    /// columns. `ctx` must outlive the returned plug.
    pub fn compiler(ctx: *Ctx) harness.Compiler {
        return .{
            .name = "vera",
            .runs = true,
            .owns_xfail = true,
            .ctx = ctx,
            .check = check,
            .prepare = prepare,
        };
    }

    /// `compiler`'s state: the suite's knobs, and the testbenches `prepare` built
    /// in batches.
    pub const Ctx = struct {
        /// Borrowed for `fixture_opt`/`fixture_backend`.
        cfg: *const harness.Config,
        /// Fixture path -> the batch binary that stands in for its testbench.
        /// Written by `prepare` alone, before any `check` reads it.
        batched: std.StringHashMapUnmanaged(Batched) = .empty,
        /// The batch binaries' paths, owned by the `gpa` given to `prepare`.
        bins: std.ArrayList([]const u8) = .empty,

        /// Frees what `prepare` allocated; `gpa` must be the one it was given.
        pub fn deinit(ctx: *Ctx, gpa: std.mem.Allocator) void {
            for (ctx.bins.items) |b| gpa.free(b);
            ctx.bins.deinit(gpa);
            ctx.batched.deinit(gpa);
        }
    };

    /// One fixture's member slot in a batch binary.
    const Batched = struct { bin: []const u8, index: usize };

    /// Fixtures per batch, in walk order. A batch build pays the compiler's fixed
    /// cost once instead of `batch_size` times; larger batches serialise more of
    /// the run behind one build and hold more in one compiler's memory.
    const batch_size = 8;

    /// The compile -> batch-build half of the run: every fixture is compiled and
    /// staged as `check` would, and each run of `batch_size` consecutive fixtures
    /// whose testbench is a plain analog runner is built as one binary (the mixed
    /// runner links `sim` and stays one build per fixture). `check` then compiles
    /// again (milliseconds), finds the batch binary, and runs it in place of its
    /// own build. A batch that does not build marks nothing: its fixtures build
    /// one by one in `check`, so a failure names its own fixture.
    fn prepare(ctx_ptr: *anyopaque, gpa: std.mem.Allocator, io: Io, fixtures: []const Fixture, jobs: usize) anyerror!void {
        // ponytail: argv[0] dispatch goes through a symlink; Windows builds one by one.
        if (@import("builtin").os.tag == .windows) return;
        const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
        const chunks = try gpa.alloc(Chunk, (fixtures.len + batch_size - 1) / batch_size);
        defer gpa.free(chunks);
        @memset(chunks, .{});
        var pool: Pool = .{ .gpa = gpa, .io = io, .ctx = ctx, .fixtures = fixtures, .chunks = chunks };
        var group: Io.Group = .init;
        var hands: usize = 0;
        while (hands < jobs) : (hands += 1) group.concurrent(io, Pool.work, .{&pool}) catch break;
        if (hands == 0) pool.work();
        try group.await(io);

        for (chunks, 0..) |c, k| {
            const bin = c.bin orelse continue;
            try ctx.bins.append(gpa, bin);
            const lo = k * batch_size;
            for (c.member[0..c.n], 0..) |fi, i| try ctx.batched.put(gpa, fixtures[lo + fi].path, .{ .bin = bin, .index = i });
        }
    }

    /// One batch's outcome: which of its fixtures (offsets in the chunk, each
    /// below `batch_size`) are members, in member order, and the binary when it
    /// built. One per `batch_size` fixtures; `member[0..n]` is what is valid.
    const Chunk = struct {
        member: [batch_size]u8 = undefined,
        n: u8 = 0,
        bin: ?[]const u8 = null,
    };

    // Budget: the offsets are below `batch_size`, so a byte each; `usize` offsets
    // made a row 88 B.
    comptime {
        std.debug.assert(batch_size <= std.math.maxInt(u8));
        std.debug.assert(@sizeOf(Chunk) == 32);
    }

    /// `prepare`'s work queue: one chunk of fixtures per take.
    const Pool = struct {
        gpa: std.mem.Allocator,
        io: Io,
        ctx: *const Ctx,
        fixtures: []const Fixture,
        chunks: []Chunk,
        next: std.atomic.Value(usize) = .init(0),

        fn work(pool: *Pool) void {
            while (true) {
                const k = pool.next.fetchAdd(1, .monotonic);
                if (k >= pool.chunks.len) return;
                pool.chunk(k) catch {}; // a batch that fails marks nothing; `check` builds alone
            }
        }

        fn chunk(pool: *Pool, k: usize) !void {
            var arena_state: std.heap.ArenaAllocator = .init(pool.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const lo = k * batch_size;
            const fs = pool.fixtures[lo..@min(lo + batch_size, pool.fixtures.len)];
            var staged: [batch_size]vera.tb.Staged = undefined;
            const c = &pool.chunks[k];
            for (fs, 0..) |f, fi| {
                const source = Io.Dir.cwd().readFileAlloc(pool.io, f.path, arena, .limited(1 << 20)) catch continue;
                if (digital.vcdExpectation(source) != null) continue;
                const d = vera.tb.parse(arena, source) catch continue;
                if (d.reject.len != 0) continue;
                var sink: ?vera.tb.Staged = null;
                var discard: Io.Writer.Discarding = .init(&.{});
                _ = runAndCheck(pool.gpa, pool.io, arena, pool.ctx, f, source, d, &discard.writer, &sink) catch continue;
                staged[c.n] = sink orelse continue;
                c.member[c.n] = @intCast(fi);
                c.n += 1;
            }
            if (c.n < 2) return; // one member gains nothing over its own build
            const cfg = pool.ctx.cfg;
            const built = try vera.tb.buildBatch(pool.gpa, pool.io, staged[0..c.n], .{
                .work_dir = try arena.print("{s}/torture-batch/{d}", .{ options.work_root, k }),
                .contract = options.contract,
                .name = "batch",
                .zig_exe = options.zig_exe,
                .optimize = cfg.fixture_opt,
                .backend = cfg.fixture_backend,
                .strip = true,
            });
            switch (built) {
                .ok => |bin| c.bin = bin,
                .failed => |text| pool.gpa.free(text),
            }
        }
    };

    /// VerA held to what a foreign compiler is held to (accept or refuse only), so
    /// the head-to-head's agreement column asks both sides the same question.
    pub fn acceptRejectCompiler() harness.Compiler {
        return .{
            .name = "vera",
            .runs = false,
            // `//! xfail` marks debt against the full claim; a fixture that compiles
            // and then computes a wrong number is met here and would XPASS.
            .owns_xfail = false,
            .ctx = &no_ctx,
            .check = checkAcceptReject,
        };
    }

    var no_ctx: u8 = 0;

    fn checkAcceptReject(
        _: *anyopaque,
        gpa: std.mem.Allocator,
        _: Io,
        _: std.mem.Allocator,
        f: Fixture,
        source: []const u8,
        d: vera.tb.Directives,
        w: *Io.Writer,
    ) anyerror!Result {
        var outcome = try compileFixture(gpa, f, source, d);
        defer outcome.deinit(gpa);
        const must_reject = d.reject.len != 0;
        if ((outcome == .accepted) == !must_reject) return .met;
        if (must_reject) {
            try w.print("FAIL {s}: the LRM says this must not compile, and vera accepted it.\n", .{f.path});
        } else {
            try w.print("FAIL {s}: must compile, and vera refused it: {s}\n", .{ f.path, outcome.refused.error_name });
        }
        return .unmet;
    }

    /// One accept/reject compilation, the unit the head-to-head times: returns the
    /// emitted device's size, or null when VerA refused. No testbench is built, so
    /// no `zig build-exe` time lands in VerA's number.
    pub fn compileOnce(gpa: std.mem.Allocator, f: Fixture, source: []const u8, d: vera.tb.Directives) !?usize {
        var outcome = try compileFixture(gpa, f, source, d);
        defer outcome.deinit(gpa);
        return switch (outcome) {
            .accepted => |n| n,
            .refused => null,
        };
    }

    fn check(
        ctx: *anyopaque,
        gpa: std.mem.Allocator,
        io: Io,
        arena: std.mem.Allocator,
        f: Fixture,
        source: []const u8,
        d: vera.tb.Directives,
        w: *Io.Writer,
    ) anyerror!Result {
        const c: *const Ctx = @ptrCast(@alignCast(ctx));
        if (d.reject.len != 0) return verifyRejected(gpa, f, source, d, w);
        return runAndCheck(gpa, io, arena, c, f, source, d, w, null);
    }

    /// Why a fixture failed to produce a device, in the vocabulary the `//! reject`
    /// directives are written in.
    const Failure = struct {
        /// `@errorName` of the returned error, or a synthetic name for the two
        /// failure modes that are not Zig errors (see `compileFixture`).
        error_name: []const u8,
        diags: vera.diag.Bag,
        /// Non-null only for `GeneratedCompileError`; owned by `gpa`.
        generated: ?[]const u8 = null,
    };

    /// What one compilation did. `accepted` carries the device's size, not its
    /// text: nothing downstream reads the text.
    const Outcome = union(enum) {
        accepted: usize,
        refused: Failure,

        fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
            switch (self.*) {
                .accepted => {},
                .refused => |*bad| {
                    if (bad.generated) |g| gpa.free(g);
                    bad.diags.deinit(gpa);
                },
            }
        }
    };

    // ---------------------------------------------------------------------------
    // The reject half: the expected behavior is a diagnostic
    // ---------------------------------------------------------------------------

    fn verifyRejected(
        gpa: std.mem.Allocator,
        f: Fixture,
        source: []const u8,
        d: vera.tb.Directives,
        w: *Io.Writer,
    ) !Result {
        var outcome = try compileFixture(gpa, f, source, d);
        defer outcome.deinit(gpa);
        const bad = switch (outcome) {
            .accepted => {
                try w.print("FAIL {s}: expected a diagnostic, but it compiled cleanly\n", .{f.path});
                return .unmet;
            },
            .refused => |b| b,
        };

        for (d.reject) |pattern| {
            if (!failureContains(bad, pattern)) {
                try w.print("FAIL {s}: diagnostic substring not found: \"{s}\"\n", .{ f.path, pattern });
                try w.print("  error: {s}\n", .{bad.error_name});
                try printDiags(bad, w);
                return .unmet;
            }
        }
        // `//! reject-only`: the refusal is the named rule's alone. An error no
        // pattern names is a second refusal riding inside this one, which a plain
        // `reject` cannot see.
        if (harness.probe_reject_only) {
            for (0..bad.diags.count()) |i| {
                if (bad.diags.at(i).severity != .err) continue;
                for (d.reject) |pattern| {
                    if (diagSays(&bad.diags, i, pattern)) break;
                } else {
                    try w.print("ONLY-NO {s}: {t}\n", .{ f.path, bad.diags.at(i).code });
                    return .met;
                }
            }
            try w.print("ONLY-OK {s}\n", .{f.path});
            return .met;
        }
        if (d.reject_only) for (0..bad.diags.count()) |i| {
            if (bad.diags.at(i).severity != .err) continue;
            for (d.reject) |pattern| {
                if (diagSays(&bad.diags, i, pattern)) break;
            } else {
                const e = bad.diags.at(i);
                try w.print("FAIL {s}: `//! reject-only`, and a second error fired: {t} {s}\n", .{ f.path, e.code, vera.diag.info(e.code).title });
                try printDiags(bad, w);
                return .unmet;
            }
        };
        return .met;
    }

    /// One compilation. Two failure modes are not Zig errors and get synthetic
    /// names, matching the vocabulary the fixtures use:
    ///   `DiagnosticsReported`  — compiled, but a stage reported a message.
    ///   `GeneratedCompileError` — codegen deliberately emitted `@compileError`.
    fn compileFixture(gpa: std.mem.Allocator, f: Fixture, source: []const u8, d: vera.tb.Directives) !Outcome {
        var diags: vera.diag.Bag = .init(gpa);
        // `.build` (not `.lint`) so stage 6 runs: some fixtures are rejected by
        // codegen emitting `@compileError`, which `.lint` would never see.
        var result = vera.compileSourceOpts(gpa, source, .build, .{
            .file_name = f.path,
            .include_dirs = &.{ f.dir(), harness.include_dir },
            // The suite's convention: a source includes the annex D files it uses.
            .require_std_includes = true,
            .diags = &diags,
            // Annex E.2: the fixture's `//! spice` cards, read as a netlist.
            .spice_netlist = d.spice,
            .spice_path = f.path,
            .discipline_resolution = d.discipline_resolution,
        }) catch |err| {
            if (err == error.OutOfMemory) {
                diags.deinit(gpa);
                return error.OutOfMemory;
            }
            return .{ .refused = .{ .error_name = @errorName(err), .diags = diags } };
        };
        defer result.deinit();

        if (diags.failed()) {
            return .{ .refused = .{ .error_name = "DiagnosticsReported", .diags = diags } };
        }

        const generated = result.generateDevice() catch |err| {
            if (err == error.OutOfMemory) {
                diags.deinit(gpa);
                return error.OutOfMemory;
            }
            return .{ .refused = .{ .error_name = @errorName(err), .diags = diags } };
        };
        if (diags.failed()) {
            return .{ .refused = .{ .error_name = "DiagnosticsReported", .diags = diags } };
        }
        // The compiler's own flag, not a text search: a kernel may carry
        // `@compileError` in a guard that never fires (`$table_model`'s does).
        if (result.device_has_compile_error) {
            // Transfer the GPA-owned text before dropping the compilation.
            result.device.text = "";
            return .{ .refused = .{
                .error_name = "GeneratedCompileError",
                .diags = diags,
                .generated = generated,
            } };
        }

        diags.deinit(gpa);
        return .{ .accepted = generated.len };
    }

    /// Whether the failure matches a `//! reject` pattern: a code, an error name,
    /// `@compileError` text, a diagnostic substring, or a phase label derived from
    /// the failure:
    ///   `DiagnosticsReported`  the failure carries at least one diagnostic.
    ///   `ParseError`           every diagnostic came from preprocess or parse.
    fn failureContains(f: Failure, pattern: []const u8) bool {
        if (asCode(pattern) != null) {
            for (0..f.diags.count()) |i| if (diagSays(&f.diags, i, pattern)) return true;
            return false;
        }
        if (std.mem.find(u8, f.error_name, pattern) != null) return true;
        if (f.generated) |g| if (std.mem.find(u8, g, pattern) != null) return true;

        if (!f.diags.isEmpty()) {
            if (std.mem.eql(u8, pattern, "DiagnosticsReported")) return true;
            if (std.mem.eql(u8, pattern, "ParseError")) {
                for (0..f.diags.count()) |i| switch (f.diags.at(i).stage) {
                    .preprocess, .parse => {},
                    .lower, .proof, .codegen, .run => return false,
                };
                return true;
            }
        }
        for (0..f.diags.count()) |i| if (diagSays(&f.diags, i, pattern)) return true;
        return false;
    }

    /// Does diagnostic `i` say `pattern`: its code when `pattern` is one, else a
    /// substring of its message, point, catalogue title or a note.
    fn diagSays(bag: *const vera.diag.Bag, i: usize, pattern: []const u8) bool {
        const d = bag.at(i);
        if (asCode(pattern)) |want| return d.code == want;
        // The title too: much wording lives in `Info.title`, not the message.
        if (std.mem.find(u8, d.message, pattern) != null) return true;
        if (std.mem.find(u8, d.point, pattern) != null) return true;
        if (std.mem.find(u8, vera.diag.info(d.code).title, pattern) != null) return true;
        var nbuf: [vera.diag.max_children]vera.diag.Note = undefined;
        for (bag.notes(d, &nbuf)) |n| {
            if (std.mem.find(u8, n.text, pattern) != null) return true;
        }
        return false;
    }

    /// `//! warn`: every pattern names a warning in `bag`. `//! nowarn`: `bag`
    /// holds no warning. Detail goes to `w` on a miss.
    fn warningsMet(bag: *vera.diag.Bag, f: Fixture, d: vera.tb.Directives, w: *Io.Writer) !bool {
        for (d.warn) |pattern| {
            for (0..bag.count()) |i| {
                if (bag.at(i).severity == .warning and diagSays(bag, i, pattern)) break;
            } else {
                try w.print("FAIL {s}: no warning matches: \"{s}\"\n", .{ f.path, pattern });
                vera.diag.render(bag, w, .{ .explain_hint = false, .summary = false }) catch {};
                return false;
            }
        }
        if (d.nowarn and bag.count() != 0) {
            try w.print("FAIL {s}: `//! nowarn`, and the compile warned:\n", .{f.path});
            vera.diag.render(bag, w, .{ .explain_hint = false, .summary = false }) catch {};
            return false;
        }
        return true;
    }

    /// A directive is either a CODE (`E0313`, `W0650`) or a message substring.
    ///
    /// Codes are preferred: they are stable and pin which rule fired.
    fn asCode(pattern: []const u8) ?vera.diag.Code {
        if (pattern.len != 5) return null;
        if (pattern[0] != 'E' and pattern[0] != 'W') return null;
        for (pattern[1..]) |c| if (!std.ascii.isDigit(c)) return null;
        return std.meta.stringToEnum(vera.diag.Code, pattern);
    }

    fn printDiags(f: Failure, w: *Io.Writer) !void {
        // Render the real thing, so a failing fixture shows exactly what a user
        // would see — snippet, carets, notes and all. Colour is off: this output is
        // read from a log as often as from a terminal.
        var bag = f.diags;
        vera.diag.render(&bag, w, .{ .explain_hint = false, .summary = false }) catch {};
        // A `@compileError` carries the whole reason; without it
        // "GeneratedCompileError" says nothing about WHICH construct codegen refused.
        if (f.generated) |g| {
            var rest = g;
            while (std.mem.find(u8, rest, "@compileError")) |at| {
                const line_end = std.mem.findScalar(u8, rest[at..], '\n') orelse rest.len - at;
                try w.print("  codegen: {s}\n", .{rest[at .. at + line_end]});
                rest = rest[at + line_end ..];
            }
        }
    }

    // ---------------------------------------------------------------------------
    // The run half: the expected behavior is a transcript the model asserts itself
    // ---------------------------------------------------------------------------

    fn runAndCheck(
        gpa: std.mem.Allocator,
        io: Io,
        arena: std.mem.Allocator,
        ctx: *const Ctx,
        f: Fixture,
        source: []const u8,
        d: vera.tb.Directives,
        w: *Io.Writer,
        /// `prepare`'s mode: stage a plain testbench's files here instead of
        /// building and running it (left null for a mixed one).
        stage_into: ?*?vera.tb.Staged,
    ) !Result {
        const cfg = ctx.cfg;
        // `--perturb`: check.vh moves every want by a relative δ.
        // A define ahead of the text, so the first `include "check.vh"` sees it,
        // and an IEEE 1364 §19.7 `line after it, so the fixture's own §10.7
        // `__LINE__ is not moved down by the define's line.
        const compiled_src = if (harness.perturb) |p| try arena.print("`define VERA_PERTURB {e}\n`line 1 \"{s}\" 0\n{s}", .{ p, f.path, source }) else source;
        // Stages 1-6 with §9.4 display ON. W0650 is about speed, and every fixture
        // that probes a node trips it; allowing it here keeps the transcript about
        // the model rather than about float modes — unless a `//! warn` names it.
        var diags: vera.diag.Bag = .init(gpa);
        defer diags.deinit(gpa);
        var levels: vera.diag.Levels = .empty;
        defer levels.deinit(gpa);
        for (d.warn) |p| {
            if (std.mem.eql(u8, p, "W0650")) break;
        } else try levels.set(gpa, .W0650, .allow);

        var opts: vera.Options = .{
            .file_name = f.path,
            .include_dirs = &.{ f.dir(), harness.include_dir },
            .require_std_includes = true,
            .diags = &diags,
            .lint = levels,
            .display = if (d.display_record) .record else .emit,
            .spice_netlist = d.spice,
            .spice_path = f.path,
            .discipline_resolution = d.discipline_resolution,
        };
        var result = vera.compileSourceOpts(gpa, compiled_src, .build, opts) catch |err| {
            try w.print("FAIL {s}: did not compile: {t}\n", .{ f.path, err });
            vera.diag.render(&diags, w, .{ .explain_hint = false, .summary = false }) catch {};
            return .unmet;
        };
        defer result.deinit();
        // §3.4 a `//! param` card value for a shape parameter is a compile-time
        // value: compile again for it, as `vera --emit-exe` does.
        opts.param_overrides = try vera.tb.shapeOverrides(arena, d, result.lowered);
        if (opts.param_overrides.len != 0) {
            diags.deinit(gpa);
            diags = .init(gpa);
            const again = vera.compileSourceOpts(gpa, compiled_src, .build, opts) catch |err| {
                try w.print("FAIL {s}: did not compile: {t}\n", .{ f.path, err });
                vera.diag.render(&diags, w, .{ .explain_hint = false, .summary = false }) catch {};
                return .unmet;
            };
            result.deinit();
            result = again;
        }

        const device = result.generateDevice() catch |err| {
            try w.print("FAIL {s}: codegen failed: {t}\n", .{ f.path, err });
            return .unmet;
        };
        if (result.device_has_compile_error) {
            try w.print("FAIL {s}: codegen refused a construct (generated output is not usable)\n", .{f.path});
            return .unmet;
        }
        // An LLVM intrinsic link-fails under `--zig-backend=native`.
        if (std.mem.find(u8, device, "extern fn @\"llvm.") != null) {
            try w.print("FAIL {s}: the device declares an `llvm.*` intrinsic; it cannot build under the self-hosted backend\n", .{f.path});
            return .unmet;
        }
        try vera.tb.warnGridEvents(&diags, result.lowered, result.mir);
        if (!try warningsMet(&diags, f, d, w)) return .unmet;

        // VAMS §7: a module with a discrete half gets the mixed-signal runner.
        var dm = d;
        dm.mixed = vera.tb.mixedPlan(result.lowered, result.mir);
        dm.op_states = try vera.tb.opStates(arena, result.lowered);
        dm.mem_bytes = vera.tb.memBytes(result.lowered);
        dm.validate_contract = true;
        dm.certify = harness.certify and d.fd_exempt == null;
        // L4b: the prover's claim `finiteCheck` tests. Every contribution unit
        // rated `.optimized` (proof.zig `FloatMode`); a device with none claims nothing.
        dm.finite_proved = for (result.verdict.unit_modes) |mode| {
            if (mode != .optimized) break false;
        } else result.verdict.unit_modes.len != 0;
        const runner = try vera.tb.renderRunner(arena, f.stem(), dm);

        // One work directory per fixture, keyed on the whole relative path: two
        // fixtures may declare the same module name AND share a file name, and a
        // shared scratch would race them onto one `device.zig`.
        const work = try std.fs.path.join(arena, &.{
            options.work_root,
            "torture",
            std.fs.path.basename(f.root),
            f.slug,
        });
        const build_opts: vera.tb.BuildOptions = .{
            .work_dir = work,
            .contract = options.contract,
            .name = result.mir.name,
            .mixed = dm.mixed != null,
            .zig_exe = options.zig_exe,
            .optimize = cfg.fixture_opt,
            .backend = cfg.fixture_backend,
            .strip = true,
        };
        if (stage_into) |s| {
            if (!build_opts.mixed) s.* = try vera.tb.stageExe(arena, io, device, runner, build_opts);
            return .met;
        }
        const built = (if (ctx.batched.get(f.path)) |b| linkBatched(gpa, io, arena, work, b) else vera.tb.buildExe(gpa, io, device, runner, build_opts)) catch |err| {
            try w.print("FAIL {s}: building the testbench: {t}\n", .{ f.path, err });
            return .unmet;
        };
        defer built.deinit(gpa);
        const bin = switch (built) {
            // Every testbench build failure is an engine bug; there is no excused
            // case. Make a failure impossible before adding an excuse for it.
            .failed => |text| {
                try w.print(
                    "FAIL {s}: the generated testbench does not compile — an ENGINE bug:\n{s}\n",
                    .{ f.path, text },
                );
                return .unmet;
            },
            .ok => |p| p,
        };

        const got = capture(gpa, io, bin, work, d.expected_exit, d.plusargs) catch |err| {
            try w.print("FAIL {s}: running the testbench: {t}\n", .{ f.path, err });
            return .unmet;
        };
        defer gpa.free(got);

        // THE ASSERTION, and the only one there is.
        const tally = countVerdicts(got);
        if (harness.perturb != null) return perturbed(f, got, w);
        if (d.expected_checks) |expected| {
            if (tally.total != expected) {
                try w.print("FAIL {s}: observed {d} assertion(s), expected exactly {d}\n", .{
                    f.path, tally.total, expected,
                });
                return .unmet;
            }
        }
        if (tally.failed != 0) {
            try w.print("FAIL {s}: {d} of {d} assertion(s) reported ok=0:\n", .{
                f.path, tally.failed, tally.total,
            });
            var lines = std.mem.splitScalar(u8, got, '\n');
            while (lines.next()) |line| {
                if (std.mem.find(u8, line, "ok=0") != null) try w.print("    {s}\n", .{line});
            }
            return .unmet;
        }

        // `//! reject-run`: the run refused, by name, and only for the named
        // rules (`reject-only`'s test, on the run's `error[...]` lines).
        for (d.reject_run) |pattern| if (!digital.errorSays(got, &.{pattern}, .any)) {
            try w.print("FAIL {s}: `//! reject-run`: no run-time `error[` line holds \"{s}\":\n{s}\n", .{ f.path, pattern, got });
            return .unmet;
        };
        if (d.reject_run.len != 0 and !digital.errorSays(got, d.reject_run, .every)) {
            try w.print("FAIL {s}: `//! reject-run`, and a second run-time error fired:\n{s}\n", .{ f.path, got });
            return .unmet;
        }

        // A fixture may also report failure in prose — a §9.7.3 severity task, or a
        // computed verdict that is not an `ok=` column. A run-time refusal's run
        // may say FAIL about itself (the mixed runner's "the digital half did not
        // run"); it is judged by its status and `error[` lines above, so only
        // `capture`'s status line counts against it.
        if (std.mem.find(u8, got, if (d.reject_run.len != 0) "FAIL: <testbench" else "FAIL") != null) {
            try w.print("FAIL {s}: the testbench itself reported a failure:\n{s}\n", .{ f.path, got });
            return .unmet;
        }

        // A run-time refusal is its own assertion (`decide` lets it through lint).
        if (tally.total == 0 and d.reject_run.len == 0) {
            try w.print(
                "{s}: compiled and ran, but asserted nothing.\n",
                .{f.path},
            );
            return .unasserted;
        }
        return .met;
    }

    /// A `--perturb` transcript's verdict: every want was moved, so every check
    /// must now print a failing verdict. Each `ok=1` left is LOOSE, named here
    /// for `tools/conformance.py`. The runner's own directive checks (`//! noise`,
    /// `acstim`, `acdyn`, `qsite`, `seed`, `limit`, `abstol`) are not the
    /// fixture's: check.vh does not move their wants, and whether they can fail
    /// is the runner's property (its exact or 1e-12 comparisons, pinned by
    /// src/codegen/exe/tb/test.zig and tests/canary), so they are left out.
    fn perturbed(f: Fixture, got: []const u8, w: *Io.Writer) !Result {
        var own: Tally = .{ .total = 0, .failed = 0 };
        var runner_checks: usize = 0;
        var lines = std.mem.splitScalar(u8, got, '\n');
        while (lines.next()) |line| {
            const at = std.mem.find(u8, line, "ok=") orelse continue;
            if (directiveCheck(line)) {
                runner_checks += 1;
                continue;
            }
            own.total += 1;
            const rest = line[at + 3 ..];
            if (!(rest.len != 0 and rest[0] == '1' and (rest.len == 1 or std.ascii.isWhitespace(rest[1])))) own.failed += 1;
        }
        if (own.total == 0) return if (runner_checks != 0) .met else .unasserted;
        if (own.failed == own.total) return .met;
        try w.print("FAIL {s}: {d} of {d} check(s) still pass with their want perturbed:\n", .{ f.path, own.total - own.failed, own.total });
        lines = std.mem.splitScalar(u8, got, '\n');
        while (lines.next()) |line| {
            if (directiveCheck(line)) continue;
            const at = std.mem.find(u8, line, "ok=1") orelse continue;
            if (at + 4 == line.len or std.ascii.isWhitespace(line[at + 4])) try w.print("LOOSE {s}: {s}\n", .{ f.path, line });
        }
        return .unmet;
    }

    /// Whether a verdict line is one the runner prints for a device-table
    /// directive (`tb/runner.zig`), not a check the fixture wrote.
    fn directiveCheck(line: []const u8) bool {
        const tags = [_][]const u8{ "noise[", "noise count", "acstim[", "acstim count", "acdyn[", "qsite[", "qsite count", "seed[", "limit[", "abstol[", "meta[", "meta count" };
        for (tags) |t| if (std.mem.startsWith(u8, line, t)) return true;
        return false;
    }

    test "a perturbed run judges the fixture's checks, not the runner's directive tables" {
        var aw: Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        const f: Fixture = .{ .path = "x.va", .root = ".", .slug = "x" };
        // Every own check flipped; a directive check still ok=1 is not LOOSE.
        try std.testing.expectEqual(Result.met, try perturbed(f, "own got=1 want=1.001 ok=0\nnoise[0] got=a want=a ok=1\n", &aw.writer));
        // Only directive checks: the runner's comparisons are what can fail.
        try std.testing.expectEqual(Result.met, try perturbed(f, "limit[0].g got=1 want=1 ok=1\n", &aw.writer));
        try std.testing.expectEqual(Result.unasserted, try perturbed(f, "nothing\n", &aw.writer));
        // An own check that survives is LOOSE, by name.
        try std.testing.expectEqual(Result.unmet, try perturbed(f, "loose got=1 want=1.001 ok=1\n", &aw.writer));
        try std.testing.expect(std.mem.find(u8, aw.written(), "LOOSE x.va: loose") != null);
    }

    const Tally = struct { total: usize, failed: usize };

    /// Count the `ok=` verdicts a transcript carries. `ok=1` passes, anything else
    /// fails — a malformed verdict is not a pass.
    fn countVerdicts(text: []const u8) Tally {
        var t: Tally = .{ .total = 0, .failed = 0 };
        var rest = text;
        while (std.mem.find(u8, rest, "ok=")) |at| {
            rest = rest[at + "ok=".len ..];
            t.total += 1;
            const is_one = rest.len != 0 and rest[0] == '1' and
                (rest.len == 1 or std.ascii.isWhitespace(rest[1]));
            if (!is_one) t.failed += 1;
        }
        return t;
    }

    /// Stands `<work>/vera-batch-<i>`, a symlink to the batch binary, in for the
    /// fixture's own testbench (`vera.tb.batch_argv0`). Gpa-owned path.
    fn linkBatched(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, work: []const u8, b: Batched) !vera.tb.BuildResult {
        var dir = try Io.Dir.cwd().openDir(io, work, .{});
        defer dir.close(io);
        const name = try arena.print(vera.tb.batch_argv0 ++ "{d}", .{b.index});
        dir.deleteFile(io, name) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        try dir.symLink(io, b.bin, name, .{});
        return .{ .ok = try std.fs.path.join(gpa, &.{ work, name }) };
    }

    /// Runs the testbench and returns its stderr, where both `$strobe` output and
    /// the residual dump go, in program order. Caller frees with `gpa`.
    ///
    /// The child runs in its own work directory, so §9.5 file I/O resolves in a
    /// per-fixture namespace rather than the repository root. `bin` is
    /// `<work>/<name>`, so from inside `work` it is `./<name>`.
    fn capture(gpa: std.mem.Allocator, io: Io, bin: []const u8, work: []const u8, expected_exit: u8, plusargs: []const []const u8) ![]const u8 {
        var argv0_buf: [std.fs.max_path_bytes]u8 = undefined;
        const argv0 = try std.mem.print(&argv0_buf, "./{s}", .{std.fs.path.basename(bin)});
        const argv = try gpa.alloc([]const u8, 1 + plusargs.len);
        defer gpa.free(argv);
        argv[0] = argv0;
        @memcpy(argv[1..], plusargs);
        const r = try std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .path = work } });
        gpa.free(r.stdout);
        var text: std.ArrayList(u8) = .fromOwnedSlice(r.stderr);
        errdefer text.deinit(gpa);
        // Exit status is part of the oracle, even when earlier assertions passed.
        // Fatal-task fixtures opt into their expected status with `//! exit`.
        switch (r.term) {
            .exited => |c| if (c != expected_exit) {
                var line: [64]u8 = undefined;
                const s = std.mem.print(&line, "FAIL: <testbench exit {d}, expected {d}>\n", .{ c, expected_exit }) catch unreachable;
                try text.appendSlice(gpa, s);
            },
            else => try text.appendSlice(gpa, "FAIL: <testbench did not exit normally>\n"),
        }
        return text.toOwnedSlice(gpa);
    }

    test "a batch runs each member by argv[0]; one member that does not compile fails the batch" {
        if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const work = options.work_root ++ "/batch-selftest";
        // Prints its device's tag and the plusargs it was handed.
        const runner =
            \\const std = @import("std");
            \\const device = @import("device");
            \\pub fn main(init: std.process.Init.Minimal) void {
            \\    const argv = init.args.toSlice(std.heap.page_allocator) catch return;
            \\    std.debug.print("{s}", .{device.tag});
            \\    for (argv[1..]) |a| std.debug.print(" {s}", .{a});
            \\    std.debug.print("\n", .{});
            \\}
            \\
        ;
        const tags = [_][]const u8{ "a", "b", "broken" };
        var staged: [tags.len]vera.tb.Staged = undefined;
        var dirs: [tags.len][]const u8 = undefined;
        for (&staged, &dirs, tags) |*s, *dir, tag| {
            dir.* = try std.fs.path.join(arena, &.{ work, tag });
            const device = if (std.mem.eql(u8, tag, "broken")) "pub const tag = 1 +;\n" else try arena.print("pub const tag = \"{s}\";\n", .{tag});
            s.* = try vera.tb.stageExe(arena, io, device, runner, .{ .work_dir = dir.*, .contract = options.contract, .name = tag, .zig_exe = options.zig_exe });
        }
        const opts: vera.tb.BuildOptions = .{ .work_dir = work ++ "/batch", .contract = options.contract, .name = "batch", .zig_exe = options.zig_exe, .strip = true };

        const built = try vera.tb.buildBatch(gpa, io, staged[0..2], opts);
        defer built.deinit(gpa);
        const bin = switch (built) {
            .ok => |p| p,
            .failed => |text| {
                std.debug.print("{s}\n", .{text});
                return error.TestUnexpectedResult;
            },
        };
        for (0..2) |i| {
            const link = try linkBatched(gpa, io, arena, dirs[i], .{ .bin = bin, .index = i });
            defer link.deinit(gpa);
            const got = try capture(gpa, io, link.ok, dirs[i], 0, &.{ "+x=1", "+y" });
            defer gpa.free(got);
            try std.testing.expectEqualStrings(try arena.print("{s} +x=1 +y\n", .{tags[i]}), got);
        }

        const bad = try vera.tb.buildBatch(gpa, io, &staged, opts);
        defer bad.deinit(gpa);
        try std.testing.expect(bad == .failed);
    }

    test "capture forwards runtime argv without expansion and preserves order" {
        if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
        // Independent POSIX argv probe, not a generated model: the model's current
        // plusarg stub cannot distinguish missing runner plumbing from its own bug.
        // Only this fixed script is interpreted; fixture bytes stay positional
        // arguments, quoted by the probe and never inserted into its source.
        const got = try capture(std.testing.allocator, std.testing.io, "/bin/sh", "/bin", 0, &.{
            "-c",      "for arg do printf '%s\\n' \"$arg\" >&2; done", "argv-probe",
            "+gain=7", "+gain=8",                                      "+gain=7",
            "+empty=", "+literal=$HOME;*",                             "+literal=$(printf_EXPANDED)",
        });
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(
            "+gain=7\n+gain=8\n+gain=7\n+empty=\n+literal=$HOME;*\n+literal=$(printf_EXPANDED)\n",
            got,
        );
        const absent = try capture(std.testing.allocator, std.testing.io, "/bin/sh", "/bin", 0, &.{});
        defer std.testing.allocator.free(absent);
        try std.testing.expectEqualStrings("", absent);
    }

    test "verdicts are counted, and a malformed one is not a pass" {
        try std.testing.expectEqual(Tally{ .total = 0, .failed = 0 }, countVerdicts("no verdicts here"));
        try std.testing.expectEqual(Tally{ .total = 2, .failed = 0 }, countVerdicts("a ok=1\nb ok=1\n"));
        try std.testing.expectEqual(Tally{ .total = 2, .failed = 1 }, countVerdicts("a ok=1\nb ok=0\n"));
        try std.testing.expectEqual(Tally{ .total = 1, .failed = 1 }, countVerdicts("a ok=\n"));
        try std.testing.expectEqual(Tally{ .total = 1, .failed = 0 }, countVerdicts("a ok=1"));
        for ([_][]const u8{ "ok=10", "ok=1garbage", "ok=1.0", "ok=-1", "ok=" }) |bad| {
            try std.testing.expectEqual(Tally{ .total = 1, .failed = 1 }, countVerdicts(bad));
        }
    }

    test "declared check count rejects missing and duplicated observations" {
        const gpa = std.testing.allocator;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var report: Io.Writer.Allocating = .init(gpa);
        defer report.deinit();
        const source =
            \\`include "disciplines.vams"
            \\module check_count_oracle(p, n);
            \\  inout p, n; electrical p, n;
            \\  analog $strobe("single observation ok=1");
            \\endmodule
        ;
        const fixture: Fixture = .{
            .path = suite.fixture_root ++ "/check_count_oracle.va",
            .root = suite.fixture_root,
            .slug = "harness_check_count_selftest",
        };
        const missing = try runAndCheck(gpa, std.testing.io, arena, &.{ .cfg = &.{} }, fixture, source, .{ .expected_checks = 2 }, &report.writer, null);
        try std.testing.expect(missing == .unmet);
        try std.testing.expect(std.mem.find(u8, report.written(), "observed 1 assertion(s), expected exactly 2") != null);
        const complete = try runAndCheck(gpa, std.testing.io, arena, &.{ .cfg = &.{} }, fixture, source, .{ .expected_checks = 1 }, &report.writer, null);
        try std.testing.expect(complete == .met);
        const duplicated = try runAndCheck(gpa, std.testing.io, arena, &.{ .cfg = &.{} }, fixture, source, .{
            .expected_checks = 1,
            .times = &.{ 0.0, 1e-9 },
        }, &report.writer, null);
        try std.testing.expect(duplicated == .unmet);
        try std.testing.expect(std.mem.find(u8, report.written(), "observed 2 assertion(s), expected exactly 1") != null);
    }

    test "a fatal exit after a passing assertion must be explicitly expected" {
        const gpa = std.testing.allocator;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var report: Io.Writer.Allocating = .init(gpa);
        defer report.deinit();
        const source =
            \\`include "disciplines.vams"
            \\module exit_oracle(p, n);
            \\  inout p, n; electrical p, n;
            \\  analog begin
            \\    $strobe("before fatal got=1 want=1 ok=1");
            \\    $fatal(1, "intentional exit");
            \\  end
            \\endmodule
        ;
        const fixture: Fixture = .{
            .path = suite.fixture_root ++ "/exit_oracle.va",
            .root = suite.fixture_root,
            .slug = "harness_exit_status_selftest",
        };
        const unexpected = try runAndCheck(gpa, std.testing.io, arena, &.{ .cfg = &.{} }, fixture, source, .{}, &report.writer, null);
        try std.testing.expect(unexpected == .unmet);
        try std.testing.expect(std.mem.find(u8, report.written(), "exit 1, expected 0") != null);
        const expected = try runAndCheck(gpa, std.testing.io, arena, &.{ .cfg = &.{} }, fixture, source, .{ .expected_exit = 1 }, &report.writer, null);
        try std.testing.expect(expected == .met);
    }

    test {
        _ = harness;
    }
};

const Canary = struct {
    //! The canary in `zig build test`: the judge judged. `<vera_root>/canary/`
    //! holds fixtures that are wrong on purpose (VerA's own, outside the suite's
    //! `tests/`), and its `EXPECT.tsv` says what the harness must answer for each
    //! -> exit 0 only when every answer is the expected one.
    //!
    //! A suite that cannot say FAIL proves nothing by saying PASS: each row here
    //! is a way a fixture can look green while asserting nothing, and the run
    //! fails the day the harness stops catching it.
    //!
    //! EXPECT.tsv: `<file>\t<normal|perturb>\t<pass | substring of the FAIL text>`.
    //! `perturb` runs the row as `benchmark -- --perturb` would.

    const std = @import("std");
    const options = @import("suite_options");
    const harness = Fixtures;
    const torture = Analog;

    const Io = std.Io;

    const Row = struct { file: []const u8, perturb: bool, want: []const u8 };

    /// Judges every canary and compares each verdict and its text with its row.
    pub fn run(init: std.process.Init) !u8 {
        const gpa = init.gpa;
        const io = init.io;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var buf: [4096]u8 = undefined;
        var stderr = Io.File.stderr().writer(io, &buf);
        const w = &stderr.interface;
        defer w.flush() catch {};

        const root = options.vera_root ++ "/canary";
        const table = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ root, "EXPECT.tsv" }), arena, .limited(1 << 16));
        const rows = try parse(arena, table);

        var cfg: harness.Config = .init();
        cfg.root = root;
        cfg.strict = true;
        var ctx: torture.Ctx = .{ .cfg = &cfg };
        defer ctx.deinit(gpa);
        const compiler = torture.compiler(&ctx);

        const fixtures = try harness.collect(arena, io, root, &.{""}, null);
        var bad: usize = 0;
        for (fixtures) |f| {
            const name = std.fs.path.basename(f.path);
            const row = for (rows) |r| {
                if (std.mem.eql(u8, r.file, name)) break r;
            } else {
                try w.print("CANARY {s}: no EXPECT.tsv row\n", .{name});
                bad += 1;
                continue;
            };
            harness.perturb = if (row.perturb) 1e-3 else null;
            defer harness.perturb = null;
            var aw: Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            const v = try harness.judge(gpa, io, arena, compiler, f, true, &aw.writer);
            const text = aw.written();
            const ok = if (std.mem.eql(u8, row.want, "pass"))
                v == .pass
            else
                v == .fail and std.mem.find(u8, text, row.want) != null;
            if (ok) {
                try w.print("canary {s}: {t} as expected\n", .{ name, v });
            } else {
                try w.print("CANARY {s}: wanted {s}, the harness said {t}:\n{s}\n", .{ name, row.want, v, text });
                bad += 1;
            }
        }
        for (rows) |r| {
            for (fixtures) |f| {
                if (std.mem.eql(u8, std.fs.path.basename(f.path), r.file)) break;
            } else {
                try w.print("CANARY {s}: EXPECT.tsv row with no fixture\n", .{r.file});
                bad += 1;
            }
        }
        try w.print("\ncanary: {d}/{d} answered as expected\n", .{ fixtures.len - @min(bad, fixtures.len), fixtures.len });
        return if (bad == 0 and fixtures.len != 0) 0 else 1;
    }

    fn parse(arena: std.mem.Allocator, table: []const u8) ![]const Row {
        var rows: std.ArrayList(Row) = .empty;
        var lines = std.mem.splitScalar(u8, table, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            const file = cols.next() orelse return error.BadExpectRow;
            const mode = cols.next() orelse return error.BadExpectRow;
            const want = cols.next() orelse return error.BadExpectRow;
            const perturb = if (std.mem.eql(u8, mode, "perturb")) true else if (std.mem.eql(u8, mode, "normal")) false else return error.BadExpectRow;
            try rows.append(arena, .{ .file = file, .perturb = perturb, .want = want });
        }
        return rows.items;
    }

    test "EXPECT.tsv rows: three columns, a known mode" {
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();
        const rows = try parse(arena_state.allocator(), "# comment\na.va\tnormal\tpass\nb.va\tperturb\tLOOSE b\n");
        try std.testing.expectEqual(@as(usize, 2), rows.len);
        try std.testing.expect(rows[1].perturb);
        try std.testing.expectEqualStrings("LOOSE b", rows[1].want);
        try std.testing.expectError(error.BadExpectRow, parse(arena_state.allocator(), "a.va\tsideways\tpass\n"));
        try std.testing.expectError(error.BadExpectRow, parse(arena_state.allocator(), "a.va\tnormal\n"));
    }
};

const CFixtures = struct {
    //! The `vpi` mode: every `.c` fixture under `vpi_dirs`, compiled (not linked or
    //! run) against src/vpi/vpi_user.h, so the ABI the LRM describes is checked by
    //! a C compiler. The fixtures that run are `build.zig`'s `vpi_runs`.
    //!
    //!   zig build suite -- vpi           # all of them
    //!   zig build suite -- vpi p03    # the ones whose name contains p03

    const std = @import("std");
    const options = @import("suite_options");
    const harness = Fixtures;
    const child = Child;

    const Io = std.Io;
    const Args = std.process.Args.Iterator;

    /// Directories under the fixture root holding `.c` fixtures. Some groups
    /// share a header beside them (`p02_check.h`, `p03_vpi_analog.h`,
    /// `b_check.h`), so the fixture's own directory goes on the include path as
    /// well as `src/vpi`.
    const vpi_dirs = [_][]const u8{ "verilog-ams/ch11_vpi", "verilog-ams/ch12_vpi_routines", "verilog/pli" };

    /// The `vpi` mode: compiles each `.c` fixture matching the filter in `args`
    /// and prints one FAIL line per refusal and a census to stderr. Exit 1 on any
    /// FAIL or when nothing matched.
    pub fn run(init: std.process.Init, args: *Args) !u8 {
        const gpa = init.gpa;
        const io = init.io;

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();

        var filter: ?[]const u8 = null;
        while (args.next()) |a| filter = a;

        var buf: [4096]u8 = undefined;
        var stderr = Io.File.stderr().writer(io, &buf);
        const w = &stderr.interface;
        defer w.flush() catch {};

        // One object path, reused: the loop is sequential and nothing reads it.
        const work = options.work_root ++ "/vpi-fixtures";
        Io.Dir.cwd().createDirPath(io, work) catch {};
        const obj = try std.fs.path.join(arena_state.allocator(), &.{ work, "fixture.o" });
        const vpi_include = options.vpi_include;

        var ran: usize = 0;
        var failed: usize = 0;
        for (vpi_dirs) |sub| {
            const dir_path = try std.fs.path.join(gpa, &.{ options.fixture_root, sub });
            defer gpa.free(dir_path);
            var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);

            // Sorted, so a failing run is reproducible and its name list diffs.
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(gpa);
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
                try names.append(gpa, try arena_state.allocator().dupe(u8, entry.name));
            }
            std.mem.sort([]const u8, names.items, {}, harness.strLess);

            for (names.items) |name| {
                if (filter) |f| if (std.mem.find(u8, name, f) == null) continue;
                ran += 1;
                const pa = arena_state.allocator();
                const src = try std.fs.path.join(pa, &.{ dir_path, name });
                // `-c -o`, not `-fsyntax-only`: `zig cc` passes its own `-c`, which
                // `-fsyntax-only` leaves unused, and `-Werror` fails every fixture on
                // that warning. The flags are `vpi_app.c`'s, so no fixture passes
                // here that the acceptance test's flags would refuse.
                const r = child.capture(pa, io, &.{
                    options.zig_exe, "cc",     "-std=c99", "-Wall", "-Werror",
                    "-c",            "-o",     obj,        "-I",    vpi_include,
                    "-I",            dir_path, src,
                }) catch |e| {
                    try w.print("FAIL {s}: could not run the C compiler: {s}\n", .{ name, @errorName(e) });
                    failed += 1;
                    continue;
                };
                if (r.exit == 0) continue;
                failed += 1;
                // One line of the compiler's words; the full log would bury the census.
                const first = std.mem.trim(u8, firstErrorLine(r.stderr), " \t\r");
                try w.print("FAIL {s}: {s}\n", .{ name, first });
            }
        }

        if (ran == 0) {
            try w.print("vpi: nothing matched `{s}`\n", .{filter orelse ""});
            return 1;
        }
        try w.print("vpi: {d}/{d} fixtures compile against src/vpi/vpi_user.h\n", .{ ran - failed, ran });
        return if (failed == 0) 0 else 1;
    }

    /// The compiler's first `error:` line, or its first line if it never said one.
    fn firstErrorLine(stderr: []const u8) []const u8 {
        var lines = std.mem.splitScalar(u8, stderr, '\n');
        while (lines.next()) |l| if (std.mem.find(u8, l, "error:") != null) return l;
        var again = std.mem.splitScalar(u8, stderr, '\n');
        return again.next() orelse "";
    }

    test "the first error line is the compiler's, not the last line of a log" {
        const log =
            \\p02_01.c:77:24: note: expanded from here
            \\p02_01.c:77:24: error: unknown type name 'p_cb_data'
            \\p02_01.c:93:14: error: use of undeclared identifier 'vpiBinStrVal'
            \\1 error generated.
        ;
        try std.testing.expectEqualStrings(
            "p02_01.c:77:24: error: unknown type name 'p_cb_data'",
            firstErrorLine(log),
        );
        // A compiler that failed without the word `error:` still has to report
        // something, or a FAIL row would be a bare name.
        try std.testing.expectEqualStrings("cc: killed", firstErrorLine("cc: killed\n"));
        try std.testing.expectEqualStrings("", firstErrorLine(""));
    }
};

const Child = struct {
    //! A child process run to completion: argv -> everything it printed and its
    //! exit code. The digital, `--native`, `--fuzz`, `vpi` and `spice` modes each
    //! judge a `vera` (or `zig cc`) run by its two streams, so they share this.

    const std = @import("std");

    const Io = std.Io;
    const Allocator = std.mem.Allocator;

    /// Both streams, whole, and the exit code; a signal or stop is 255.
    const Captured = struct { stdout: []const u8, stderr: []const u8, exit: u8 };

    /// Runs a child and takes everything it said. Both streams are allocated in
    /// `arena`; a spawn failure is the error.
    pub fn capture(arena: Allocator, io: Io, argv: []const []const u8) !Captured {
        return captureIn(arena, io, argv, null);
    }

    /// `capture` with the child's working directory at `cwd` (null: this one).
    pub fn captureIn(arena: Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8) !Captured {
        const r = try std.process.run(arena, io, .{ .argv = argv, .cwd = if (cwd) |p| .{ .path = p } else .inherit });
        return .{ .stdout = r.stdout, .stderr = r.stderr, .exit = switch (r.term) {
            .exited => |c| c,
            else => 255,
        } };
    }
};

const Devices = struct {
    //! The `devices` mode: `vera --run x.v` transcripts against committed goldens,
    //! which need the `vera` binary and so cannot be `test` blocks.
    //!
    //!   zig build suite -- devices          # all of it
    //!   zig build suite -- devices rng   # the cases whose name contains `rng`
    //!
    //! Cases come from the suite's `verilog-ams/digital/` and `verilog/`, sorted,
    //! so a FAIL name list diffs between two runs. `--native` hands the same
    //! cases to `Native`, `--fuzz` goes to `Fuzz`, and `--coverage` to
    //! `Ieee1364`.

    const std = @import("std");
    const options = @import("suite_options");
    const harness = Fixtures;
    const ieee1364 = Ieee1364;
    const native = Native;
    const fuzz = Fuzz;
    const digital = Digital;
    const child = Child;

    const Io = std.Io;
    const Allocator = std.mem.Allocator;
    const Args = std.process.Args.Iterator;

    /// `vera --run <name>.v` must print `<name>.expected.txt` exactly. IEEE 1364
    /// semantics, so `.v` and not `.va`: the shared frontend plus `sim/`, with no
    /// analog path at all.
    ///
    /// Walked recursively, not listed, under the fixture root: `verilog/<NN_clause>/`
    /// (IEEE 1364-2005, one directory per clause) and `verilog-ams/digital/`
    /// (digital-context Verilog-AMS rules such as wreal and the `--std` boundary).
    ///
    /// A `.v` is a case when it has `.expected.txt`, a `//! reject` line
    /// (`digital.negative`) or a `//! expect vcd` line; a support design with none
    /// (a UDP library a fixture instantiates) is not. A reject with an
    /// `.expected.txt` is a run an error did not end (IEEE 1364-2005 §17.2.9's
    /// terminated load): it must fail as the reject lines say and print the
    /// transcript. `verilog/pli/` is not walked: its designs are loaded by the `.c`
    /// fixtures `build.zig` runs.
    pub const digital_dirs = [_][]const u8{ "verilog-ams/digital", ieee1364_dir };
    /// The IEEE 1364-2005 transcript tree under the fixture root, which `zig
    /// build suite -- ieee1364` runs alone.
    pub const ieee1364_dir = "verilog";

    /// The `devices` and `ieee1364` modes over the cases under `dirs`: the
    /// verdicts and a census on stderr, exit 1 on any FAIL or when nothing
    /// matched. Changes this process's working directory to the suite's scratch
    /// tree before any case runs.
    pub fn run(init: std.process.Init, vera_exe: []const u8, args: *Args, dirs: []const []const u8) !u8 {
        const gpa = init.gpa;
        const io = init.io;

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();

        var filter: ?[]const u8 = null;
        // `--verdicts=F`: one `<verdict>\t<path under the fixture root>` row per
        // case, `harness.writeVerdicts`'s format, so `tools/conformance.py
        // metric` reads a digital case's verdict as it reads a .va fixture's.
        var verdicts_path: ?[]const u8 = null;
        var native_flags: ?[]const []const u8 = null;
        var snapshot = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--coverage")) return ieee1364.coverage(init);
            if (std.mem.startsWith(u8, a, "--verdicts=")) {
                // Absolute: the cases run from the suite's scratch tree.
                verdicts_path = try Io.Dir.cwd().realPathFileAlloc(io, ".", arena_state.allocator());
                verdicts_path = try std.fs.path.resolve(arena_state.allocator(), &.{ verdicts_path.?, a["--verdicts=".len..] });
                continue;
            }
            if (std.mem.eql(u8, a, "--native") or std.mem.eql(u8, a, "--native=fifo")) {
                native_flags = &.{"--schedule=fifo"};
                continue;
            }
            if (std.mem.eql(u8, a, "--native=static")) {
                native_flags = &.{"--schedule=static"};
                continue;
            }
            if (std.mem.eql(u8, a, "--native=four")) {
                native_flags = &.{ "--schedule=fifo", "--state=4" };
                continue;
            }
            if (std.mem.eql(u8, a, "--native=two-state")) {
                native_flags = &.{"--two-state"};
                continue;
            }
            if (std.mem.eql(u8, a, "--native=snapshot") or std.mem.eql(u8, a, "--snapshot")) {
                snapshot = true;
                if (native_flags == null or a.len == "--native=snapshot".len) native_flags = &.{"--schedule=fifo"};
                continue;
            }
            if (std.mem.eql(u8, a, "--fuzz")) {
                const n = std.fmt.parseInt(u32, args.next() orelse "", 10) catch return harness.usage(init.io, "--fuzz takes a count");
                return fuzz.run(init, vera_exe, n);
            }
            filter = a;
        }

        var buf: [4096]u8 = undefined;
        var stderr = Io.File.stderr().writer(io, &buf);
        const w = &stderr.interface;
        defer w.flush() catch {};

        const cases = try digitalCases(gpa, io, dirs);
        defer {
            for (cases) |c| gpa.free(c);
            gpa.free(cases);
        }
        // A case that writes a file (§17.2.1 `$fopen` for writing, §18's dump)
        // writes it relative to the working directory, which must not be the
        // repository: every case runs in the suite's scratch tree instead. The
        // fixture paths are absolute already; the executable is made so.
        const exe = try Io.Dir.cwd().realPathFileAlloc(io, vera_exe, gpa);
        defer gpa.free(exe);
        const scratch = options.work_root ++ "/devices";
        try Io.Dir.cwd().createDirPath(io, scratch);
        var scratch_dir = try Io.Dir.cwd().openDir(io, scratch, .{});
        defer scratch_dir.close(io);
        try std.process.setCurrentDir(io, scratch_dir);

        if (native_flags) |flags| return native.run(gpa, io, exe, flags, snapshot, cases, filter, w);

        var ran: usize = 0;
        var failed: usize = 0;
        var xfailed: usize = 0;
        var rows: Io.Writer.Allocating = .init(gpa);
        defer rows.deinit();
        for (cases) |case| {
            if (filter) |f| if (std.mem.find(u8, case, f) == null) continue;
            var case_arena: std.heap.ArenaAllocator = .init(gpa);
            defer case_arena.deinit();
            ran += 1;
            const v = try digitalVerdict(case_arena.allocator(), io, exe, case, w);
            switch (v) {
                .pass => {},
                .fail => failed += 1,
                .xfail => xfailed += 1,
            }
            if (verdicts_path != null) try rows.writer.print("{t}\t{s}.v\n", .{ v, case });
        }
        if (verdicts_path) |path| try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rows.written() });
        if (ran == 0) {
            try w.print("devices: nothing matched `{s}`\n", .{filter orelse ""});
            return 1;
        }
        try w.print("devices: {d}/{d} cases behave as they say they do", .{ ran - failed - xfailed, ran });
        if (xfailed != 0) try w.print(", {d} XFAIL (a known gap, not a pass)", .{xfailed});
        try w.writeAll("\n");
        return if (failed == 0) 0 else 1;
    }

    /// A transcript that differs is reported as the whole of both sides: these are
    /// tens of bytes, and "line 3 differs" sends the reader to the file anyway.
    pub fn diff(w: *Io.Writer, what: []const u8, want: []const u8, got: []const u8) !bool {
        if (std.mem.eql(u8, want, got)) return true;
        try w.print("FAIL {s}: transcript differs\n  want: {f}\n  got:  {f}\n", .{
            what,
            std.ascii.hexEscape(want, .lower),
            std.ascii.hexEscape(got, .lower),
        });
        return false;
    }

    /// Digital transcript cases, diagnostic cases and `//! expect vcd` dump cases,
    /// sorted so two runs report in the same order. Support files are not cases.
    /// Case names are fixture-root-relative stems, `verilog/05_expressions/control`.
    fn digitalCases(gpa: Allocator, io: Io, dirs: []const []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |c| gpa.free(c);
            list.deinit(gpa);
        }
        for (dirs) |sub| {
            const root = try std.fs.path.join(gpa, &.{ options.fixture_root, sub });
            defer gpa.free(root);
            var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
            defer dir.close(io);
            var walker = try dir.walk(gpa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.eql(u8, std.fs.path.extension(entry.path), ".v")) continue;
                if (std.mem.startsWith(u8, entry.path, "pli" ++ std.fs.path.sep_str)) continue;
                const stem = entry.path[0 .. entry.path.len - ".v".len];
                const golden = try gpa.print("{s}.expected.txt", .{stem});
                defer gpa.free(golden);
                const has_golden = if (dir.access(io, golden, .{})) |_| true else |_| false;
                const source = try dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 20));
                defer gpa.free(source);
                const dumps = !has_golden and digital.vcdExpectation(source) != null;
                if (!dumps and !digital.caseSelected(has_golden, source)) continue;
                try list.append(gpa, try gpa.print("{s}/{s}", .{ sub, stem }));
            }
        }
        std.mem.sort([]const u8, list.items, {}, harness.strLess);
        return list.toOwnedSlice(gpa);
    }

    /// `digitalCase` under `//! xfail` or a `harness.xfail_list` row, with the .va
    /// suite's algebra (`harness.judge`): an unmet xfail case is XFAIL and does not
    /// fail the run; a met one is an XPASS FAIL, so a marker cannot outlive its
    /// limitation.
    fn digitalVerdict(arena: Allocator, io: Io, vera_exe: []const u8, case: []const u8, w: *Io.Writer) !enum { pass, fail, xfail } {
        const xfail = try xfailOf(arena, io, case) orelse
            return if (try digitalCase(arena, io, vera_exe, case, w)) .pass else .fail;
        if (xfail.len == 0) {
            try w.print("FAIL {s}: `//! xfail` names no reason\n", .{case});
            return .fail;
        }
        var detail: Io.Writer.Allocating = .init(arena);
        if (try digitalCase(arena, io, vera_exe, case, &detail.writer)) {
            try w.print("FAIL {s}: XPASS — marked xfail, but VerA now does what the fixture says.\n" ++
                "  Delete its `//! xfail` line or its row in {s}.\n", .{ case, harness.xfail_list });
            return .fail;
        }
        try w.print("XFAIL {s}: known: {s}\n", .{ case, xfail });
        return .xfail;
    }

    /// A case's xfail reason: its own `//! xfail` line, else its
    /// `harness.xfail_list` row; null when it has neither.
    fn xfailOf(arena: Allocator, io: Io, case: []const u8) !?[]const u8 {
        const src = try arena.print("{s}/{s}.v", .{ options.fixture_root, case });
        const source = try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(1 << 20));
        if (digital.xfailReason(source)) |why| return why;
        return harness.listedXfail(arena, io, options.fixture_root, src);
    }

    fn digitalCase(arena: Allocator, io: Io, vera_exe: []const u8, case: []const u8, w: *Io.Writer) !bool {
        const src = try arena.print("{s}/{s}.v", .{ options.fixture_root, case });
        const source = try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(1 << 20));
        const argv = try std.mem.concat(arena, []const u8, &.{ &.{ vera_exe, "--run", src }, try digital.runnerArgs(arena, source, std.fs.path.dirname(src).?) });
        // A §18 dump case's evidence is the file its run writes, in a directory
        // of its own; `Native.vcdDiff` compares it with the golden beside the case.
        if (!digital.negative(source)) if (digital.vcdExpectation(source)) |v| {
            const work = try arena.print("vcd/{s}", .{case});
            try Io.Dir.cwd().createDirPath(io, work);
            Io.Dir.cwd().deleteFile(io, try std.fs.path.join(arena, &.{ work, v.produced })) catch {};
            const r = try child.captureIn(arena, io, argv, work);
            if (r.exit != 0) {
                try w.print("FAIL {s}: vera --run exited {d}\n{s}\n", .{ case, r.exit, r.stderr });
                return false;
            }
            return native.vcdDiff(arena, io, w, case, work, v, false);
        };
        if (digital.negative(source)) {
            const r = try child.capture(arena, io, argv);
            if (!digital.rejectionMatches(source, r.exit, r.stderr)) {
                try w.print("FAIL {s}: digital rejection mismatch (exit {d})\n{s}\n", .{ case, r.exit, r.stderr });
                return false;
            }
            // A run-time error that does not end the run (IEEE 1364-2005
            // §17.2.9's terminated load) also pins what the run printed.
            const golden = try arena.print("{s}/{s}.expected.txt", .{ options.fixture_root, case });
            const want = Io.Dir.cwd().readFileAlloc(io, golden, arena, .limited(1 << 20)) catch return true;
            return diff(w, case, want, r.stdout);
        }
        const want = try Io.Dir.cwd().readFileAlloc(
            io,
            try arena.print("{s}/{s}.expected.txt", .{ options.fixture_root, case }),
            arena,
            .limited(1 << 20),
        );
        const r = try child.capture(arena, io, argv);
        if (r.exit != 0) {
            try w.print("FAIL {s}: vera --run exited {d}\n{s}\n", .{ case, r.exit, r.stderr });
            return false;
        }
        if (!digital.warningsMatch(source, r.stderr)) {
            try w.print("FAIL {s}: successful digital run has missing warning evidence or error diagnostics\n{s}\n", .{ case, r.stderr });
            return false;
        }
        return diff(w, case, want, r.stdout);
    }
};

const Digital = struct {
    //! The `.v` runner metadata both digital runners read: a fixture's raw source
    //! -> its routing (a `//! reject` line), its extra `vera` arguments (the
    //! suite's `//@` lines), its `//! reject`, `//! xfail` and `//! warn`
    //! obligations judged against a run's stderr, and its `//! expect vcd` dump
    //! comparison. `Devices`, `Native`, `Ieee1364`, `Analog` and `Fixtures`
    //! (`collect`, `judge`, `judgeVcd`) read it.
    //!
    //! None of it is a `tb` directive: `tb.parse` describes the analog harness and
    //! must not take a digital diagnostic as its evidence.
    //!
    //! Clauses: IEEE 1364-2005 §13.2 and §13.7.1 (`--libmap`, `-L`), §18.2 (the
    //! VCD format's free white space and its writer-owned sections).

    const std = @import("std");

    /// Whether a `.v` is a digital reject case: a `//! reject` or `//! reject-only`
    /// line, the suite's own rule (`harness/conform.c`). A `_rejected` file name
    /// says the same, but the line is what decides. Runner metadata, deliberately
    /// not a tb directive: tb.parse describes the analog harness and must not
    /// interpret a digital diagnostic as its evidence.
    pub fn negative(source: []const u8) bool {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "//!")) continue;
            var words = std.mem.tokenizeAny(u8, line["//!".len..], " \t");
            const word = words.next() orelse continue;
            if (std.mem.eql(u8, word, "reject") or std.mem.eql(u8, word, "reject-only")) return true;
        }
        return false;
    }

    /// The `vera` arguments a digital case passes after its own path, from the
    /// suite's `//@` lines (`harness/conform.c`): `//@ std SPEC` is `--std=SPEC`;
    /// `//@ libmap FILE` is `--libmap FILE` and `//@ files FILE...` more sources
    /// after the fixture, both relative to the fixture's directory `dir`; and
    /// `//@ liblist LIB...` is `-L LIB` each. Any other `//@` word is
    /// `error.BadDirective`, as the suite's harness refuses it. VerA's own
    /// `//! event-budget N` is `--event-budget=N` (the harness ignores `//!`
    /// words it does not know, so this one is VerA's to read).
    pub fn runnerArgs(arena: std.mem.Allocator, source: []const u8, dir: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var files: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.cutPrefix(u8, line, "//! event-budget")) |rest| {
                const n = std.mem.trim(u8, rest, " \t");
                if (n.len == 0) return error.BadDirective;
                try out.append(arena, try std.mem.concat(arena, u8, &.{ "--event-budget=", n }));
                continue;
            }
            if (!std.mem.startsWith(u8, line, "//@")) continue;
            var words = std.mem.tokenizeAny(u8, line["//@".len..], " \t");
            const key = words.next() orelse return error.BadDirective;
            if (std.mem.eql(u8, key, "std")) {
                try out.append(arena, try std.mem.concat(arena, u8, &.{ "--std=", words.next() orelse return error.BadDirective }));
            } else if (std.mem.eql(u8, key, "libmap")) {
                try out.appendSlice(arena, &.{ "--libmap", try std.fs.path.join(arena, &.{ dir, words.next() orelse return error.BadDirective }) });
            } else if (std.mem.eql(u8, key, "liblist")) {
                while (words.next()) |lib| try out.appendSlice(arena, &.{ "-L", lib });
            } else if (std.mem.eql(u8, key, "files")) {
                while (words.next()) |f| try files.append(arena, try std.fs.path.join(arena, &.{ dir, f }));
            } else return error.BadDirective;
        }
        try out.appendSlice(arena, files.items);
        return out.items;
    }

    /// Whether a `.v` is a digital transcript case: it has a golden or is a
    /// reject case (`negative`). Anything else is support material.
    pub fn caseSelected(has_golden: bool, source: []const u8) bool {
        return has_golden or negative(source);
    }

    /// Match a normal digital diagnostic exit, not a signal, successful program,
    /// empty/bare reject, or unrelated failure. Every declared pattern must match.
    /// `//! reject-only` also requires every `error[` line to match some pattern,
    /// as the analog judge does.
    pub fn rejectionMatches(source: []const u8, exit_code: u8, stderr: []const u8) bool {
        if (exit_code != 1 or std.mem.find(u8, stderr, "error[") == null) return false;
        var patterns: [32][]const u8 = undefined;
        var count: usize = 0;
        var only = false;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "//!")) continue;
            var fields = std.mem.tokenizeAny(u8, line[3..], " \t\r");
            const key = fields.next() orelse continue;
            const exclusive = std.mem.eql(u8, key, "reject-only");
            if (!exclusive and !std.mem.eql(u8, key, "reject")) continue;
            only = only or exclusive;
            const pattern = std.mem.trim(u8, fields.rest(), " \t\r");
            if (pattern.len == 0 or count == patterns.len) return false;
            if (!errorSays(stderr, &.{pattern}, .any)) return false;
            patterns[count] = pattern;
            count += 1;
        }
        if (count == 0) return false;
        return !only or errorSays(stderr, patterns[0..count], .every);
    }

    /// `.any`: some `error[` line contains one of `patterns`. `.every`: each
    /// `error[` line contains one of them. Also `analog.zig`'s `//! reject-run`.
    pub fn errorSays(stderr: []const u8, patterns: []const []const u8, mode: enum { any, every }) bool {
        var diagnostics = std.mem.splitScalar(u8, stderr, '\n');
        while (diagnostics.next()) |raw| {
            const diagnostic = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, diagnostic, "error[")) continue;
            const hit = for (patterns) |p| {
                if (std.mem.find(u8, diagnostic, p) != null) break true;
            } else false;
            switch (mode) {
                .any => if (hit) return true,
                .every => if (!hit) return false,
            }
        }
        return mode == .every;
    }

    /// `//! xfail <reason>` on a digital case: the reason, "" for a bare marker,
    /// null when there is none. The verdict algebra is `judge`'s: a failing case
    /// is XFAIL, a passing one is an XPASS FAIL.
    pub fn xfailReason(source: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "//!")) continue;
            const rest = std.mem.trimStart(u8, line[3..], " \t");
            if (!std.mem.startsWith(u8, rest, "xfail")) continue;
            const tail = rest["xfail".len..];
            if (tail.len != 0 and tail[0] != ' ' and tail[0] != '\t') continue;
            return std.mem.trim(u8, tail, " \t");
        }
        return null;
    }

    /// Optional warning obligations on a successful digital transcript, one
    /// `//! warn <pattern>` line each. Match actual diagnostic headers, never
    /// source excerpts or arbitrary stderr text. A positive still needs its exact
    /// stdout oracle and a successful exit.
    pub fn warningsMatch(source: []const u8, stderr: []const u8) bool {
        var diagnostics = std.mem.splitScalar(u8, stderr, '\n');
        while (diagnostics.next()) |raw| {
            if (std.mem.startsWith(u8, std.mem.trim(u8, raw, " \t\r"), "error[")) return false;
        }
        const prefix = "//! warn";
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, prefix)) continue;
            const suffix = line[prefix.len..];
            if (suffix.len != 0 and suffix[0] != ' ' and suffix[0] != '\t') continue;
            const pattern = std.mem.trim(u8, suffix, " \t\r");
            if (pattern.len == 0) return false;
            diagnostics.reset();
            var found = false;
            while (diagnostics.next()) |diagnostic_raw| {
                const diagnostic = std.mem.trim(u8, diagnostic_raw, " \t\r");
                if (std.mem.startsWith(u8, diagnostic, "warning[") and
                    std.mem.find(u8, diagnostic, pattern) != null) found = true;
            }
            if (!found) return false;
        }
        return true;
    }

    /// `//! expect vcd <produced> == <golden>`: `vera --run` of the `.v` writes
    /// `<produced>` (relative to the run's working directory), which must equal
    /// `<golden>` (relative to the fixture) once both are normalised (`vcdTokens`).
    pub const VcdExpect = struct { produced: []const u8, golden: []const u8 };

    /// Returns the fixture's `//! expect vcd` line, slices into `source`. Null when
    /// there is none, or it is malformed (then `tb.parse` fails it as unknown).
    pub fn vcdExpectation(source: []const u8) ?VcdExpect {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "//!")) continue;
            var f = std.mem.tokenizeAny(u8, line[3..], " \t\r");
            if (!std.mem.eql(u8, f.next() orelse continue, "expect")) continue;
            if (!std.mem.eql(u8, f.next() orelse return null, "vcd")) continue;
            const produced = f.next() orelse return null;
            if (!std.mem.eql(u8, f.next() orelse return null, "==")) return null;
            const golden = f.next() orelse return null;
            if (f.next() != null) return null;
            return .{ .produced = produced, .golden = golden };
        }
        return null;
    }

    /// IEEE 1364-2005 §18.2: "The dump file is structured in a free format. White
    /// space is used to separate commands", so a VCD is compared as TOKENS. The
    /// `$date` (§18.2.3.2) and `$version` (§18.2.3.8) sections are required
    /// header (§18.2.1) whose text is the writer's own, so each compares as its
    /// keyword and `$end` (present, body dropped); a golden writes `$date $end`.
    /// A `$comment` (§18.2.3.1) is what §18.1.5's dump limit inserts, so its body
    /// compares, joined by single spaces into one token. The `$timescale` body is
    /// joined with nothing, so `1 ns` and `1ns` are one token.
    pub fn vcdTokens(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (it.next()) |tok| {
            const header = std.mem.eql(u8, tok, "$date") or std.mem.eql(u8, tok, "$version");
            const comment = std.mem.eql(u8, tok, "$comment");
            const join = std.mem.eql(u8, tok, "$timescale");
            if (!header and !comment and !join) {
                try out.append(arena, tok);
                continue;
            }
            var body: std.ArrayList(u8) = .empty;
            while (it.next()) |t| {
                if (std.mem.eql(u8, t, "$end")) break;
                if (comment and body.items.len != 0) try body.append(arena, ' ');
                try body.appendSlice(arena, t);
            }
            if (header) try out.appendSlice(arena, &.{ tok, "$end" }) else try out.appendSlice(arena, &.{ tok, body.items, "$end" });
        }
        return out.items;
    }

    test "VCD comparison keeps the header sections, the comments, and joins the timescale" {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const got = try vcdTokens(a, "$date today $end $version VerA 1.0\n$end\n$timescale 1 ns $end\n$comment x  y $end #0 0! b1 \" ");
        const want = [_][]const u8{ "$date", "$end", "$version", "$end", "$timescale", "1ns", "$end", "$comment", "x y", "$end", "#0", "0!", "b1", "\"" };
        try std.testing.expectEqual(want.len, got.len);
        for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
        const e = vcdExpectation("// prose\n//! expect vcd a.vcd == ../g/a.vcd\n").?;
        try std.testing.expectEqualStrings("a.vcd", e.produced);
        try std.testing.expectEqualStrings("../g/a.vcd", e.golden);
        try std.testing.expect(vcdExpectation("//! expect vcd a.vcd ../g/a.vcd\n") == null);
        try std.testing.expect(vcdExpectation("//! lrm 9.1\n") == null);
    }

    test "digital positive warning obligations inspect diagnostic headers" {
        const source = "//! warn W1150\n//! warn memory data count\n";
        const warning = "warning[W1150]: memory data count differs from requested range\n";
        try std.testing.expect(warningsMatch(source, warning));
        try std.testing.expect(!warningsMatch(source, ""));
        try std.testing.expect(!warningsMatch(source, "warning[W1150]: unrelated\n12 | // memory data count\n"));
        try std.testing.expect(!warningsMatch(source, "memory data count W1150\n"));
        try std.testing.expect(!warningsMatch(source, "error[W1150]: memory data count\n"));
        try std.testing.expect(!warningsMatch("//! warn\n", warning));
        try std.testing.expect(warningsMatch("module ordinary; endmodule", warning));
        try std.testing.expect(!warningsMatch("module ordinary; endmodule", "error[E1100]: failure\n"));
        try std.testing.expect(warningsMatch("initial $display(\"//! warn absent\");", ""));
        try std.testing.expect(warningsMatch("//! warnings are prose", ""));
        try std.testing.expect(warningsMatch("//! nowarn\n", ""));
    }

    test "digital negative routing is explicit and diagnostics are specific" {
        const source = "//! reject E1100\n//! reject no arguments\n";
        try std.testing.expect(negative(source));
        try std.testing.expect(negative("  //! reject-only E1100\n"));
        try std.testing.expect(!negative("// reject E1100\n//! rejected\n//! reject-run E0601\n"));
        try std.testing.expect(!negative("initial $display(\"//! reject\");"));
        const diagnostic = "error[E1100]: function takes no arguments";
        try std.testing.expect(rejectionMatches(source, 1, diagnostic));
        try std.testing.expect(!rejectionMatches(source, 0, diagnostic));
        try std.testing.expect(!rejectionMatches(source, 255, diagnostic));
        try std.testing.expect(!rejectionMatches(source, 1, "error[E1100]: unsupported real"));
        try std.testing.expect(!rejectionMatches(source, 1, "error[E1100]: unrelated failure\n12 | // no arguments\n"));
        try std.testing.expect(rejectionMatches(source, 1, "error[E1100]: first failure\nerror[E0001]: no arguments\n"));
        try std.testing.expect(!rejectionMatches("//! reject\n", 1, diagnostic));
        try std.testing.expect(!rejectionMatches("//! lrm 9.10\n", 1, diagnostic));
        try std.testing.expect(rejectionMatches("//! reject E1100\n//! xfail pending\n", 1, diagnostic));
        // reject-only: the named error alone. A second, unnamed error fails it.
        try std.testing.expect(rejectionMatches("//! reject-only E1100\n", 1, diagnostic));
        try std.testing.expect(!rejectionMatches("//! reject-only E1100\n", 1, "error[E1100]: x\nerror[E0001]: y\n"));
        try std.testing.expect(rejectionMatches("//! reject-only E1100\n//! reject E0001\n", 1, "error[E1100]: x\nerror[E0001]: y\n"));
        try std.testing.expectEqualStrings("pending", xfailReason("//! reject E1100\n  //! xfail pending \n").?);
        try std.testing.expectEqualStrings("", xfailReason("//! xfail\n").?);
        try std.testing.expect(xfailReason("// xfail prose\n//! xfailed\n") == null);
        try std.testing.expect(caseSelected(false, source));
        try std.testing.expect(caseSelected(true, "module positive; endmodule"));
        try std.testing.expect(!caseSelected(false, "//! lrm 9.10\n"));
        try std.testing.expect(!caseSelected(false, "module support; endmodule"));
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const args = try runnerArgs(arena.allocator(), "//! reject E1100\n//@ files a.v b.vg\n//@ std 1364-2005\n  //@ libmap m/lib.map\n//@ liblist gateLib\n", "d");
        // Joined to the fixture's directory with the host's separator.
        const sep = std.fs.path.sep_str;
        const want = [_][]const u8{ "--std=1364-2005", "--libmap", "d" ++ sep ++ "m/lib.map", "-L", "gateLib", "d" ++ sep ++ "a.v", "d" ++ sep ++ "b.vg" };
        try std.testing.expectEqual(want.len, args.len);
        for (want, args) |w, a| try std.testing.expectEqualStrings(w, a);
        try std.testing.expectEqual(0, (try runnerArgs(arena.allocator(), "//! reject E1100\n// @ std prose\n", "d")).len);
        try std.testing.expectError(error.BadDirective, runnerArgs(arena.allocator(), "//@ event-budget 10\n", "d"));
        const budget = try runnerArgs(arena.allocator(), "//! event-budget 1000\n//! reject E1100\n", "d");
        try std.testing.expectEqual(1, budget.len);
        try std.testing.expectEqualStrings("--event-budget=1000", budget[0]);
    }
};

const Fuzz = struct {
    //! `--fuzz N`: N random expressions, each printed by `vera --run` and by the
    //! native executable of the same source; the two transcripts must be equal
    //! and the executable must be native. The fixtures pin the §5.5 context
    //! rules at the points someone thought of; this is the check on the rule
    //! being implemented twice (`exec.evalContext`, `emit_expr.value`).
    //!
    //!   zig build suite -- devices --fuzz 2000

    const std = @import("std");
    const options = @import("suite_options");
    const child = Child;

    const Io = std.Io;
    const Allocator = std.mem.Allocator;

    const FuzzVar = struct { width: u32, signed: bool };
    const fuzz_widths = [_]u32{ 1, 2, 3, 7, 8, 13, 16, 31, 32, 33, 48, 63, 64, 65, 100, 128, 129 };
    const fuzz_vars = 12;
    const fuzz_per_file = 400;

    /// `--fuzz N`: writes the designs under the scratch tree, runs both engines on
    /// each and prints every differing line and a census to stderr. Exit 1 on the
    /// first refused or non-native design, or when any transcript differs.
    pub fn run(init: std.process.Init, vera_exe: []const u8, count: u32) !u8 {
        const gpa = init.gpa;
        const io = init.io;
        var buf: [4096]u8 = undefined;
        var stderr = Io.File.stderr().writer(io, &buf);
        const w = &stderr.interface;
        defer w.flush() catch {};
        const exe = try Io.Dir.cwd().realPathFileAlloc(io, vera_exe, gpa);
        defer gpa.free(exe);
        const work = options.work_root ++ "/fuzz";
        try Io.Dir.cwd().createDirPath(io, work);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        var prng = std.Random.DefaultPrng.init(0x5eed_1364);
        const rand = prng.random();
        var done: u32 = 0;
        var file: u32 = 0;
        var failed = false;
        var twos: u32 = 0;
        var reruns: u32 = 0;
        while (done < count) : (file += 1) {
            _ = arena_state.reset(.retain_capacity);
            const a = arena_state.allocator();
            const n = @min(fuzz_per_file, count - done);
            const late = file % 2 == 1;
            const src = try fuzzSource(a, rand, n, late);
            const path = try a.print("{s}/fuzz{d}.v", .{ work, file });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
            const want = try child.capture(a, io, &.{ exe, "--run", path });
            const built = try child.capture(a, io, &.{ exe, "--emit-exe", "--work-dir", work, path });
            if (want.exit != 0 or built.exit != 0) {
                try w.print("FAIL {s}: --run exited {d}, --emit-exe exited {d}\n{s}{s}\n", .{ path, want.exit, built.exit, want.stderr, built.stderr });
                return 1;
            }
            if (std.mem.find(u8, built.stderr, "not native (") != null) {
                try w.print("FAIL {s}: not native\n{s}\n", .{ path, built.stderr });
                return 1;
            }
            if (late and std.mem.find(u8, built.stderr, "4-state: ") != null) {
                try w.print("FAIL {s}: known operands, yet `--state=auto` built it 4-state\n{s}\n", .{ path, built.stderr });
                return 1;
            }
            const got = try child.capture(a, io, &.{ std.mem.trimEnd(u8, built.stdout, "\n"), "--vera-state" });
            if (std.mem.find(u8, got.stderr, "rerun") != null) reruns += 1 else if (std.mem.find(u8, got.stderr, "2-state") != null) twos += 1;
            if (!std.mem.eql(u8, want.stdout, got.stdout)) {
                failed = true;
                var wl = std.mem.splitScalar(u8, want.stdout, '\n');
                var gl = std.mem.splitScalar(u8, got.stdout, '\n');
                while (wl.next()) |x| {
                    const y = gl.next() orelse "";
                    if (!std.mem.eql(u8, x, y)) try w.print("FAIL {s}: --run `{s}`, native `{s}`\n", .{ path, x, y });
                }
            }
            done += n;
        }
        try w.print("fuzz: {d} expressions in {d} files, native {s} --run; --state=auto ran 2-state in {d} files, of which it reran {d} 4-state\n", .{ count, file, if (failed) "DIFFERS from" else "equals", twos + reruns, reruns });
        return if (failed) 1 else 0;
    }

    /// One design: `fuzz_vars` random four-state operands, then `n` lines, each
    /// one random expression printed self-determined or through an assignment
    /// to a random-width target (so its context width and signedness vary).
    /// `late`: every operand and literal known, and the lines one tick after
    /// them, so `--state=auto` computes them in its 2-state phase, where an x
    /// an operator makes is printed as 4-state prints it and storing one reruns
    /// the design 4-state.
    fn fuzzSource(a: Allocator, rand: std.Random, n: u32, late: bool) ![]const u8 {
        var out: Io.Writer.Allocating = .init(a);
        const o = &out.writer;
        var vars: [fuzz_vars]FuzzVar = undefined;
        try o.writeAll("module fuzz;\n");
        for (&vars, 0..) |*v, i| {
            v.* = .{ .width = fuzz_widths[rand.uintLessThan(usize, fuzz_widths.len)], .signed = rand.boolean() };
            try o.print("  reg {s}[{d}:0] v{d};\n", .{ if (v.signed) "signed " else "", v.width - 1, i });
        }
        try o.writeAll("  reg [7:0] mem [2:5];\n");
        for (fuzz_widths, 0..) |tw, i| try o.print("  reg {s}[{d}:0] t{d};\n", .{ if (i % 2 == 0) "signed " else "", tw - 1, i });
        try o.writeAll("  initial begin\n");
        // Half the operands fully known, or arithmetic would almost always see
        // an x and never reach its known-value path.
        for (vars, 0..) |v, i| try o.print("    v{d} = {f};\n", .{ i, FuzzBits{ .rand = rand, .width = v.width, .known = late or i % 2 == 0 } });
        for (2..6) |i| try o.print("    mem[{d}] = {f};\n", .{ i, FuzzBits{ .rand = rand, .width = 8, .known = late } });
        if (late) {
            for (fuzz_widths, 0..) |_, i| try o.print("    t{d} = 0;\n", .{i});
            try o.writeAll("    #1;\n");
        }
        for (0..n) |line| {
            var g: FuzzGen = .{ .rand = rand, .vars = &vars, .out = o, .known = late };
            // `%d` of more than 64 bits is refused by both engines alike, so it
            // is asked of an expression only when its width is at most 64. A
            // late design stores only in its last tenth: storing an x ends the
            // 2-state phase for every line after it.
            if (rand.boolean() or (late and line < n - n / 10)) {
                var e: Io.Writer.Allocating = .init(a);
                g.out = &e.writer;
                const ew = try g.expr(3);
                try o.print("    $display(\"%b {s}\", {s}, {s});\n", .{ if (ew <= 64 and rand.boolean()) "%d" else "%h", e.written(), e.written() });
            } else {
                const t = rand.uintLessThan(usize, fuzz_widths.len);
                try o.print("    t{d} = ", .{t});
                _ = try g.expr(3);
                try o.print(";\n    $display(\"%b {s}\", t{d}, t{d});\n", .{ if (fuzz_widths[t] <= 64) "%d" else "%h", t, t });
            }
        }
        try o.writeAll("  end\nendmodule\n");
        return out.written();
    }

    /// A sized binary literal of `width` random bits, mostly known.
    const FuzzBits = struct {
        rand: std.Random,
        width: u32,
        known: bool = false,

        /// `{f}`: writes `<width>'b` and the digits, drawing them from `rand`.
        pub fn format(self: FuzzBits, o: *Io.Writer) Io.Writer.Error!void {
            try o.print("{d}'b", .{self.width});
            for (0..self.width) |_| try o.writeByte(if (!self.known and self.rand.uintLessThan(u8, 8) == 0) "xz"[self.rand.uintLessThan(u8, 2)] else "01"[self.rand.uintLessThan(u8, 2)]);
        }
    };

    /// Random expressions over one- and multi-word operands, every one of which
    /// the native executable takes.
    const FuzzGen = struct {
        rand: std.Random,
        vars: []const FuzzVar,
        out: *Io.Writer,
        /// No x or z literal.
        known: bool = false,

        /// Writes one expression; returns its self-determined width.
        fn expr(g: *FuzzGen, depth: u32) Io.Writer.Error!u32 {
            const o = g.out;
            const r = g.rand;
            if (depth == 0 or r.uintLessThan(u8, 5) == 0) return g.leaf();
            switch (r.uintLessThan(u8, 12)) {
                0 => {
                    try o.writeAll(([_][]const u8{ "-", "~", "!", "&", "|", "^", "~&", "~^", "+" })[r.uintLessThan(usize, 9)]);
                    try o.writeByte('(');
                    const wa = try g.expr(depth - 1);
                    try o.writeByte(')');
                    return wa;
                },
                1, 2, 3 => {
                    try o.writeByte('(');
                    const wa = try g.expr(depth - 1);
                    try o.writeAll(([_][]const u8{ " + ", " - ", " * ", " / ", " % ", " & ", " | ", " ^ ", " ~^ " })[r.uintLessThan(usize, 9)]);
                    const wb = try g.expr(depth - 1);
                    try o.writeByte(')');
                    return @max(wa, wb);
                },
                4 => {
                    try o.writeByte('(');
                    _ = try g.expr(depth - 1);
                    try o.writeAll(([_][]const u8{ " == ", " != ", " === ", " !== ", " < ", " <= ", " > ", " >= ", " && ", " || " })[r.uintLessThan(usize, 10)]);
                    _ = try g.expr(depth - 1);
                    try o.writeByte(')');
                    return 1;
                },
                5 => {
                    try o.writeByte('(');
                    const wa = try g.expr(depth - 1);
                    try o.writeAll(([_][]const u8{ " << ", " >> ", " <<< ", " >>> ", " ** " })[r.uintLessThan(usize, 5)]);
                    if (r.boolean()) try o.print("{d}", .{r.uintLessThan(u32, 70)}) else _ = try g.expr(depth - 1);
                    try o.writeByte(')');
                    return wa;
                },
                6 => {
                    try o.writeByte('(');
                    _ = try g.expr(depth - 1);
                    try o.writeAll(" ? ");
                    const wa = try g.expr(depth - 1);
                    try o.writeAll(" : ");
                    const wb = try g.expr(depth - 1);
                    try o.writeByte(')');
                    return @max(wa, wb);
                },
                7 => {
                    const i = r.uintLessThan(usize, g.vars.len);
                    const j = r.uintLessThan(usize, g.vars.len);
                    try o.print("{{v{d}, v{d}}}", .{ i, j });
                    return g.vars[i].width + g.vars[j].width;
                },
                8 => {
                    const i = r.uintLessThan(usize, g.vars.len);
                    const n = 1 + r.uintLessThan(u32, 4);
                    try o.print("{{{d}{{v{d}}}}}", .{ n, i });
                    return n * g.vars[i].width;
                },
                9 => {
                    try o.writeAll(if (r.boolean()) "$signed(" else "$unsigned(");
                    const wa = try g.expr(depth - 1);
                    try o.writeByte(')');
                    return wa;
                },
                10 => {
                    const i = r.uintLessThan(usize, g.vars.len);
                    const vw = g.vars[i].width;
                    if (r.boolean()) {
                        try o.print("v{d}[", .{i});
                        try g.index();
                        try o.writeByte(']');
                        return 1;
                    }
                    const lo = r.uintLessThan(u32, vw);
                    const hi = lo + r.uintLessThan(u32, vw - lo);
                    try o.print("v{d}[{d}:{d}]", .{ i, hi, lo });
                    return hi - lo + 1;
                },
                else => {
                    try o.writeAll("mem[");
                    try g.index();
                    try o.writeByte(']');
                    return 8;
                },
            }
        }

        /// A leaf of at most 64 bits: the engine refuses a wider index.
        fn index(g: *FuzzGen) Io.Writer.Error!void {
            while (true) {
                const cut = g.out.end;
                if (try g.leaf() <= 64) return;
                g.out.end = cut;
            }
        }

        fn leaf(g: *FuzzGen) Io.Writer.Error!u32 {
            const o = g.out;
            const r = g.rand;
            switch (r.uintLessThan(u8, 6)) {
                0 => {
                    try o.print("{d}", .{r.uintLessThan(u32, 300)});
                    return 32;
                },
                1 => {
                    if (g.known) try o.writeAll(([_][]const u8{ "'b1", "-4'sd3", "'sd7", "'h5a" })[r.uintLessThan(usize, 4)]) else try o.writeAll(([_][]const u8{ "'bx", "'bz", "'hx1", "'b1", "-4'sd3", "4'sb1x01", "'sd7", "3'bz0x" })[r.uintLessThan(usize, 8)]);
                    return 32;
                },
                else => {
                    const i = r.uintLessThan(usize, g.vars.len);
                    try o.print("v{d}", .{i});
                    return g.vars[i].width;
                },
            }
        }
    };
};

const Golden = struct {
    //! The `golden` mode: what the compiler SAYS about every fixture, snapshotted,
    //! so a refactor can prove it changed nothing.
    //!
    //!   zig build suite -- golden before        # on the pre-change tree
    //!   zig build suite -- golden after         # ... the change ...
    //!   zig build suite -- golden diff          # before vs after; exit 1 on a difference
    //!   zig build suite -- golden diff A B      # two tags, or two snapshot directories
    //!
    //! A snapshot is `.zig-cache/vera-golden/<tag>/`, per `.va` and `.v` under
    //! the fixture root (the suite's `tests/`, not its `netlist/`):
    //!
    //!   <path>.txt           `vera --emit-zig` stdout, then a last line `exit=<code>`
    //!   <path>.stderr        its stderr: the message text is held too, and vera
    //!                        writes the device at offset 0, so one file would
    //!                        lose the warnings
    //!   <path>.runner.txt    a `.va` with a `//!` line: the testbench runner
    //!                        `tb.renderRunner` gives `--emit-exe` (`runner`)
    //!   <path>.so/...        a `.va`: the tree `--emit-so` writes before `zig`
    //!                        runs, `shim.zig` and the split device (`soTree`)
    //!   <path>.program.txt   a `.v`: the executable root `--emit-exe` builds
    //!                        (`digital.program`)
    //!
    //! The last three are made in-process through `vera`'s and `sim`'s API, not by
    //! spawning. A kind that fails is `error=<name>` in its own file (a `.so` tree
    //! is then `<path>.so.error.txt`), so it hides no other kind.
    //!
    //! Every file is written with the checkout's root cut out (`unrooted`): the
    //! fixture's absolute path reaches diagnostics, device and program text
    //! (`$fopen`, `$readmem`, the fallback's `file_name`), so two worktrees'
    //! snapshots are equal byte for byte. `diff` cuts it again, for snapshots an
    //! older tree wrote.
    //!
    //! Not a cacheable build step: the build graph cannot see fixture contents, so
    //! a cached run would compare nothing (`build.zig`'s note on the `suite` step).

    const std = @import("std");
    const options = @import("suite_options");
    const harness = Fixtures;
    const vera = @import("vera");
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
        var stderr = Io.File.stderr().writer(io, &buf);
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
        return snapshot(gpa, io, arena, vera_exe, try std.fs.path.join(arena, &.{ store, word }), w);
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
            const src = try std.fs.path.join(arena, &.{ options.fixture_root, rel });
            const base = try std.mem.concat(arena, u8, &.{ pool.out, "/", rel });
            const txt = try std.mem.concat(arena, u8, &.{ base, ".txt" });
            const err = try std.mem.concat(arena, u8, &.{ base, ".stderr" });
            try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(txt).?);
            const includes: []const []const u8 = &.{ harness.include_dir, std.fs.path.dirname(src).? };

            const code: u32 = code: {
                const out_file = try Io.Dir.cwd().createFile(io, txt, .{});
                defer out_file.close(io);
                const err_file = try Io.Dir.cwd().createFile(io, err, .{});
                defer err_file.close(io);
                var child = try std.process.spawn(io, .{
                    .argv = &.{
                        pool.vera,                  "--emit-zig",        "--color=never",
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

            const source = try readAll(io, arena, src);
            if (std.mem.endsWith(u8, rel, ".v")) {
                const text = program(arena, io, src, includes, source) catch |e| try arena.print("error={t}\n", .{e});
                return save(io, arena, try std.mem.concat(arena, u8, &.{ base, ".program.txt" }), text);
            }
            if (harness.hasDirective(source)) {
                const text = runner(pool.gpa, arena, src, includes, source) catch |e| try arena.print("error={t}\n", .{e});
                try save(io, arena, try std.mem.concat(arena, u8, &.{ base, ".runner.txt" }), text);
            }
            const so = try std.mem.concat(arena, u8, &.{ base, ".so" });
            if (soTree(pool.gpa, io, arena, src, includes, source, so)) |_| {
                for (try fileList(arena, io, so)) |p| {
                    const path = try std.fs.path.join(arena, &.{ so, p });
                    try save(io, arena, path, try readAll(io, arena, path));
                }
            } else |e| try save(io, arena, try std.mem.concat(arena, u8, &.{ so, ".error.txt" }), try arena.print("error={t}\n", .{e}));
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
        const d = try vera.tb.parse(arena, source);
        var bag: vera.diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var opts: vera.Options = .{
            .file_name = src,
            .include_dirs = includes,
            .require_std_includes = true,
            .diags = &bag,
            .display = if (d.display_record) .record else .emit,
            .spice_netlist = d.spice,
            .spice_path = src,
            .discipline_resolution = d.discipline_resolution,
        };
        var result = try vera.compileSourceOpts(gpa, source, .build, opts);
        defer result.deinit();
        // §3.4 a shape card is a compile-time value: compile again, as vera does.
        opts.param_overrides = try vera.tb.shapeOverrides(arena, d, result.lowered);
        if (opts.param_overrides.len != 0) {
            bag.deinit(gpa);
            bag = .init(gpa);
            const again = try vera.compileSourceOpts(gpa, source, .build, opts);
            result.deinit();
            result = again;
        }
        var dm = d;
        dm.mixed = vera.tb.mixedPlan(result.lowered, result.mir);
        dm.op_states = try vera.tb.opStates(arena, result.lowered);
        dm.mem_bytes = vera.tb.memBytes(result.lowered);
        dm.validate_contract = true;
        return vera.tb.renderRunner(arena, std.fs.path.stem(src), dm);
    }

    /// The tree `vera --emit-so` writes for a `.va` device before `zig` runs
    /// (`orchestrator.writeTree`): `shim.zig`, and the split `device.zig`, `h.zig`
    /// and `u/*.zig`. A split LLVM build's part and chunk shims and the engine
    /// root are written only beside a `zig` child; `zigbuild/shim.zig`'s whole-file
    /// tests pin those.
    fn soTree(gpa: Allocator, io: Io, arena: Allocator, src: []const u8, includes: []const []const u8, source: []const u8, dir: []const u8) !void {
        var bag: vera.diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        // `.record` is `vera`'s default display (`args.Cli`), not `Options`'.
        var result = try vera.compileSourceOpts(gpa, source, .build, .{ .file_name = src, .include_dirs = includes, .require_std_includes = true, .diags = &bag, .display = .record });
        defer result.deinit();
        const device = try result.generateOutput();
        if (result.device_has_compile_error) return error.CodegenRefused;
        _ = try vera.orchestrator.writeTree(io, gpa, .{
            .work_dir = dir,
            .name = try vera.orchestrator.fileStem(arena, result.mir.name),
            .optimize = .fast,
            .backend = .llvm,
            .modules = &.{},
        }, device);
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
    /// decks), relative to the root.
    fn fixtureList(arena: Allocator, io: Io) ![]const []const u8 {
        var dir = try Io.Dir.cwd().openDir(io, options.fixture_root, .{ .iterate = true });
        defer dir.close(io);
        var list: std.ArrayList([]const u8) = .empty;
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file or std.mem.startsWith(u8, e.path, "netlist" ++ std.fs.path.sep_str)) continue;
            if (!std.mem.endsWith(u8, e.path, ".va") and !std.mem.endsWith(u8, e.path, ".v")) continue;
            try list.append(arena, try arena.dupe(u8, e.path));
        }
        std.mem.sort([]const u8, list.items, {}, harness.strLess);
        return list.items;
    }

    /// Replaces the snapshot at `out` with a fresh one, one `vera` per CPU.
    fn snapshot(gpa: Allocator, io: Io, arena: Allocator, vera_exe: []const u8, out: []const u8, w: *Io.Writer) !u8 {
        Io.Dir.cwd().deleteTree(io, out) catch {};
        try Io.Dir.cwd().createDirPath(io, out);
        // Absolute, because each child runs from the repository root.
        const exe = try Io.Dir.cwd().realPathFileAlloc(io, vera_exe, arena);
        var pool: Pool = .{ .io = io, .gpa = gpa, .vera = exe, .out = out, .rels = try fixtureList(arena, io) };
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

    /// `diff -r a b` with every `<root>/tests/conformance/tests/` written `tests/conformance/tests/`
    /// on both sides. Prints one line per file that is missing or differs, then
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

    /// `text` with each absolute path's root cut back to `tests/conformance/tests`.
    /// A path starts after a space, quote, backtick or parenthesis, or at a line
    /// start, and must start with `/`. It may name the fixture root itself, as
    /// the include-search note does (`searched: <root>/tests/conformance/tests, ...`).
    fn unrooted(arena: Allocator, text: []const u8) ![]const u8 {
        const key = "/tests/conformance/tests";
        var out: std.ArrayList(u8) = .empty;
        var rest = text;
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
        return out.items;
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
    }
};

const Ieee1364 = struct {
    //! `zig build suite -- ieee1364 --coverage`: `<vera_root>/clauses/ieee1364/CLAUSES.tsv`
    //! (the clause table: every IEEE 1364-2005 clause, its title and its kind),
    //! every `.v` case under the suite's `verilog/` and every `.c` in build.zig's
    //! `vpi_runs` -> the work lists and summary over those clauses, plus one row
    //! per chapter.
    //!
    //! Static: nothing is compiled or run, so a cite (`//! inherited IEEE 1364-2005
    //! <clause>`) says what a fixture claims, not that it passes. A `.c` fixture's
    //! polarity is per line (`//! inherited-reject IEEE 1364-2005 <clause>` for a
    //! refusal).

    const std = @import("std");
    const harness = Fixtures;
    const digital = Digital;

    /// The kinds a `CLAUSES.tsv` row may name, spelled with hyphens in the file
    /// (`non-normative`): a clause that states no obligation a fixture pins, or
    /// one whose obligation is of a kind a fixture may not pin one way.
    /// `no_prohibition` is a normative clause whose every sentence is positive,
    /// so its positive fixtures are the whole obligation; it is refused unless a
    /// positive fixture cites the clause. `not_supported` is a clause out of
    /// VerA's scope, which it refuses or warns about by name.
    pub const ClassKind = enum {
        non_normative,
        no_prohibition,
        optional,
        implementation_defined,
        resource_limit,
        unspecified,
        not_supported,
    };
    const options = @import("suite_options");

    const Io = std.Io;
    const Allocator = std.mem.Allocator;

    const Clause = struct {
        id: []const u8,
        title: []const u8,
        /// `null` is an ordinary clause (`-` in the file).
        kind: ?ClassKind,
        pos: bool = false,
        neg: bool = false,
    };

    /// Per clause chapter (`5`, `17`, `A`): the fixtures in its directory and how
    /// its clauses are evidenced.
    const Chapter = struct {
        fixtures: u32 = 0,
        uncited_fixtures: u32 = 0,
        clauses: u32 = 0,
        both: u32 = 0,
        pos_only: u32 = 0,
        neg_only: u32 = 0,
        uncited: u32 = 0,
        classified: u32 = 0,
    };

    /// Prints the report to stderr. Returns exit code 1 when a cite names no
    /// clause in the table or a CLAUSES.tsv row is rejected, else 0.
    pub fn coverage(init: std.process.Init) !u8 {
        const io = init.io;
        var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var buf: [4096]u8 = undefined;
        var stderr = Io.File.stderr().writer(io, &buf);
        const w = &stderr.interface;
        defer w.flush() catch {};

        const root = options.fixture_root ++ "/" ++ Devices.ieee1364_dir;
        var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);

        // The clause table, in table-of-contents order.
        var clauses: std.ArrayList(Clause) = .empty;
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        var bad: usize = 0;
        {
            const text = try Io.Dir.cwd().readFileAlloc(io, options.vera_root ++ "/clauses/ieee1364/CLAUSES.tsv", arena, .limited(1 << 20));
            var lines = std.mem.splitScalar(u8, text, '\n');
            var line_no: usize = 0;
            while (lines.next()) |raw| {
                line_no += 1;
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (line.len == 0 or line[0] == '#') continue;
                const c = parseRow(arena, line) catch |err| {
                    try w.print("BAD CLAUSES.tsv ROW — line {d}: {s}\n", .{ line_no, @errorName(err) });
                    bad += 1;
                    continue;
                };
                const g = try index.getOrPut(arena, c.id);
                if (g.found_existing) {
                    try w.print("BAD CLAUSES.tsv ROW — line {d}: duplicate clause {s}\n", .{ line_no, c.id });
                    bad += 1;
                    continue;
                }
                g.value_ptr.* = clauses.items.len;
                try clauses.append(arena, c);
            }
        }

        try w.writeAll(
            "STATIC CITATION INVENTORY — IEEE 1364-2005, fixtures under verilog/.\n" ++
                "Fixtures are not executed by --coverage; both polarities cited does not\n" ++
                "establish passing tests or every rule within a clause.\n\n",
        );

        var chapters: std.StringArrayHashMapUnmanaged(Chapter) = .empty;
        var fixtures: usize = 0;
        var citing: usize = 0;
        var unresolved: usize = 0;
        var uncited_paths: std.ArrayList([]const u8) = .empty;
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".v")) continue;
            // `pli/`'s designs are the `.c` fixtures' (`vpi_runs`, below).
            if (std.mem.startsWith(u8, e.path, "pli" ++ std.fs.path.sep_str)) continue;
            const path = try arena.dupe(u8, e.path);
            const source = try dir.readFileAlloc(io, path, arena, .limited(1 << 20));
            const neg = digital.negative(source);
            // A source a case reads through `//@ files` has no golden and is not
            // a case.
            if (!neg) for ([_][]const u8{ ".expected.txt", ".expected.vcd" }) |ext| {
                if (dir.access(io, try std.mem.concat(arena, u8, &.{ path[0 .. path.len - 2], ext }), .{})) |_| break else |_| {}
            } else continue;
            const ch = try chapterOf(&chapters, arena, path);
            fixtures += 1;
            ch.fixtures += 1;
            var cites: std.ArrayList([]const u8) = .empty;
            try inheritedCites(arena, source, pos_key, &cites);
            if (cites.items.len == 0) {
                ch.uncited_fixtures += 1;
                try uncited_paths.append(arena, path);
                continue;
            }
            citing += 1;
            for (cites.items) |id| {
                const i = index.get(id) orelse {
                    try w.print("UNRESOLVED — verilog/{s} cites §{s}, which CLAUSES.tsv does not list\n", .{ path, id });
                    unresolved += 1;
                    continue;
                };
                if (neg) clauses.items[i].neg = true else clauses.items[i].pos = true;
            }
        }

        // Only a `.c` fixture that runs is evidence: `vpi_runs` is build.zig's
        // list of those, relative to the repository.
        for (options.vpi_runs) |rel| {
            const source = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ options.repo_root, rel }), arena, .limited(1 << 20));
            var pos: std.ArrayList([]const u8) = .empty;
            var neg: std.ArrayList([]const u8) = .empty;
            try inheritedCites(arena, source, pos_key, &pos);
            try inheritedCites(arena, source, neg_key, &neg);
            if (pos.items.len + neg.items.len == 0) continue;
            fixtures += 1;
            citing += 1;
            for ([_][]const []const u8{ pos.items, neg.items }, [_]bool{ false, true }) |ids, is_neg| {
                for (ids) |id| {
                    const i = index.get(id) orelse {
                        try w.print("UNRESOLVED — {s} cites §{s}, which CLAUSES.tsv does not list\n", .{ rel, id });
                        unresolved += 1;
                        continue;
                    };
                    if (is_neg) clauses.items[i].neg = true else clauses.items[i].pos = true;
                }
            }
        }

        // A classification moves a one-way or uncited clause out of its work
        // list; two-way evidence wins.
        for (clauses.items) |c| {
            if (c.kind == .no_prohibition and !c.pos) {
                try w.print("BAD CLAUSES.tsv ROW — §{s}: no-prohibition, but no positive fixture cites it\n", .{c.id});
                bad += 1;
            }
        }
        var total: Chapter = .{};
        const headers = [_][]const u8{
            "",
            "\nPOSITIVE CITATIONS ONLY — no rejection fixture cites these:\n",
            "\nREJECTION CITATIONS ONLY — no positive behaviour is established:\n",
            "\nUNCITED — no fixture names these at all:\n",
            "\nCLASSIFIED — CLAUSES.tsv says the clause states no obligation a fixture pins,\n" ++
                "or (not_supported) that it is out of VerA's scope and VerA refuses or warns:\n",
        };
        for ([_]Bucket{ .pos_only, .neg_only, .uncited, .classified }) |want| {
            var printed = false;
            for (clauses.items) |c| {
                if (bucketOf(c) != want) continue;
                if (!printed) try w.writeAll(headers[@backingInt(want)]);
                printed = true;
                if (want == .classified)
                    try w.print("§{s} {s}  [{s}]\n", .{ c.id, c.title, @tagName(c.kind.?) })
                else
                    try w.print("§{s} {s}\n", .{ c.id, c.title });
            }
        }
        for (clauses.items) |c| {
            const ch = try chapters.getOrPut(arena, topOf(c.id));
            if (!ch.found_existing) ch.value_ptr.* = .{};
            inline for (.{ ch.value_ptr, &total }) |t| {
                t.clauses += 1;
                switch (bucketOf(c)) {
                    .both => t.both += 1,
                    .pos_only => t.pos_only += 1,
                    .neg_only => t.neg_only += 1,
                    .uncited => t.uncited += 1,
                    .classified => t.classified += 1,
                }
            }
        }

        if (uncited_paths.items.len != 0) {
            std.mem.sort([]const u8, uncited_paths.items, {}, harness.strLess);
            try w.writeAll("\nFIXTURES CITING NO 1364-2005 CLAUSE — they run, and count for nothing here:\n");
            for (uncited_paths.items) |p| try w.print("  verilog/{s}\n", .{p});
        }

        try w.writeAll("\nchapter\tfixtures\tuncited-fixtures\tclauses\tboth\tpos-only\trej-only\tuncited\tclassified\n");
        for (clauses.items) |c| {
            if (std.mem.findScalar(u8, c.id, '.') != null) continue;
            const t = chapters.get(c.id).?;
            try w.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
                c.id, t.fixtures, t.uncited_fixtures, t.clauses, t.both, t.pos_only, t.neg_only, t.uncited, t.classified,
            });
        }

        const n = clauses.items.len;
        var uncited_classified: usize = 0;
        for (clauses.items) |c| {
            if (c.kind != null and !c.pos and !c.neg) uncited_classified += 1;
        }
        try w.print(
            "\n{d} of {d} IEEE 1364-2005 clauses cited, by {d} of {d} fixtures\n" ++
                "  {d} cited both ways · {d} positive citations only · {d} rejection citations only · {d} uncited · {d} classified\n",
            .{
                n - total.uncited - uncited_classified, n,
                citing,                                 fixtures,
                total.both,                             total.pos_only,
                total.neg_only,                         total.uncited,
                total.classified,
            },
        );
        if (unresolved != 0) try w.print("{d} cite(s) resolve to no clause\n", .{unresolved});
        if (bad != 0) try w.print("{d} CLAUSES.tsv row(s) rejected\n", .{bad});
        return if (unresolved == 0 and bad == 0) 0 else 1;
    }

    const Bucket = enum { both, pos_only, neg_only, uncited, classified };

    fn bucketOf(c: Clause) Bucket {
        if (c.pos and c.neg) return .both;
        if (c.kind != null) return .classified;
        if (c.pos) return .pos_only;
        if (c.neg) return .neg_only;
        return .uncited;
    }

    /// `5.1.14` -> `5`, `A.6.7` -> `A`.
    fn topOf(id: []const u8) []const u8 {
        return id[0 .. std.mem.findScalar(u8, id, '.') orelse id.len];
    }

    /// The chapter a fixture's directory files it under: `05_expressions/x.v` -> `5`.
    fn chapterOf(map: *std.StringArrayHashMapUnmanaged(Chapter), arena: Allocator, path: []const u8) !*Chapter {
        const dir = path[0 .. std.mem.findScalar(u8, path, '/') orelse 0];
        var id = dir[0 .. std.mem.findScalar(u8, dir, '_') orelse dir.len];
        id = std.mem.trimStart(u8, id, "0");
        const g = try map.getOrPut(arena, id);
        if (!g.found_existing) g.value_ptr.* = .{};
        return g.value_ptr;
    }

    fn parseRow(arena: Allocator, line: []const u8) !Clause {
        var cols = std.mem.splitScalar(u8, line, '\t');
        const id = cols.next() orelse return error.MissingClause;
        if (id.len == 0) return error.MissingClause;
        const kind_text = cols.next() orelse return error.MissingKind;
        const title = cols.next() orelse return error.MissingTitle;
        const evidence = std.mem.trim(u8, cols.rest(), " \t");
        if (std.mem.eql(u8, kind_text, "-")) return .{ .id = id, .title = title, .kind = null };
        const spelled = try arena.dupe(u8, kind_text);
        std.mem.replaceScalar(u8, spelled, '-', '_');
        const kind = std.meta.stringToEnum(ClassKind, spelled) orelse return error.UnknownKind;
        if (evidence.len == 0) return error.MissingEvidence;
        return .{ .id = id, .title = title, .kind = kind };
    }

    const pos_key = "inherited IEEE 1364-2005 ";
    const neg_key = "inherited-reject IEEE 1364-2005 ";

    /// `//! inherited IEEE 1364-2005 17.5.1,17.5.3 (note)` -> `17.5.1`, `17.5.3`,
    /// for `key` the text after `//!`. Clauses are the words before a
    /// parenthesised note, split on spaces and commas; a word that is not a clause
    /// number is returned as-is and so reported unresolved rather than silently
    /// dropped.
    fn inheritedCites(arena: Allocator, source: []const u8, key: []const u8, out: *std.ArrayList([]const u8)) !void {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "//!")) continue;
            const rest = std.mem.trimStart(u8, line["//!".len..], " \t");
            if (!std.mem.startsWith(u8, rest, key)) continue;
            const list = rest[key.len..];
            var words = std.mem.tokenizeAny(u8, list[0 .. std.mem.findScalar(u8, list, '(') orelse list.len], " ,");
            while (words.next()) |id| try out.append(arena, id);
        }
    }

    test "inherited cites: lists, commas, and a note that is not a clause" {
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var got: std.ArrayList([]const u8) = .empty;
        try inheritedCites(arena,
            \\// inherited IEEE 1364-2005 9.9 in prose is not a cite
            \\//! lrm 9.8
            \\//! inherited IEEE 1364-2005 17.5.1,17.5.3
            \\  //! inherited IEEE 1364-2005 12.4.1 5.2.1 (loop generate, 17.1)
            \\//! inherited-reject IEEE 1364-2005 27.14
        , pos_key, &got);
        const want = [_][]const u8{ "17.5.1", "17.5.3", "12.4.1", "5.2.1" };
        try std.testing.expectEqual(want.len, got.items.len);
        for (want, got.items) |a, b| try std.testing.expectEqualStrings(a, b);
        got.clearRetainingCapacity();
        try inheritedCites(arena, "//! inherited-reject IEEE 1364-2005 27.14\n", neg_key, &got);
        try std.testing.expectEqual(@as(usize, 1), got.items.len);
    }
};

const Lint = struct {
    //! The assertion lint, the mechanical half of "restricting and true": a
    //! fixture's raw source -> whether every `CHECK*` call in it can fail. A want
    //! must be a numeric literal a human derived, so the compiler under test never
    //! supplies its own expectation. Two exemptions, each argued at its function:
    //! `CHECKEQ` (two expressions on purpose) and a want piecewise in `$abstime`.
    //!
    //! LRM clauses: §10.3 (what counts as a macro call), §2.5.1 and §2.6 (how a
    //! literal and a scale factor are spelled), §4.5.3 (why a want may be
    //! piecewise in time).

    const std = @import("std");

    /// The assertion lint's finding for one source.
    const AssertionCheck = union(enum) {
        /// At least one assertion, and every one of them can fail.
        ok,
        /// No `CHECK` macro anywhere in the source.
        none,
        /// `CHECK("x", expr, expr, tol)` — got and want are textually identical.
        tautology: []const u8,
        /// The want is not a numeric literal, so it may be the compiler's own output.
        computed_want: []const u8,
    };

    /// Lints the `CHECK*` calls in raw source: every want must be a literal a
    /// human typed, never an expression the compiler under test evaluates.
    /// `CHECK("sin", sin(0.5), sin(0.5), 1e-15)` passes in any compiler; this
    /// rejects it. Whether the literal is right is the reviewer's job.
    pub fn checkAssertions(source: []const u8) AssertionCheck {
        var found = false;
        var scan: MacroScan = .{ .src = source };
        while (scan.next()) |call| {
            const rest = source[call.at..];
            const open = call.open - call.at;
            // An unbalanced `(` is a syntax error the compile will report; it is not
            // this lint's business, and it must not abandon the CHECKs after it.
            const close = matchParen(rest, open) orelse continue;
            const site = trimLine(rest[0..@min(close + 1, rest.len)]);

            // `CHECKEQ` is the marked relational form: its want is another
            // expression on purpose, so the literal rule does not apply to it.
            const relational = std.mem.eql(u8, call.name, "CHECKEQ");

            var args: [8][]const u8 = undefined;
            const n = splitArgs(rest[open + 1 .. close], &args);
            // NAME, GOT, WANT[, TOL] — every CHECK* form puts the want third.
            if (n < 3) continue;
            found = true;

            const got = stripParens(std.mem.trim(u8, args[1], " \t\r\n\\"));
            const want = stripParens(std.mem.trim(u8, args[2], " \t\r\n\\"));
            if (std.mem.eql(u8, got, want)) {
                // Two identical LITERALS are a round-trip check on the lexer
                // (`CHECKI("unary minus", -7, -7)`) — weak, but it can fail if a
                // literal is mangled on one side. Two identical EXPRESSIONS cannot
                // fail at all, whatever the compiler does.
                if (!isNumericLiteral(got)) return .{ .tautology = site };
            } else if (!relational and !isNumericLiteral(want) and !isTimePiecewiseWant(want)) {
                return .{ .computed_want = site };
            }
        }
        return if (found) .ok else .none;
    }

    /// Finds each `CHECK*` macro call outside comments and string literals. A call
    /// is §10.3's `` `identifier `` followed by `(` with at most horizontal white
    /// space between; a name with no argument list is not a call, so it cannot
    /// borrow a later `(` from unrelated text.
    const MacroScan = struct {
        src: []const u8,
        i: usize = 0,

        const Call = struct {
            /// Spelling without the backtick, so `CHECKEQ` is compared and not
            /// prefix-matched — `CHECKEQX` would be a different macro.
            name: []const u8,
            /// Index of the backtick, where a quoted site starts.
            at: usize,
            /// Index of the `(` that opens the actual arguments.
            open: usize,
        };

        fn next(s: *MacroScan) ?Call {
            while (s.i < s.src.len) {
                switch (s.src[s.i]) {
                    '/' => if (s.i + 1 < s.src.len) switch (s.src[s.i + 1]) {
                        '/' => {
                            s.i = std.mem.findScalarPos(u8, s.src, s.i, '\n') orelse s.src.len;
                            continue;
                        },
                        '*' => {
                            const end = std.mem.findPos(u8, s.src, s.i + 2, "*/");
                            s.i = if (end) |e| e + 2 else s.src.len;
                            continue;
                        },
                        else => {},
                    },
                    // A string literal holds a CHECK's own NAME argument, and names
                    // quote code: `CHECKX("`CHECKEQ would be vacuous here", …)`.
                    '"' => {
                        s.i += 1;
                        while (s.i < s.src.len and s.src[s.i] != '"') : (s.i += 1) {
                            if (s.src[s.i] == '\\') s.i += 1;
                        }
                    },
                    '`' => {
                        const at = s.i;
                        var j = at + 1;
                        while (j < s.src.len and isIdentChar(s.src[j])) j += 1;
                        var k = j;
                        while (k < s.src.len and (s.src[k] == ' ' or s.src[k] == '\t')) k += 1;
                        s.i = j; // always progress: `j > at`, even for a bare backtick
                        const name = s.src[at + 1 .. j];
                        if (std.mem.startsWith(u8, name, "CHECK") and
                            k < s.src.len and s.src[k] == '(')
                        {
                            s.i = k;
                            return .{ .name = name, .at = at, .open = k };
                        }
                        continue;
                    },
                    else => {},
                }
                s.i += 1;
            }
            return null;
        }
    };

    fn isIdentChar(c: u8) bool {
        return c == '_' or c == '$' or std.ascii.isAlphanumeric(c);
    }

    /// Drop redundant outer parentheses, so `(V(a,b))` and `V(a,b)` compare equal.
    /// Otherwise parens around one side would hide a tautology.
    fn stripParens(s: []const u8) []const u8 {
        var t = std.mem.trim(u8, s, " \t\r\n");
        while (t.len >= 2 and t[0] == '(' and matchParen(t, 0) == t.len - 1) {
            t = std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n");
        }
        return t;
    }

    /// Index of the `)` closing the `(` at `open`, or null if unbalanced. String
    /// literals are skipped so a `")"` inside a CHECK's name does not close it.
    fn matchParen(s: []const u8, open: usize) ?usize {
        var depth: usize = 0;
        var i = open;
        var in_string = false;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (in_string) {
                if (c == '\\') i += 1 else if (c == '"') in_string = false;
                continue;
            }
            switch (c) {
                '"' => in_string = true,
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                else => {},
            }
        }
        return null;
    }

    /// Split on TOP-LEVEL commas only: `CHECKR("atan2(1,1)", atan2(1.0, 1.0), …)`
    /// has commas inside both a string and a nested call, and neither separates an
    /// argument. Returns the count written.
    fn splitArgs(s: []const u8, out: *[8][]const u8) usize {
        var n: usize = 0;
        var depth: usize = 0;
        var in_string = false;
        var start: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (in_string) {
                if (c == '\\') i += 1 else if (c == '"') in_string = false;
                continue;
            }
            switch (c) {
                '"' => in_string = true,
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                ',' => if (depth == 0) {
                    if (n == out.len) return n;
                    out[n] = s[start..i];
                    n += 1;
                    start = i + 1;
                },
                else => {},
            }
        }
        if (n < out.len and start <= s.len) {
            out[n] = s[start..];
            n += 1;
        }
        return n;
    }

    /// Is this text a number a human wrote, and nothing else?
    ///
    /// Deliberately strict. A leading sign and a Verilog-A real or integer literal
    /// are all that is allowed — no `M_PI`, no `1.0/3.0`, no identifiers. A fixture
    /// that wants pi writes its digits, which is what a reviewer checks against the
    /// LRM anyway, and which no amount of compiler misbehaviour can change.
    fn isNumericLiteral(s: []const u8) bool {
        var t = s;
        if (t.len != 0 and (t[0] == '+' or t[0] == '-')) t = t[1..];
        if (t.len == 0) return false;

        var seen_digit = false;
        var seen_dot = false;
        var i: usize = 0;
        while (i < t.len) : (i += 1) {
            switch (t[i]) {
                '0'...'9' => seen_digit = true,
                '_' => {}, // §2.5.1 allows underscores in numbers.
                '.' => {
                    if (seen_dot) return false;
                    seen_dot = true;
                },
                'e', 'E' => {
                    if (!seen_digit) return false;
                    // Exponent: an optional sign then digits, to the end.
                    var j = i + 1;
                    if (j < t.len and (t[j] == '+' or t[j] == '-')) j += 1;
                    if (j == t.len) return false;
                    while (j < t.len) : (j += 1) switch (t[j]) {
                        '0'...'9', '_' => {},
                        else => return false,
                    };
                    return true;
                },
                else => return false,
            }
        }
        return seen_digit;
    }

    /// The one widening of the literal rule: a want that is piecewise in TIME.
    ///
    /// A transient fixture's expectation often changes at a `//! time` point —
    /// §4.5.3 makes `ddt` zero at the DC point that opens the analysis and the ramp
    /// slope after it, so "0 then 1.0" is one claim about one branch and splitting
    /// it across two fixtures would test less, not more. Writing it as
    /// `($abstime > 0) * 1.0` is not the thing the literal rule exists to stop: the
    /// DIGITS are still typed by a human, and `$abstime` is a harness INPUT — the
    /// `//! time` line supplies it — not something the compiler under test derives.
    ///
    /// The exemption is therefore exactly as narrow as that argument: the want may
    /// mention `$abstime` and nothing else with a name. Every other identifier is
    /// refused, so a want cannot smuggle in `V(p)`, a parameter, or a call and
    /// launder the compiler's own answer through a conditional. A want with NO
    /// identifier at all is not exempt either — `2.0*1e-18` restates a derivation
    /// instead of stating a number, which is the original rule's point.
    ///
    /// An identifier is a run starting at a letter, `_` or `$` that is not preceded
    /// by one — so the `n` of `1n` (§2.6's scale factor) is part of the number and
    /// not a name.
    fn isTimePiecewiseWant(s: []const u8) bool {
        var found_abstime = false;
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            const starts = (std.ascii.isAlphabetic(c) or c == '_' or c == '$') and
                (i == 0 or !(std.ascii.isAlphanumeric(s[i - 1]) or s[i - 1] == '_' or s[i - 1] == '.'));
            if (!starts) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_' or s[j] == '$')) j += 1;
            if (!std.mem.eql(u8, s[i..j], "$abstime")) return false;
            found_abstime = true;
            i = j;
        }
        return found_abstime;
    }

    /// The macro call as one line, for an error message. A CHECK often spans lines
    /// via `\` continuations, and a four-line quote buries the point.
    fn trimLine(s: []const u8) []const u8 {
        const end = std.mem.findScalar(u8, s, '\n') orelse s.len;
        return std.mem.trim(u8, s[0..end], " \t\r\\");
    }

    test "an assertion whose want is the got cannot fail" {
        try std.testing.expect(checkAssertions(
            \\`CHECK("sin", sin(0.5), sin(0.5), 1e-15);
        ) == .tautology);
        try std.testing.expect(checkAssertions(
            \\`CHECKX("round trip", y, expected_y);
        ) == .computed_want);
        try std.testing.expect(checkAssertions("I(p,n) <+ 1.0;") == .none);
        try std.testing.expect(checkAssertions(
            \\`CHECKR("atan2(1,1)", atan2(1.0, 1.0), 0.7853981633974483, 1e-15);
        ) == .ok);
        // A negative and an exponent are both literals a human typed.
        try std.testing.expect(checkAssertions(
            \\`CHECK("limexp underflow", limexp(-80.0), -1.8048513878454153e-35, 1e-40);
        ) == .ok);
        // A concatenation's comma is inside the got, not between arguments.
        try std.testing.expect(checkAssertions(
            \\`CHECKI("concatenation", {4'h1, 16'h5}, 65541);
        ) == .ok);
        // Two identical literals round-trip the lexer; two identical expressions
        // cannot fail whatever the compiler does.
        try std.testing.expect(checkAssertions(
            \\`CHECKI("unary minus", -7, -7);
        ) == .ok);
        try std.testing.expect(checkAssertions(
            \\`CHECKI("above threshold?", V(p, n) > vth, (V(p, n) > vth));
        ) == .tautology);
        // A want piecewise in TIME is exempt: the digits are still a human's and
        // `$abstime` is what the `//! time` line put there, not something the
        // compiler under test worked out.
        try std.testing.expect(checkAssertions(
            \\`CHECK("ddt is zero at the DC point and the slope after it", I(cap), ($abstime > 0) * 1.0, 1e-9);
        ) == .ok);
        try std.testing.expect(checkAssertions(
            \\`CHECKX("three levels", Vgain * val, ($abstime < 4n) ? 0.25 : (($abstime < 12n) ? 0.5 : 0.75));
        ) == .ok);
        // ...and exactly that narrow. One other name in the want and the
        // exemption is gone, or a conditional would launder the compiler's own
        // answer past the rule.
        try std.testing.expect(checkAssertions(
            \\`CHECK("laundered", I(cap), ($abstime > 0) * V(p, n), 1e-9);
        ) == .computed_want);
        try std.testing.expect(checkAssertions(
            \\`CHECK("laundered through a parameter", I(cap), ($abstime > 0) * c, 1e-9);
        ) == .computed_want);
        // A want with no name at all restates a derivation instead of stating a
        // number, which is the rule's original point and is still refused.
        try std.testing.expect(checkAssertions(
            \\`CHECK("arithmetic", x, 2.0 * 1e-18, 1e-30);
        ) == .computed_want);
        // The marked relational form may pin two expressions together...
        try std.testing.expect(checkAssertions(
            \\`CHECKEQ("branch probe equals the node pair", V(br), V(a, b), 0.0);
        ) == .ok);
        // ...but not to itself.
        try std.testing.expect(checkAssertions(
            \\`CHECKEQ("vacuous", V(a, b), V(a, b), 0.0);
        ) == .tautology);
    }

    test "the assertion lint reads code, not prose" {
        // A name with no argument list must not borrow a `(` from later text.
        try std.testing.expect(checkAssertions(
            \\// so this assertion is `CHECKX and not a tolerance.
            \\I(p, n) <+ ddt(V(p, n), 1.0);
        ) == .none);
        try std.testing.expect(checkAssertions(
            \\// An earlier revision wrote `CHECKEQ(y, expected_y) here.
            \\`CHECKX("real", V(p, n), 0.5);
        ) == .ok);
        // A comment naming the macro is not an invocation even when it quotes a
        // full argument list.
        try std.testing.expect(checkAssertions(
            \\// It WAS `CHECKEQ("x", code, $fseek(fd, 0, 0), 0), which asserted nothing.
        ) == .none);
        try std.testing.expect(checkAssertions(
            \\/* `CHECK("sin", sin(0.5), sin(0.5), 1e-15); */
        ) == .none);
        // A name argument may quote a macro; the quote is data.
        try std.testing.expect(checkAssertions(
            \\`CHECKX("`CHECKEQ(V(a,b), V(a,b)) would be vacuous", V(a, b), 0.5);
        ) == .ok);
        // §10.3 allows horizontal white space before the actual arguments, but a
        // newline ends the usage: the name would be a macro taking no arguments.
        try std.testing.expect(checkAssertions(
            \\`CHECKX ("spaced", V(a, b), 0.5);
        ) == .ok);
        // An unbalanced paren is the compiler's error to report, and must not hide
        // the real defect after it.
        try std.testing.expect(checkAssertions(
            \\`CHECKX("truncated", V(a, b, 0.5);
        ) == .none);
    }
};

const Native = struct {
    //! `--native`: the same cases through `vera --emit-exe` and the executable it
    //! builds. The golden `--run` matches is the oracle, so matching it is matching
    //! the interpreter and neither engine runs twice. Every case is also one of
    //! three name lists — `NATIVE`, `FALLBACK <reason>` (the executable embeds the
    //! interpreter, `rt.interpret`) or `FAIL` — so native coverage is diffed by
    //! name, and a fallback that hides a regression shows up as a moved name.
    //! A `// native-required` fixture makes that fallback a FAIL in native modes.
    //! The forced two-state report keeps its separate x/z refusal policy below.
    //!
    //!   zig build suite -- ieee1364 --native            # all of IEEE 1364
    //!   zig build suite -- ieee1364 --native=static     # combinational logic levelized
    //!   zig build suite -- devices --native d04     # the cases whose name has d04
    //!   zig build suite -- ieee1364 --native=two-state  # a report, not a gate: see below
    //!   zig build suite -- ieee1364 --native=snapshot   # every tick run twice (below)
    //!
    //! `--snapshot` (after any `--native=`) runs each executable with
    //! `--vera-snapshot`: at every tick boundary its state is saved, the tick run
    //! quietly, the state restored and the tick run again (`rt/snapshot.zig`).
    //! The transcript must still be the golden.
    //!
    //! `--two-state` makes every x or z 0, so its transcript is not the golden.
    //! A case passes when each line that differs shows an x or z digit in the
    //! golden; FALLBACK is then every case `--two-state` refuses (E1101).

    const std = @import("std");
    const options = @import("suite_options");
    const harness = Fixtures;
    const devices = Devices;
    const digital = Digital;
    const child = Child;

    const Io = std.Io;
    const Allocator = std.mem.Allocator;

    const NativeJob = struct {
        gpa: Allocator,
        io: Io,
        vera_exe: []const u8,
        flags: []const []const u8,
        snapshot: bool,
        cases: []const []const u8,
        slots: []NativeSlot,
        next: std.atomic.Value(usize) = .init(0),

        fn work(job: *NativeJob) void {
            var arena_state: std.heap.ArenaAllocator = .init(job.gpa);
            defer arena_state.deinit();
            while (true) {
                const i = job.next.fetchAdd(1, .monotonic);
                if (i >= job.cases.len) return;
                _ = arena_state.reset(.retain_capacity);
                var aw: Io.Writer.Allocating = .init(job.gpa);
                const v = nativeVerdict(arena_state.allocator(), job.io, job.vera_exe, job.flags, job.snapshot, job.cases[i], &aw.writer) catch |e| blk: {
                    aw.writer.print("FAIL {s}: the runner itself failed: {t}\n", .{ job.cases[i], e }) catch {};
                    break :blk NativeVerdict{ .pass = false, .fallback = null };
                };
                var list = aw.toArrayList();
                // The reason is in the arena the next case resets.
                var kept = v;
                if (v.fallback) |why| kept.fallback = job.gpa.dupe(u8, why) catch "?";
                job.slots[i] = .{ .verdict = kept, .output = list.toOwnedSlice(job.gpa) catch "" };
            }
        }
    };

    /// `fallback` is the executable's reason for embedding the interpreter;
    /// `refused` is a case the shared elaboration rejected, so no executable
    /// was built at all; `xfail` is an unmet `//! xfail` case, which does not
    /// fail the run.
    /// `state` is what a `--state=auto` executable ran (`rt.auto`'s
    /// `--vera-state` line): 4-state throughout, 2-state after a 4-state
    /// start, or that and then a 4-state rerun.
    const NativeVerdict = struct { pass: bool, fallback: ?[]const u8, refused: bool = false, xfail: bool = false, state: RunState = .four };
    const RunState = enum { four, two, rerun };

    /// `nativeCase` under `//! xfail` or an xfail list row, with `digitalVerdict`'s algebra.
    fn nativeVerdict(arena: Allocator, io: Io, vera_exe: []const u8, flags: []const []const u8, snapshot: bool, case: []const u8, w: *Io.Writer) !NativeVerdict {
        const xfail = try devices.xfailOf(arena, io, case) orelse
            return nativeCase(arena, io, vera_exe, flags, snapshot, case, w);
        if (xfail.len == 0) {
            try w.print("FAIL {s}: `//! xfail` names no reason\n", .{case});
            return .{ .pass = false, .fallback = null };
        }
        var detail: Io.Writer.Allocating = .init(arena);
        var v = try nativeCase(arena, io, vera_exe, flags, snapshot, case, &detail.writer);
        if (v.pass) {
            try w.print("FAIL {s}: XPASS — marked xfail, but VerA now does what the fixture says.\n" ++
                "  Delete its `//! xfail` line or its row in {s}.\n", .{ case, harness.xfail_list });
            v.pass = false;
            return v;
        }
        try w.print("XFAIL {s}: known: {s}\n", .{ case, xfail });
        v.xfail = true;
        return v;
    }
    const NativeSlot = struct { verdict: NativeVerdict = .{ .pass = false, .fallback = null }, output: []const u8 = "" };

    /// `--native`: every case in `all` matching `filter`, judged on `harness.defaultJobs()`
    /// workers, then the NATIVE, FALLBACK, AUTO2 and RERUN name lists and a census on `w`,
    /// in case order. Exit 1 on any FAIL or when nothing matched.
    pub fn run(gpa: Allocator, io: Io, exe: []const u8, flags: []const []const u8, snapshot: bool, all: []const []const u8, filter: ?[]const u8, w: *Io.Writer) !u8 {
        var picked: std.ArrayList([]const u8) = .empty;
        defer picked.deinit(gpa);
        for (all) |c| if (filter == null or std.mem.find(u8, c, filter.?) != null) try picked.append(gpa, c);
        if (picked.items.len == 0) {
            try w.print("devices: nothing matched `{s}`\n", .{filter orelse ""});
            return 1;
        }
        const slots = try gpa.alloc(NativeSlot, picked.items.len);
        defer gpa.free(slots);
        @memset(slots, .{});
        var job: NativeJob = .{ .gpa = gpa, .io = io, .vera_exe = exe, .flags = flags, .snapshot = snapshot, .cases = picked.items, .slots = slots };
        var group: Io.Group = .init;
        const jobs = harness.defaultJobs();
        var hands: usize = 0;
        while (hands < jobs) : (hands += 1) group.concurrent(io, NativeJob.work, .{&job}) catch break;
        if (hands == 0) job.work();
        try group.await(io);

        var failed: usize = 0;
        var xfailed: usize = 0;
        var fell: usize = 0;
        var refused: usize = 0;
        var twos: usize = 0;
        var reruns: usize = 0;
        for (picked.items, slots) |case, s| {
            try w.writeAll(s.output);
            switch (s.verdict.state) {
                .four => {},
                .two => twos += 1,
                .rerun => reruns += 1,
            }
            if (s.verdict.state != .four) try w.print("AUTO2 {s}\n", .{case});
            if (s.verdict.state == .rerun) try w.print("RERUN {s}\n", .{case});
            if (s.verdict.xfail) {
                xfailed += 1;
            } else if (!s.verdict.pass) failed += 1;
            if (s.verdict.refused) {
                refused += 1;
            } else if (s.verdict.fallback) |why| {
                fell += 1;
                try w.print("FALLBACK {s}: {s}\n", .{ case, why });
            } else if (s.verdict.pass) try w.print("NATIVE {s}\n", .{case});
        }
        try w.print(
            "devices --native: {d}/{d} cases behave as they say they do; {d} native, " ++
                "{d} through the embedded interpreter, {d} refused before any executable",
            .{ picked.items.len - failed - xfailed, picked.items.len, picked.items.len - fell - refused, fell, refused },
        );
        if (xfailed != 0) try w.print("; {d} XFAIL (a known gap, not a pass)", .{xfailed});
        try w.print("; --state=auto turned 2-state in {d} (AUTO2), of which {d} reran 4-state (RERUN)\n", .{ twos + reruns, reruns });
        for (slots) |s| {
            gpa.free(s.output);
            if (s.verdict.fallback) |why| gpa.free(why);
        }
        return if (failed == 0) 0 else 1;
    }

    /// `digitalCase` through the executable. A rejection may come from `vera
    /// --emit-exe` (the shared elaboration) or from the executable at run time;
    /// either way its stderr is judged, the build's and the run's together.
    fn nativeCase(arena: Allocator, io: Io, vera_exe: []const u8, flags: []const []const u8, snapshot: bool, case: []const u8, w: *Io.Writer) !NativeVerdict {
        const src = try arena.print("{s}/{s}.v", .{ options.fixture_root, case });
        const source = try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(1 << 20));
        const work = try arena.print("native/{s}", .{case});
        try Io.Dir.cwd().createDirPath(io, work);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ vera_exe, "--emit-exe", "--work-dir", work });
        try argv.appendSlice(arena, flags);
        try argv.append(arena, src);
        try argv.appendSlice(arena, try digital.runnerArgs(arena, source, std.fs.path.dirname(src).?));
        const built = try child.capture(arena, io, argv.items);
        const two_state = std.mem.eql(u8, flags[0], "--two-state");
        const fallback: ?[]const u8 = if (std.mem.find(u8, built.stderr, "not native (")) |at| blk: {
            const rest = built.stderr[at + "not native (".len ..];
            break :blk rest[0 .. std.mem.find(u8, rest, ")\n") orelse rest.len];
        } else null;
        const negative = digital.negative(source);
        if (two_state and built.exit != 0) if (std.mem.find(u8, built.stderr, "carries meaning: ")) |at| {
            const rest = built.stderr[at + "carries meaning: ".len ..];
            return .{ .pass = true, .fallback = rest[0 .. std.mem.findScalar(u8, rest, '\n') orelse rest.len] };
        };
        if (built.exit != 0) {
            if (negative and digital.rejectionMatches(source, built.exit, built.stderr)) return .{ .pass = true, .fallback = null, .refused = true };
            try w.print("FAIL {s}: vera --emit-exe exited {d}\n{s}\n", .{ case, built.exit, built.stderr });
            return .{ .pass = false, .fallback = fallback };
        }
        if (!two_state and nativeRequired(source)) if (fallback) |why| {
            try w.print("FAIL {s}: `// native-required` forbids interpreter fallback: {s}\n", .{ case, why });
            return .{ .pass = false, .fallback = fallback };
        };
        const bin = try Io.Dir.cwd().realPathFileAlloc(io, std.mem.trimEnd(u8, built.stdout, "\n"), arena);
        var ran = try child.captureIn(arena, io, if (snapshot) &.{ bin, "--vera-state", "--vera-snapshot" } else &.{ bin, "--vera-state" }, work);
        if (std.mem.find(u8, ran.stderr, "vera-snapshot: ")) |at| {
            const end = std.mem.findScalarPos(u8, ran.stderr, at, '\n') orelse ran.stderr.len;
            ran.stderr = try std.mem.concat(arena, u8, &.{ ran.stderr[0..at], ran.stderr[@min(end + 1, ran.stderr.len)..] });
        }
        var state: RunState = .four;
        if (std.mem.find(u8, ran.stderr, "vera-state: ")) |at| {
            const end = std.mem.findScalarPos(u8, ran.stderr, at, '\n') orelse ran.stderr.len;
            const line = ran.stderr[at..end];
            state = if (std.mem.find(u8, line, "rerun") != null) .rerun else if (std.mem.find(u8, line, "2-state") != null) .two else .four;
            ran.stderr = try std.mem.concat(arena, u8, &.{ ran.stderr[0..at], ran.stderr[@min(end + 1, ran.stderr.len)..] });
        }
        // `// native-state: 2|4|rerun` pins what the default `--state=auto` runs.
        if (flags.len == 1 and !two_state) if (pinnedState(source)) |want| if (want != state) {
            try w.print("FAIL {s}: `--state=auto` ran {t}, the fixture pins {t}\n", .{ case, state, want });
            return .{ .pass = false, .fallback = fallback, .state = state };
        };
        const stderr = try std.mem.concat(arena, u8, &.{ built.stderr, ran.stderr });
        if (negative) {
            if (digital.rejectionMatches(source, ran.exit, stderr)) {
                // A rejection with a transcript (`devices.digitalCase`): the run
                // went on after the error, and printed this.
                const golden = try arena.print("{s}/{s}.expected.txt", .{ options.fixture_root, case });
                const want = Io.Dir.cwd().readFileAlloc(io, golden, arena, .limited(1 << 20)) catch
                    return .{ .pass = true, .fallback = fallback, .state = state };
                const same = if (two_state) try twoStateDiff(w, case, want, ran.stdout) else try devices.diff(w, case, want, ran.stdout);
                return .{ .pass = same, .fallback = fallback, .state = state };
            }
            try w.print("FAIL {s}: digital rejection mismatch (exit {d})\n{s}\n", .{ case, ran.exit, stderr });
            return .{ .pass = false, .fallback = fallback, .state = state };
        }
        if (ran.exit != 0) {
            try w.print("FAIL {s}: the executable exited {d}\n{s}\n", .{ case, ran.exit, stderr });
            return .{ .pass = false, .fallback = fallback, .state = state };
        }
        if (!digital.warningsMatch(source, stderr)) {
            try w.print("FAIL {s}: successful digital run has missing warning evidence or error diagnostics\n{s}\n", .{ case, stderr });
            return .{ .pass = false, .fallback = fallback, .state = state };
        }
        if (digital.vcdExpectation(source)) |v| return .{ .pass = try vcdDiff(arena, io, w, case, work, v, two_state), .fallback = fallback, .state = state };
        const want = try Io.Dir.cwd().readFileAlloc(io, try arena.print("{s}/{s}.expected.txt", .{ options.fixture_root, case }), arena, .limited(1 << 20));
        if (two_state) return .{ .pass = try twoStateDiff(w, case, want, ran.stdout), .fallback = fallback, .state = state };
        return .{ .pass = try devices.diff(w, case, want, ran.stdout), .fallback = fallback, .state = state };
    }

    /// A compiled-runtime regression may require native emission as well as its
    /// transcript. This promise applies to normal native modes, not the separate
    /// `--two-state` report which deliberately changes x/z semantics.
    fn nativeRequired(source: []const u8) bool {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), "// native-required")) return true;
        return false;
    }

    /// A fixture's `// native-state:` line, if it has one.
    fn pinnedState(source: []const u8) ?RunState {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \t\r");
            const word = if (std.mem.startsWith(u8, line, "// native-state: ")) line["// native-state: ".len..] else continue;
            if (std.mem.eql(u8, word, "2")) return .two;
            if (std.mem.eql(u8, word, "4")) return .four;
            if (std.mem.eql(u8, word, "rerun")) return .rerun;
        }
        return null;
    }

    /// A `//! expect vcd` case: the file the executable wrote in `work` against
    /// the golden beside the fixture, both normalised (`digital.vcdTokens`).
    /// Under `--two-state` a token may differ where the golden's shows an x or z
    /// digit, `twoStateDiff`'s rule.
    fn vcdDiff(arena: Allocator, io: Io, w: *Io.Writer, case: []const u8, work: []const u8, v: digital.VcdExpect, two_state: bool) !bool {
        const got_text = Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ work, v.produced }), arena, .limited(1 << 24)) catch {
            try w.print("FAIL {s}: the executable wrote no `{s}`\n", .{ case, v.produced });
            return false;
        };
        const dir = std.fs.path.dirname(try arena.print("{s}/{s}.v", .{ options.fixture_root, case })).?;
        const want_text = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ dir, v.golden }), arena, .limited(1 << 24));
        const got = try digital.vcdTokens(arena, got_text);
        const want = try digital.vcdTokens(arena, want_text);
        for (0..@max(got.len, want.len)) |i| {
            const g = if (i < got.len) got[i] else "<end of file>";
            const e = if (i < want.len) want[i] else "<end of file>";
            if (std.mem.eql(u8, g, e)) continue;
            if (two_state and std.mem.findAny(u8, e, "xXzZ") != null) continue;
            try w.print("FAIL {s}: VCD token {d} is `{s}`, the golden has `{s}`\n", .{ case, i, g, e });
            return false;
        }
        return true;
    }

    /// `--native=two-state`'s judgement: every line of `got` that differs from
    /// `want` (line by line) differs where `want` shows an x or z digit.
    fn twoStateDiff(w: *Io.Writer, case: []const u8, want: []const u8, got: []const u8) !bool {
        var wl = std.mem.splitScalar(u8, want, '\n');
        var gl = std.mem.splitScalar(u8, got, '\n');
        var differ: u32 = 0;
        var line: u32 = 1;
        while (true) : (line += 1) {
            const a = wl.next();
            const b = gl.next();
            if (a == null and b == null) break;
            if (a != null and b != null and std.mem.eql(u8, a.?, b.?)) continue;
            differ += 1;
            if (a != null and hasXz(a.?)) continue;
            try w.print("FAIL {s}: line {d} differs with no x or z in the golden\n  want: {s}\n  got:  {s}\n", .{ case, line, a orelse "(none)", b orelse "(none)" });
            return false;
        }
        if (differ != 0) try w.print("XZ {s}: {d} line(s) differ, each where the golden shows x or z\n", .{ case, differ });
        return true;
    }

    /// A value token of `line` holds an x or z digit: a run of hex digits,
    /// `_`, x and z with at least one x or z (§17.1.1.3).
    fn hasXz(line: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, line, " \t=:,;()[]{}'\"/");
        while (it.next()) |t| {
            var xz = false;
            for (t) |c| switch (c) {
                'x', 'X', 'z', 'Z' => xz = true,
                '0'...'9', 'a'...'f', 'A'...'F', '_' => {},
                else => break,
            } else if (xz) return true;
        }
        return false;
    }
};

const SpiceDecks = struct {
    //! The `spice` mode: each `.sp` deck (a SPICE netlist with `.hdl "model.va"`
    //! cards and an `.expected.json` analytic oracle) -> PASS or FAIL. First the
    //! half every deck needs: the oracle exists, every `.hdl` model resolves
    //! (`resolveModel`) and compiles under `vera --check`. Then `execute` runs
    //! the deck on the ESPice CLI, a full SPICE simulator, with `--format=csv`,
    //! and `grade` holds the CSV to the oracle's own values and tolerances.
    //! espice runs every deck or the deck FAILs: nothing is skipped.
    //!
    //! After the mode word: `--espice=PATH` names the executable (required),
    //! `--results=PATH` writes the per-deck ledger, a bare word filters the
    //! decks, and any other `--` argument is espice's own, forwarded untouched
    //! (`--backend=cuda`, `--jobs=4`): CPU or GPU is never VerA's decision.
    //!
    //!   zig build test-spice --fork .                         # ESPice from build.zig.zon, over this tree's vera
    //!   zig build test-spice -Despice=PATH                    # an espice built elsewhere
    //!   zig build test-spice --fork . -- timer                # the decks whose name contains timer
    //!   zig build test-spice -Despice=PATH -- --backend=cuda  # forwarded to espice

    const std = @import("std");
    const options = @import("suite_options");
    const harness = Fixtures;
    const child = Child;

    const Io = std.Io;
    const Allocator = std.mem.Allocator;
    const Args = std.process.Args.Iterator;

    /// `.hdl` paths are relative to the deck, exactly as written.
    fn resolveModel(arena: Allocator, io: Io, dir_path: []const u8, ref: []const u8) !?[]const u8 {
        const literal = try std.fs.path.join(arena, &.{ dir_path, ref });
        if (Io.Dir.cwd().access(io, literal, .{})) |_| return literal else |_| {}
        return null;
    }

    /// The `spice` mode: checks, then runs on espice, each `.sp` deck matching
    /// the filter in `args`, printing one PASS/FAIL line per deck and a census to
    /// stderr. Exit 1 on any FAIL or when nothing matched, 2 without `--espice=`.
    pub fn run(init: std.process.Init, vera_exe: []const u8, args: *Args) !u8 {
        const gpa = init.gpa;
        const io = init.io;

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();

        var filter: ?[]const u8 = null;
        var results_path: ?[]const u8 = null;
        var espice: ?[]const u8 = null;
        var espice_args: std.ArrayList([]const u8) = .empty;
        while (args.next()) |a| {
            if (std.mem.cutPrefix(u8, a, "--results=")) |path| {
                results_path = path;
            } else if (std.mem.cutPrefix(u8, a, "--espice=")) |path| {
                espice = path;
            } else if (std.mem.startsWith(u8, a, "--")) {
                // espice's own (`--backend=cuda`, `--jobs=4`), untouched: where a
                // deck runs is espice's decision.
                try espice_args.append(arena_state.allocator(), a);
            } else {
                filter = a;
            }
        }
        const espice_name = espice orelse return harness.usage(io, "spice: --espice=PATH names the espice executable");
        // A built espice is build.zig's cwd-relative `.zig-cache/o/...` path and
        // espice runs from each deck's directory; a bare name stays PATH's.
        const espice_exe: []const u8 = if (std.mem.findScalar(u8, espice_name, std.fs.path.sep) != null)
            try Io.Dir.cwd().realPathFileAlloc(io, espice_name, arena_state.allocator())
        else
            espice_name;
        var results: Io.Writer.Allocating = .init(gpa);
        defer results.deinit();

        var buf: [4096]u8 = undefined;
        var stderr = Io.File.stderr().writer(io, &buf);
        const w = &stderr.interface;
        defer w.flush() catch {};

        // The decks: every `.sp` with an `.expected.json` beside it under the AMS
        // directories (`harness.ams_dirs`), relative to the fixture root. Never
        // the suite's `netlist/` (ESPice's own decks), nor VerA's
        // `vera/osdi/*.sp` (ngspice `.control` decks `tools/external_analog.py`
        // runs, with no `.hdl` card and no `.expected.json`).
        var decks: std.ArrayList([]const u8) = .empty;
        defer decks.deinit(gpa);
        for (harness.ams_dirs) |sub| {
            const pa = arena_state.allocator();
            var root = Io.Dir.cwd().openDir(io, try std.fs.path.join(pa, &.{ options.fixture_root, sub }), .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer root.close(io);
            var walker = try root.walk(pa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.path, ".sp")) continue;
                const oracle = try pa.print("{s}.expected.json", .{entry.path[0 .. entry.path.len - ".sp".len]});
                if (root.access(io, oracle, .{})) |_| {} else |_| continue;
                try decks.append(gpa, try std.fs.path.join(pa, &.{ sub, entry.path }));
            }
        }
        std.mem.sort([]const u8, decks.items, {}, harness.strLess);

        var ran: usize = 0;
        var failed: usize = 0;
        var passed: usize = 0;
        for (decks.items) |rel| {
            if (filter) |f| if (std.mem.find(u8, rel, f) == null) continue;
            ran += 1;
            var status: []const u8 = "fail";
            defer if (results_path != null) {
                results.writer.print("{s}\tspice.test.{s}\n", .{ status, rel }) catch @panic("OOM");
            };
            const pa = arena_state.allocator();
            const path = try std.fs.path.join(pa, &.{ options.fixture_root, rel });
            const dir_path = std.fs.path.dirname(path) orelse ".";
            const name = std.fs.path.basename(rel);
            var bad = false;

            // 1. The oracle, which the walk saw beside the deck.
            const stem = path[0 .. path.len - ".sp".len];
            const oracle_path = try pa.print("{s}.expected.json", .{stem});
            const oracle = Io.Dir.cwd().readFileAlloc(io, oracle_path, pa, .limited(1 << 20)) catch blk: {
                try w.print("FAIL {s}: no .expected.json beside it\n", .{name});
                bad = true;
                break :blk "";
            };

            // 2. Every model the deck names, one `.hdl "<path>"` per line.
            const source = try Io.Dir.cwd().readFileAlloc(io, path, pa, .limited(1 << 20));
            var lines = std.mem.splitScalar(u8, source, '\n');
            var models: usize = 0;
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (!std.mem.startsWith(u8, line, ".hdl")) continue;
                const open = std.mem.findScalar(u8, line, '"') orelse continue;
                const rest = line[open + 1 ..];
                const close = std.mem.findScalar(u8, rest, '"') orelse continue;
                const ref = rest[0..close];

                const model = (try resolveModel(pa, io, dir_path, ref)) orelse {
                    try w.print("FAIL {s}: .hdl \"{s}\" resolves to no file\n", .{ name, ref });
                    bad = true;
                    continue;
                };
                models += 1;
                // 3. VerA's own half: the model has to compile. `--check` and both
                //    include dirs: `check.vh` is in the suite's `include/` and the
                //    model's siblings are beside it.
                const r = child.capture(pa, io, &.{
                    vera_exe, "--check",           "--contract", options.contract,
                    "-I",     harness.include_dir, "-I",         dir_path,
                    model,
                }) catch |e| {
                    try w.print("FAIL {s}: could not run vera: {s}\n", .{ name, @errorName(e) });
                    bad = true;
                    continue;
                };
                if (r.exit != 0) {
                    try w.print("FAIL {s}: model {s} does not compile\n{s}", .{
                        name, std.fs.path.basename(model), r.stderr,
                    });
                    bad = true;
                }
            }
            if (models == 0 and !bad) {
                try w.print("FAIL {s}: no .hdl card, so the deck names no model\n", .{name});
                bad = true;
            }
            if (bad) {
                failed += 1;
                continue;
            }

            // 4. Run it on espice and hold its CSV to the oracle.
            const verdict = try execute(pa, io, espice_exe, espice_args.items, std.fs.path.basename(stem), path, dir_path, analysisOf(source), oracle);
            switch (verdict) {
                .pass => |what| {
                    try w.print("PASS {s}: {s}\n", .{ name, what });
                    passed += 1;
                    status = "pass";
                },
                .fail => |why| {
                    try w.print("FAIL {s}: {s}\n", .{ name, why });
                    failed += 1;
                },
            }
        }
        if (results_path) |path| {
            if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = results.written() });
        }

        if (ran == 0) {
            try w.print("spice: nothing matched `{s}`\n", .{filter orelse ""});
            return 1;
        }
        try w.print("spice: {d}/{d} decks executed on espice and match their oracle; {d} FAIL\n", .{ passed, ran, failed });
        return if (failed == 0) 0 else 1;
    }

    /// The deck's analysis as the oracle's `analysis` names it: its first
    /// `.tran`, `.noise`, `.ac`, `.dc` or `.op` card without the dot. SPICE cards
    /// are case-insensitive. Null when the deck has none.
    fn analysisOf(source: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            var it = std.mem.tokenizeAny(u8, raw, " \t\r");
            const card = it.next() orelse continue;
            if (card[0] != '.') continue;
            for ([_][]const u8{ "tran", "noise", "ac", "dc", "op" }) |a| {
                if (std.ascii.eqlIgnoreCase(card[1..], a)) return a;
            }
        }
        return null;
    }

    const Verdict = union(enum) {
        /// What was checked.
        pass: []const u8,
        fail: []const u8,
    };

    /// Runs `deck` on espice, its CSV in a fresh `<work_root>/spice/<stem>/`, and
    /// grades what it wrote against `oracle_text`.
    fn execute(
        arena: Allocator,
        io: Io,
        espice: []const u8,
        espice_args: []const []const u8,
        stem: []const u8,
        deck: []const u8,
        dir_path: []const u8,
        analysis: ?[]const u8,
        oracle_text: []const u8,
    ) !Verdict {
        const work = try std.fs.path.join(arena, &.{ options.work_root, "spice", stem });
        // An earlier run's `<stem>.csv.2` would be read as this run's second plot.
        try Io.Dir.cwd().deleteTree(io, work);
        try Io.Dir.cwd().createDirPath(io, work);
        const out = try std.fs.path.join(arena, &.{ work, try arena.print("{s}.csv", .{stem}) });
        // `-I`: the models `include "check.vh"` from the suite's `include/`, as
        // the `vera --check` half is told; espice searches a model's own
        // directory and each `-I` for its `.hdl` includes.
        const argv = try std.mem.concat(arena, []const u8, &.{ &.{ espice, "--format=csv", "-r", out, "-I", harness.include_dir }, espice_args, &.{deck} });
        // From the deck's directory, as `.hdl` paths are written relative to it;
        // `deck` and `out` are absolute.
        const r = child.captureIn(arena, io, argv, dir_path) catch |e|
            return .{ .fail = try arena.print("could not run {s}: {s}", .{ espice, @errorName(e) }) };
        if (r.exit != 0) return .{ .fail = try arena.print("espice exited {d}:\n{s}", .{ r.exit, r.stderr }) };
        return grade(arena, io, analysis, out, oracle_text);
    }

    /// One plot of espice's CSV: `names[i]` heads `cols[i]`, and column 0 is the
    /// axis (`time`, `frequency`).
    const Table = struct {
        names: []const []const u8,
        cols: []const []const f64,
    };

    /// Reads `text` as espice's `--format=csv` writes it: a header of names, then
    /// one row of numbers per point. A name holding `,` or `"` is quoted with its
    /// `"` doubled (RFC 4180). A row whose field count is not the header's, or a
    /// field that is not a number, is `error.BadCsv`.
    fn parseCsv(arena: Allocator, text: []const u8) !Table {
        var lines = std.mem.splitScalar(u8, text, '\n');
        const header = std.mem.trimEnd(u8, lines.first(), "\r");
        var names: std.ArrayList([]const u8) = .empty;
        var name: std.ArrayList(u8) = .empty;
        var quoted = false;
        var i: usize = 0;
        while (i < header.len) : (i += 1) {
            const c = header[i];
            if (quoted) {
                if (c != '"') {
                    try name.append(arena, c);
                } else if (i + 1 < header.len and header[i + 1] == '"') {
                    try name.append(arena, '"');
                    i += 1;
                } else quoted = false;
            } else if (c == '"') {
                quoted = true;
            } else if (c == ',') {
                try names.append(arena, name.items);
                name = .empty;
            } else try name.append(arena, c);
        }
        if (quoted) return error.BadCsv;
        try names.append(arena, name.items);

        const cols = try arena.alloc(std.ArrayList(f64), names.items.len);
        @memset(cols, .empty);
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, ',');
            for (cols) |*col| {
                const f = fields.next() orelse return error.BadCsv;
                try col.append(arena, std.fmt.parseFloat(f64, f) catch return error.BadCsv);
            }
            if (fields.next() != null) return error.BadCsv;
        }
        const flat = try arena.alloc([]const f64, cols.len);
        for (cols, flat) |c, *f| f.* = c.items;
        return .{ .names = names.items, .cols = flat };
    }

    /// The column `name` of `tables`, ignoring case as SPICE does, and the axis
    /// of the table holding it. A run may also write an operating point (one row
    /// of the same `v(...)` names) or several plots, so the tables on the
    /// analysis's own axis (`time` for tran, `frequency` for noise and ac) are
    /// searched first, then every table in file order.
    fn column(tables: []const Table, analysis: []const u8, name: []const u8) ?struct { axis: []const f64, col: []const f64 } {
        const own: ?[]const u8 = if (std.mem.eql(u8, analysis, "tran"))
            "time"
        else if (std.mem.eql(u8, analysis, "noise") or std.mem.eql(u8, analysis, "ac"))
            "frequency"
        else
            null;
        if (own) |axis| for (tables) |t| if (std.ascii.eqlIgnoreCase(t.names[0], axis)) {
            for (t.names, t.cols) |n, c| if (std.ascii.eqlIgnoreCase(n, name)) return .{ .axis = t.cols[0], .col = c };
        };
        for (tables) |t| for (t.names, t.cols) |n, c| if (std.ascii.eqlIgnoreCase(n, name)) return .{ .axis = t.cols[0], .col = c };
        return null;
    }

    fn num(v: std.json.Value) ?f64 {
        return switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
        if (v != .object) return null;
        return v.object.get(key);
    }

    fn fieldNum(v: std.json.Value, key: []const u8, default: f64) f64 {
        return num(field(v, key) orelse return default) orelse default;
    }

    fn numbers(arena: Allocator, v: ?std.json.Value) ![]const f64 {
        const arr = (v orelse return error.BadOracle);
        if (arr != .array) return error.BadOracle;
        const out = try arena.alloc(f64, arr.array.items.len);
        for (arr.array.items, out) |e, *o| o.* = num(e) orelse return error.BadOracle;
        return out;
    }

    /// `|got - want| <= atol + rtol*|want|`, the oracle's tolerance.
    fn within(got: f64, want: f64, rtol: f64, atol: f64) bool {
        return @abs(got - want) <= atol + rtol * @abs(want);
    }

    /// Linear interpolation of `col` over `axis` at `a`, inside the run only.
    fn sampleAt(axis: []const f64, col: []const f64, a: f64) ?f64 {
        if (axis.len == 0 or a < axis[0] or a > axis[axis.len - 1]) return null;
        for (axis[1..], 1..) |hi, i| if (a <= hi) {
            const lo = axis[i - 1];
            if (hi == lo) return col[i];
            return col[i - 1] + (col[i] - col[i - 1]) * (a - lo) / (hi - lo);
        };
        return col[col.len - 1];
    }

    /// Holds espice's CSV at `out` to the oracle. CSV holds one plot per file, so
    /// a run's second plot is `out.2`, its third `out.3`, and a graded column is
    /// found by name across them (`column`). Reads `analysis`,
    /// `expect.status`, `expect.plots` (`match` `exact`: that column's table has
    /// the same rows, or `samples`: each column interpolated at the axis values),
    /// `expect.checks` (`selected_values`: a row at exactly each coordinate) and
    /// `finite_values_required`. Anything else in `expect` it does not know is a
    /// FAIL, never a skip.
    fn grade(arena: Allocator, io: Io, analysis: ?[]const u8, out: []const u8, oracle_text: []const u8) !Verdict {
        const oracle = std.json.parseFromSliceLeaky(std.json.Value, arena, oracle_text, .{}) catch
            return .{ .fail = "the oracle is not JSON" };
        const runs = analysis orelse return .{ .fail = "the deck has no .tran, .noise, .ac, .dc or .op card" };
        const want_analysis = field(oracle, "analysis") orelse return .{ .fail = "the oracle names no analysis" };
        if (want_analysis != .string or !std.mem.eql(u8, want_analysis.string, runs))
            return .{ .fail = try arena.print("the oracle is a {s} analysis and the deck runs {s}", .{ if (want_analysis == .string) want_analysis.string else "?", runs }) };
        const expect = field(oracle, "expect") orelse return .{ .fail = "the oracle has no expect" };
        var it = expect.object.iterator();
        while (it.next()) |e| {
            const known = [_][]const u8{ "status", "plots", "checks", "finite_values_required", "all_requested_analyses_must_complete" };
            for (known) |k| {
                if (std.mem.eql(u8, k, e.key_ptr.*)) break;
            } else return .{ .fail = try arena.print("the oracle's expect.{s} is not graded by this harness", .{e.key_ptr.*}) };
        }
        if (field(expect, "status")) |s| if (s != .string or !std.mem.eql(u8, s.string, "success"))
            return .{ .fail = "the oracle expects a status other than success" };

        var tables: std.ArrayList(Table) = .empty;
        var read: std.ArrayList(u8) = .empty; // the files, for the FAIL line
        var path = out;
        while (true) {
            const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| switch (e) {
                error.FileNotFound => break,
                else => return .{ .fail = try arena.print("cannot read {s}: {s}", .{ path, @errorName(e) }) },
            };
            const table = parseCsv(arena, text) catch
                return .{ .fail = try arena.print("espice wrote a malformed line in {s}", .{path}) };
            try tables.append(arena, table);
            try read.print(arena, " {s}", .{path});
            path = try arena.print("{s}.{d}", .{ out, tables.items.len + 1 });
        }
        var rows: usize = 0;
        for (tables.items) |t| rows += t.cols[0].len;
        if (rows == 0) return .{ .fail = try arena.print("espice wrote no {s} plot; files read:{s}", .{ runs, if (read.items.len == 0) " none" else read.items }) };
        if (field(expect, "finite_values_required")) |f| if (f == .bool and f.bool) {
            for (tables.items) |t| for (t.cols) |c| for (c) |v| if (!std.math.isFinite(v)) return .{ .fail = "a value is not finite" };
        };

        var checked: usize = 0;
        if (field(expect, "plots")) |plots| for (plots.array.items) |p| {
            const match = (field(p, "match") orelse return .{ .fail = "a plot without match" }).string;
            const ax = field(p, "axis") orelse return .{ .fail = "a plot without axis" };
            const want_axis = try numbers(arena, field(ax, "values"));
            const exact = std.mem.eql(u8, match, "exact");
            if (!exact and !std.mem.eql(u8, match, "samples")) return .{ .fail = try arena.print("plot match `{s}` is not graded", .{match}) };
            const columns = field(p, "columns") orelse return .{ .fail = "a plot without columns" };
            var ci = columns.object.iterator();
            while (ci.next()) |c| {
                const t = column(tables.items, runs, c.key_ptr.*) orelse return .{ .fail = try arena.print("espice wrote no column `{s}`", .{c.key_ptr.*}) };
                if (exact) {
                    const rc = fieldNum(p, "row_count", @floatFromInt(want_axis.len));
                    if (t.axis.len != want_axis.len or rc != @as(f64, @floatFromInt(t.axis.len)))
                        return .{ .fail = try arena.print("{d} rows, the oracle wants {d}", .{ t.axis.len, want_axis.len }) };
                    for (t.axis, want_axis) |g, wv| if (!within(g, wv, fieldNum(ax, "rtol", 0), fieldNum(ax, "atol", 0)))
                        return .{ .fail = try arena.print("axis value {e}, the oracle wants {e}", .{ g, wv }) };
                }
                const want = try numbers(arena, field(c.value_ptr.*, "values"));
                if (want.len != want_axis.len) return .{ .fail = "an oracle column's length differs from its axis" };
                const rtol = fieldNum(c.value_ptr.*, "rtol", 0);
                const atol = fieldNum(c.value_ptr.*, "atol", 0);
                for (want_axis, want, 0..) |a, wv, i| {
                    const g = if (exact) t.col[i] else sampleAt(t.axis, t.col, a) orelse
                        return .{ .fail = try arena.print("{s} at {e} is outside the run", .{ c.key_ptr.*, a }) };
                    if (!within(g, wv, rtol, atol))
                        return .{ .fail = try arena.print("{s} at {e} = {e}, the oracle wants {e} (rtol {e}, atol {e})", .{ c.key_ptr.*, a, g, wv, rtol, atol }) };
                    checked += 1;
                }
            }
        };
        if (field(expect, "checks")) |checks| for (checks.array.items) |ck| {
            const kind = (field(ck, "kind") orelse return .{ .fail = "a check without kind" }).string;
            if (!std.mem.eql(u8, kind, "selected_values")) return .{ .fail = try arena.print("check kind `{s}` is not graded", .{kind}) };
            // ponytail: `period` folds a coordinate into one period of a periodic
            // run. Every deck's period exceeds its run, so it is not applied.
            const cname = (field(ck, "column") orelse return .{ .fail = "a check without column" }).string;
            const t = column(tables.items, runs, cname) orelse return .{ .fail = try arena.print("espice wrote no column `{s}`", .{cname}) };
            const coords = try numbers(arena, field(ck, "coordinates"));
            const want = try numbers(arena, field(ck, "values"));
            if (coords.len != want.len) return .{ .fail = "a check's coordinates and values differ in length" };
            for (coords, want) |cv, wv| {
                // The coordinate itself must be an accepted point: interpolation
                // across it would hide a missing timepoint.
                const i = std.mem.findScalar(f64, t.axis, cv) orelse
                    return .{ .fail = try arena.print("MissingCoordinate: no accepted point at {e}", .{cv}) };
                if (!within(t.col[i], wv, fieldNum(ck, "rtol", 0), fieldNum(ck, "atol", 0)))
                    return .{ .fail = try arena.print("{s} at {e} = {e}, the oracle wants {e}", .{ cname, cv, t.col[i], wv }) };
                checked += 1;
            }
        };
        if (checked == 0) return .{ .fail = "the oracle states no value, so nothing was graded" };
        return .{ .pass = try arena.print("{s}, {d} values within the oracle over {d} rows", .{ runs, checked, rows }) };
    }

    test "parseCsv reads espice's CSV, and column prefers the analysis's own axis" {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // f64, as espice prints them: a `comptime_float` prints at f128 precision.
        const third: f64 = 1.0 / 3.0;
        const t = try parseCsv(a, try a.print("time,\"v(a,\"\"b\"\")\"\n0e0,{e}\n{e},-inf\n", .{ third, @as(f64, 1e-4) }));
        try std.testing.expectEqualStrings("time", t.names[0]);
        try std.testing.expectEqualStrings("v(a,\"b\")", t.names[1]);
        try std.testing.expectEqualSlices(f64, &.{ 0, 1e-4 }, t.cols[0]);
        try std.testing.expectEqualSlices(f64, &.{ third, -std.math.inf(f64) }, t.cols[1]);
        try std.testing.expectError(error.BadCsv, parseCsv(a, "time,v(out)\n0e0,1e0\n1e-4\n"));

        // An operating point written first holds `v(out)` too: the time-axis
        // table's wins, and `v(in)`, on no time axis, falls back to the first.
        const tables = [_]Table{
            try parseCsv(a, "v(in),v(out)\n1e0,5e-1\n"),
            try parseCsv(a, "Time,v(out)\n0e0,5e-1\n1e-3,7.5e-1\n"),
        };
        try std.testing.expectEqualSlices(f64, &.{ 5e-1, 7.5e-1 }, column(&tables, "tran", "V(OUT)").?.col);
        try std.testing.expectEqualSlices(f64, &.{1e0}, column(&tables, "tran", "v(in)").?.col);
    }

    test "analysisOf names the deck's first analysis card, past comments and .hdl" {
        try std.testing.expectEqualStrings("noise", analysisOf("* a .tran in a comment\n.hdl \"m.va\"\n.NOISE v(out) v1 dec 1 1 10\n.tran 1 2\n").?);
        try std.testing.expect(analysisOf("R1 a 0 1k\n.options reltol=1e-4\n.end\n") == null);
    }
};

const SizeSweep = struct {
    //! `zig build suite -- --sweep`: generated Verilog-A of growing size ->
    //! a MIR footprint table and a per-phase timing table on stdout. Each axis of
    //! `gen` is swept over `sweep` with the others at 1, so the slope is the
    //! point: an O(n^2) scan and a flat one can cost the same at n = 8.
    //!
    //! The half that can fail is `expected`, kept below: the device
    //! and MIR sizes of every generated shape, asserted under `zig build test`
    //! (two agents moving these sizes regenerate the table, they do not pick
    //! a side).

    const std = @import("std");
    const vera = @import("vera");
    const options = @import("suite_options");

    const Io = std.Io;
    const Allocator = std.mem.Allocator;

    /// `root.zig` does not export `Mir`; the type is reached through the result
    /// that carries it, the seam an embedder already has.
    const Mir = @typeInfo(@FieldType(vera.CompileResult, "mir")).pointer.child;

    /// N for the sweep and for the spawn floor; the estimator is the min over it.
    /// Noise on a shared machine only ever adds time, so the min is the closest
    /// sample to the code's cost, where a mean measures the machine's load.
    const reps = 25;

    /// The mode the engine was compiled in, printed on every row because only a
    /// ReleaseFast time is the shipping number (Debug is several times slower).
    /// `builtin.mode` is this module's `-O`, which `build.zig` keeps equal to the
    /// `vera` module's.
    pub const mode = @tagName(@import("builtin").mode);

    /// Nanoseconds since `t0` on the monotonic (`.awake`) clock.
    pub fn elapsed(io: Io, t0: Io.Timestamp) u64 {
        const ns = t0.durationTo(.now(io, .awake)).nanoseconds;
        return @intCast(@max(ns, 0));
    }

    /// The sweep. Powers of eight, so a doubling and a squaring are visibly
    /// different shapes across four steps rather than two.
    pub const sweep = [_]u32{ 1, 8, 64, 512, 4096 };

    /// The generated cases. Each pins the other two axes at 1, so a bend in one
    /// column is attributable to one axis.
    pub const Axis = enum { contrib, vals, inst };

    // ---------------------------------------------------------------------------
    // The generator
    // ---------------------------------------------------------------------------

    /// Emit a .va with `n_contrib` contributions, `n_vals` chained reals and
    /// `n_inst` instances. Everything is LIVE: the value chain terminates in the
    /// contributions and the contributions terminate in the top module's ports, so
    /// nothing here measures the speed at which VerA deletes dead code.
    fn gen(w: *Io.Writer, n_contrib: u32, n_vals: u32, n_inst: u32) Io.Writer.Error!void {
        try w.writeAll(
            \\module bench_leaf(a, b);
            \\  inout a, b;
            \\  electrical a, b;
            \\  parameter real gain = 1.0;
            \\
        );
        // A.6.3: only a named block declares, so the chain lives at module scope.
        for (0..n_vals) |i| try w.print("    real v{d};\n", .{i});
        try w.writeAll("  analog begin\n");
        try w.writeAll("    v0 = V(a, b) * gain;\n");
        for (1..n_vals) |i| try w.print("    v{d} = v{d} * 1.5 + 0.25;\n", .{ i, i - 1 });
        for (0..n_contrib) |i| try w.print(
            "    I(a, b) <+ gain * v{d} * {d}.0;\n",
            .{ n_vals - 1, i + 1 },
        );
        try w.writeAll(
            \\  end
            \\endmodule
            \\
            \\module bench_top(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\
        );
        for (0..n_inst) |i| try w.print("  bench_leaf i{d}(p, n);\n", .{i});
        try w.writeAll("endmodule\n");
    }

    fn genSource(gpa: Allocator, axis: Axis, n: u32) ![]const u8 {
        var aw: Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try gen(
            &aw.writer,
            if (axis == .contrib) n else 1,
            if (axis == .vals) n else 1,
            if (axis == .inst) n else 1,
        );
        return aw.toOwnedSlice();
    }

    // ---------------------------------------------------------------------------
    // The assertions — the half of this file that can fail
    // ---------------------------------------------------------------------------

    /// `device.text.len`, `mir.defs.len` and `mir.insts.len` for every generated
    /// shape, in `sweep` order, measured by this sweep. Pure functions of the
    /// source, so the same on every machine and optimize mode: a change here is a
    /// change in what VerA emits, and the commit that moves it explains it.
    const Shape = struct { device: usize, defs: usize, insts: usize };
    const expected = std.enums.directEnumArrayDefault(Axis, [sweep.len]Shape, null, 0, .{
        .contrib = .{
            .{ .device = 38528, .defs = 8, .insts = 5 },
            .{ .device = 38883, .defs = 35, .insts = 26 },
            .{ .device = 41626, .defs = 258, .insts = 194 },
            .{ .device = 64029, .defs = 2050, .insts = 1538 },
            .{ .device = 246609, .defs = 16386, .insts = 12290 },
        },
        .vals = .{
            .{ .device = 38528, .defs = 8, .insts = 5 },
            .{ .device = 38710, .defs = 24, .insts = 19 },
            .{ .device = 40166, .defs = 136, .insts = 131 },
            .{ .device = 51871, .defs = 1032, .insts = 1027 },
            .{ .device = 145632, .defs = 8200, .insts = 8195 },
        },
        // Parallel instances share one (p, n) row; the MIR also carries each
        // instance's share of it (`lower_contrib.unitAccum`), dead in the device.
        .inst = .{
            .{ .device = 38528, .defs = 8, .insts = 5 },
            .{ .device = 39732, .defs = 57, .insts = 47 },
            .{ .device = 49580, .defs = 449, .insts = 383 },
            .{ .device = 130114, .defs = 3585, .insts = 3071 },
            .{ .device = 787899, .defs = 28673, .insts = 24575 },
        },
    });

    /// Compile one generated shape and hold it to `expected`. Shared by the bench
    /// run (every point of the sweep) and by the unit test below (the two cheap
    /// points), so the assertion has exactly one spelling.
    fn checkShape(gpa: Allocator, axis: Axis, i: usize) !Footprint {
        const src = try genSource(gpa, axis, sweep[i]);
        defer gpa.free(src);

        var result = try vera.compileSourceOpts(gpa, src, .lint, .{});
        defer result.deinit();
        const device = try result.generateDevice();

        const want = expected[@backingInt(axis)][i];
        try std.testing.expectEqual(want.defs, result.mir.defs.len);
        try std.testing.expectEqual(want.insts, result.mir.insts.len);
        try std.testing.expectEqual(want.device, device.len);
        return .of(result.mir);
    }

    // ---------------------------------------------------------------------------
    // The MIR footprint — the other half of a size regression
    // ---------------------------------------------------------------------------

    /// What one compilation's MIR costs in bytes, by column. A `MultiArrayList` row
    /// costs the sum of its field sizes, not `@sizeOf(Row)`. The dedup maps and the
    /// interner are excluded: they are build-time scratch that `deinit` drops.
    const Footprint = struct {
        insts: u64 = 0,
        defs: u64 = 0,
        blocks: u64 = 0,
        extra: u64 = 0,

        // ponytail: ask the SoA container for its row size; this still excludes spare capacity.
        const inst_b: u64 = std.MultiArrayList(Mir.InstRow).capacityInBytes(1);
        const def_b: u64 = std.MultiArrayList(Mir.ValueRow).capacityInBytes(1) + @sizeOf(Mir.Value); // + alias slot
        const block_b: u64 = std.MultiArrayList(Mir.BlockRow).capacityInBytes(1);

        fn of(m: *const Mir) Footprint {
            return .{
                .insts = m.insts.len,
                .defs = m.defs.len,
                .blocks = m.blocks.len,
                .extra = m.extra.items.len,
            };
        }

        fn bytes(self: Footprint) u64 {
            return self.insts * inst_b + self.defs * def_b +
                self.blocks * block_b + self.extra * @sizeOf(u32);
        }
    };

    fn emitFootprint(w: *Io.Writer, case: []const u8, n: u32, f: Footprint) !void {
        try w.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            case, n, f.insts, f.defs, f.blocks, f.extra, f.bytes(),
        });
    }

    // ---------------------------------------------------------------------------
    // The phases
    // ---------------------------------------------------------------------------

    /// The sweep's phases, each a prefix of the next (there is no seam that resumes
    /// a compilation midway), so a stage's own cost is a subtraction: `lint - pp`
    /// is lex+parse+lower+prove, `codegen - lint` is codegen.
    ///   pp        `Preprocessor.process`                          text -> text
    ///   lint      `vera.compileSourceOpts(gpa, src, .lint, .{})`  text -> MIR
    ///   codegen   `result.generateDevice()`                       MIR -> device.zig
    ///   rewrite   `orchestrator.writeTree` a second time          device.zig -> 0 bytes
    const Phase = enum { pp, lint, codegen, rewrite };

    /// `bytes` is what the phase handled: preprocessed text out of `pp`, the same
    /// text in for `lint`, device text out of `codegen`, bytes written to disk for
    /// `rewrite` (asserted 0 by a test, not here).
    const Sample = struct { min_ns: u64, bytes: u64 };

    /// Run `phase` over one generated source and return the bytes it handled.
    ///
    /// `keep` receives the `CompileResult` instead of freeing it, so the clock is
    /// read before teardown. Precondition: `keep` already has capacity for `reps`,
    /// so no reallocation lands inside the timed region.
    fn runPhase(
        gpa: Allocator,
        io: Io,
        phase: Phase,
        source: []const u8,
        work_dir: []const u8,
        keep: *std.ArrayList(vera.CompileResult),
    ) !u64 {
        if (phase == .pp) {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var bag = vera.diag.Bag.init(arena.allocator());
            const text = (try vera.Preprocessor.process(arena.allocator(), source, .{ .bag = &bag })).text;
            std.mem.doNotOptimizeAway(text.len);
            return text.len;
        }

        keep.appendAssumeCapacity(try vera.compileSourceOpts(gpa, source, .lint, .{}));
        const result = &keep.items[keep.items.len - 1];

        std.mem.doNotOptimizeAway(result.mir);
        if (phase == .lint) return result.source.len;

        const device = try result.generateDevice();
        std.mem.doNotOptimizeAway(device.len);
        if (phase == .codegen) return device.len;

        // Prime the tree, then write it again: the no-op recompile. That it writes
        // 0 bytes is a `test` at the foot of the file; an assert under the clock
        // would time itself.
        _ = try rewrite(io, gpa, result.device, work_dir);
        return rewrite(io, gpa, result.device, work_dir);
    }

    /// One `orchestrator.writeTree`, returning how many bytes it actually put on
    /// disk. Shared by the timed phase and by the test that pins the second call to
    /// zero, so the claim and the measurement are the same code path.
    fn rewrite(io: Io, gpa: Allocator, device: anytype, work_dir: []const u8) !usize {
        return vera.orchestrator.writeTree(io, gpa, .{
            .work_dir = work_dir,
            .name = "bench",
            .optimize = .debug,
            .backend = .self_hosted,
            .modules = &.{},
        }, device);
    }

    fn measure(
        gpa: Allocator,
        io: Io,
        phase: Phase,
        source: []const u8,
        work_dir: []const u8,
    ) !Sample {
        var kept: std.ArrayList(vera.CompileResult) = .empty;
        defer {
            for (kept.items) |*r| r.deinit();
            kept.deinit(gpa);
        }
        try kept.ensureTotalCapacity(gpa, reps);

        var min: u64 = std.math.maxInt(u64);
        var bytes: u64 = 0;
        for (0..reps) |_| {
            const t0: Io.Timestamp = .now(io, .awake);
            bytes = try runPhase(gpa, io, phase, source, work_dir, &kept);
            min = @min(min, elapsed(io, t0));
        }
        return .{ .min_ns = min, .bytes = bytes };
    }

    fn emit(w: *Io.Writer, case: []const u8, n: u32, phase: Phase, s: Sample) !void {
        try w.print("{s}\t{s}\t{d}\t{t}\t{d}\t{d}\n", .{ mode, case, n, phase, s.min_ns, s.bytes });
    }

    /// `--sweep`: the footprint table, then the timing table, on `w`; returns exit
    /// code 0. A shape that departs from `expected` is an error, not a row.
    /// `arena` holds the generated sources until the caller frees it.
    pub fn report(gpa: Allocator, io: Io, arena: Allocator, w: *Io.Writer) !u8 {
        // The footprint table is its own pass, one compile per shape outside every
        // timer: the timing table's `bytes` is a different quantity.
        try w.writeAll("case\tn\tinsts\tdefs\tblocks\textra\tmir_bytes\n");
        for (std.enums.values(Axis)) |axis| {
            for (sweep, 0..) |n, i| try emitFootprint(w, @tagName(axis), n, try checkShape(gpa, axis, i));
        }
        try w.flush();

        try w.writeAll("\nmode\tcase\tn\tphase\tmin_ns\tbytes\n");
        if (@import("builtin").mode != .fast) try w.print(
            "# {s}: NOT the shipping number (~8x slow). Re-run with -Doptimize=ReleaseFast.\n",
            .{mode},
        );
        for (std.enums.values(Axis)) |axis| {
            for (sweep) |n| {
                const src = try genSource(arena, axis, n);
                for (std.enums.values(Phase)) |p| {
                    const s = try measure(gpa, io, p, src, options.work_root ++ "/benchmark/gen");
                    try emit(w, @tagName(axis), n, p, s);
                }
                try w.flush();
            }
        }
        return 0;
    }

    // orchestrator.zig's claim: writing a tree already on disk touches nothing.
    test "a second writeTree writes no bytes" {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        const src = try genSource(gpa, .contrib, 1);
        defer gpa.free(src);
        var result = try vera.compileSourceOpts(gpa, src, .lint, .{});
        defer result.deinit();
        _ = try result.generateDevice();

        const work = options.work_root ++ "/benchmark/rewrite-selftest";
        _ = try rewrite(io, gpa, result.device, work);
        try std.testing.expectEqual(@as(usize, 0), try rewrite(io, gpa, result.device, work));
    }

    // Every point of every axis, in `zig build test`, so a size regression in the
    // emitted device fails the gate. The n = 4096 points are also the renderer's
    // stack-depth check.
    test "generated shapes emit the expected device and MIR size" {
        for (std.enums.values(Axis)) |axis| {
            for (0..5) |i| _ = try checkShape(std.testing.allocator, axis, i);
        }
    }

    test "gen emits every axis it is asked for" {
        var aw: Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try gen(&aw.writer, 3, 2, 4);
        const text = aw.written();

        // The axes are independent: asking for 3 contributions must not also change
        // how many instances or values come out.
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, text, "I(a, b) <+"));
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "    real v"));
        try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, text, "  bench_leaf i"));
        // The chain terminates in the contribution, so nothing generated is dead.
        try std.testing.expect(std.mem.find(u8, text, "gain * v1 * 1.0;") != null);
    }
};
