const std = @import("std");
const Build = std.Build;
const Module = Build.Module;
const Import = Module.Import;
const Run = Build.Step.Run;

/// In dependency order: a module may import only rows above it.
const module_specs = [_]struct {
    name: []const u8,
    path: []const u8,
    imports: []const []const u8 = &.{},
    c: ?[]const u8 = null,
}{
    .{ .name = "contract", .path = "lib/contract.zig" },
    .{ .name = "base", .path = "lib/base/root.zig" },
    .{ .name = "kernels", .path = "lib/kernels/root.zig", .imports = &.{"contract"} },
    .{ .name = "diag", .path = "lib/diag/root.zig" },
    .{ .name = "dynlib", .path = "src/dynlib.zig" },
    .{ .name = "frontend", .path = "lib/frontend/root.zig", .imports = &.{ "base", "diag", "kernels" } },
    .{ .name = "elab", .path = "src/elab/root.zig", .imports = &.{ "base", "diag", "frontend", "kernels" } },
    .{ .name = "ir", .path = "src/ir/root.zig", .imports = &.{ "base", "diag", "kernels" } },
    .{ .name = "analog", .path = "src/analog/root.zig", .imports = &.{ "diag", "frontend", "elab", "ir", "kernels" } },
    .{ .name = "prove", .path = "src/prove/root.zig", .imports = &.{ "diag", "ir", "contract" } },
    .{ .name = "zigbuild", .path = "src/zigbuild/root.zig", .imports = &.{ "contract", "dynlib" } },
    .{ .name = "device", .path = "src/codegen/device/root.zig", .imports = &.{ "diag", "dynlib", "frontend", "ir", "analog", "prove", "kernels", "zigbuild" } },
    .{ .name = "verilog", .path = "src/codegen/verilog/root.zig", .imports = &.{ "ir", "prove" } },
    .{ .name = "exe", .path = "src/codegen/exe/root.zig", .imports = &.{ "diag", "frontend", "ir", "zigbuild" } },
    .{ .name = "vera", .path = "src/Compilation.zig", .imports = &.{ "base", "diag", "frontend", "elab", "ir", "analog", "prove", "device", "verilog", "exe", "kernels", "zigbuild" } },
    .{ .name = "sim", .path = "lib/sim/root.zig", .imports = &.{ "contract", "base", "diag", "frontend", "kernels" } },
    .{ .name = "digital", .path = "src/codegen/digital/root.zig", .imports = &.{ "sim", "frontend", "diag", "contract", "kernels", "base" } },
    .{ .name = "vpi", .path = "src/vpi/root.zig", .imports = &.{ "frontend", "ir", "vera", "sim" }, .c = "src/vpi/varargs.c" },
};

const M = struct {
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.lang.Optimize,

    fn make(m: M, root: []const u8, imports: []const Import) *Module {
        return m.b.createModule(.{ .root_source_file = m.b.path(root), .target = m.target, .optimize = m.optimize, .imports = imports });
    }
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    // Not standardOptimizeOption: it returns Optimize on 0.17 and ?Optimize on 0.18.
    const optimize = b.option(std.lang.Optimize, "optimize", "Prioritize performance, safety, or binary size") orelse .debug;
    const m: M = .{ .b = b, .target = target, .optimize = optimize };
    const results_dir = b.option([]const u8, "test-results", "Write executed unit, host and VPI test results to this directory");
    const espice_path = b.option([]const u8, "espice", "test-spice: run this espice executable instead of building ESPice from build.zig.zon (a release, a nix profile, a local `zig build` of ../ESPice, CPU or GPU)");
    // Off by default, unlike ESPice's own -Dgpu: device kernels cost build time
    // and a CPU espice runs every deck. The two arches, unset, keep ESPice's defaults.
    const espice_gpu = b.option(bool, "gpu", "ESPice's -Dgpu when test-spice builds it: compile its GPU device kernels (default false)") orelse false;
    const cuda_arch = b.option([]const u8, "cuda-arch", "ESPice's -Dcuda-arch when test-spice builds it with -Dgpu");
    const hip_arch = b.option([]const u8, "hip-arch", "ESPice's -Dhip-arch when test-spice builds it with -Dgpu");
    const mods = defineModules(b, target, true);
    const contract = byName(mods, "contract");
    const kernels = byName(mods, "kernels");
    const vera = byName(mods, "vera");
    const sim = byName(mods, "sim");
    const dynlib = byName(mods, "dynlib");

    const Language = enum { verilog, ams };
    const language = b.option(Language, "language", "verilog: an IEEE 1364-2005 `vera` without the analog backend; ams (default): the Verilog-AMS compiler") orelse .ams;
    const exe = cliExe(b, target, optimize, mods, "vera", language == .ams);
    b.installArtifact(exe);
    b.installFile("lib/contract.zig", "share/vera/contract.zig");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the vera CLI").dependOn(&run_cmd.step);

    // The VAMS Conformance Suite (`git submodule update --init --recursive
    // tests/conformance`) through its harness, `conform` from `nix develop
    // .#external`: its own tests and every external manifest, against the
    // installed vera. A known failure is a line of tools/vera.xfail.
    // `$1` is this build's vera (absolute: the harness runs tests from their
    // own directories), so the step depends on the compile, not on `install`.
    const conformance = b.addSystemCommand(&.{
        "sh", "-c",
        \\mkdir -p zig-out && VERA="$1" conform -t tests/conformance/tools/vera.conf -x tools/vera.xfail -j "${CONFORM_JOBS:-$(nproc)}" -T 300 \
        \\  -o zig-out/conformance.tsv tests/conformance/tests tests/conformance/external/*.manifest
        ,
        "sh",
    });
    conformance.addArtifactArg2(exe, .{ .make_absolute = true });
    conformance.has_side_effects = true;
    b.step("conformance", "Run the conformance suite (tests/conformance) against the installed vera").dependOn(&conformance.step);

    const test_step = b.step("test", "Run unit, host, reference and harness tests (language fixtures: test-ams and test-devices)");
    const all_step = b.step("build-all", "Compile every artifact for -Dtarget without running one");
    all_step.dependOn(&exe.step);
    const gen_exe = if (target.query.isNative()) exe else cliExe(b, b.graph.host, optimize, defineModules(b, b.graph.host, false), "vera-gen", true);
    const va_gen: Gen = .{ .exe = gen_exe, .cached = b.option(bool, "va-cache", "Regenerate a test device's Zig only when its source, its `include`s or its arguments change, not when vera does (default true; false: every vera change regenerates)") orelse true };

    const fmt = b.addFmt(.{ .paths = b.pathList(&.{ "lib", "src", "tests", "tools", "build.zig" }), .check = true });
    b.step("fmt-check", "Fail on any file `zig fmt` would change").dependOn(&fmt.step);
    test_step.dependOn(&fmt.step);

    const runner: Build.Step.Compile.TestRunner = .{ .path = b.path("tools/zrunner.zig"), .mode = .simple };
    const test_vpi = b.step("test-vpi", "Run the vpi module tests and the C VPI applications");
    for (mods) |mod| {
        const r = testRun(b, mod.name, mod.module, runner, results_dir);
        test_step.dependOn(&r.step);
        if (std.mem.eql(u8, mod.name, "vpi")) test_vpi.dependOn(&r.step) else b.step(b.fmt("test-{s}", .{mod.name}), b.fmt("Run the {s} module tests only", .{mod.name})).dependOn(&r.step);
    }
    test_step.dependOn(&exe.step);
    const cli_run = testRun(b, "cli", exe.root_module, runner, results_dir);
    // src/cli/lsp.zig's tests walk tests/fixtures; globFiles re-runs configure, so a new fixture counts.
    for (globFiles(b, "tests/fixtures", "")) |f| cli_run.addFileInput(b.path(f));
    test_step.dependOn(&cli_run.step);
    b.step("test-cli", "Run the CLI's tests (src/main.zig, src/cli/) only").dependOn(&cli_run.step);

    const osdi_mod = m.make("lib/osdi_dyn.zig", &.{.{ .name = "contract", .module = contract }});
    const osdi_run = testRun(b, "osdi_dyn", osdi_mod, runner, results_dir);
    b.step("test-osdi-dyn", "Run lib/osdi_dyn.zig's tests only").dependOn(&osdi_run.step);
    test_step.dependOn(&osdi_run.step);
    // zrunner cannot be its own runner's root: stock runner.
    const zrunner_test = b.addTest(.{ .name = "zrunner", .root_module = m.make("tools/zrunner.zig", &.{}) });
    all_step.dependOn(&zrunner_test.step);
    const zrunner_run = b.addRunArtifact(zrunner_test);
    b.step("test-tools", "Run tools/zrunner.zig's tests only").dependOn(&zrunner_run.step);
    test_step.dependOn(&zrunner_run.step);
    const other_exe = cliExe(b, target, optimize, mods, if (language == .ams) "vera-verilog" else "vera-ams", language != .ams);
    test_step.dependOn(&other_exe.step);
    all_step.dependOn(&other_exe.step);

    const all_mod = m.make("tests/unit.zig", mods);
    const repo = b.addOptions();
    repo.addOption([]const u8, "repo_root", pathFromRoot(b, "."));
    all_mod.addOptions("repo_options", repo);
    const all_run = testRun(b, "test_all", all_mod, runner, results_dir);
    // Reads the tree at test time: every file it can reach is an input, so a
    // no-op build reuses the result (globFiles re-runs configure for new files).
    for ([_][]const u8{ "lib", "src", "tools", "tests", "specification" }) |dir| {
        for (globFiles(b, dir, "")) |f| all_run.addFileInput(b.path(f));
    }
    all_run.addFileInput(b.path("build.zig"));
    all_run.addFileInput(b.path("build.zig.zon"));
    test_step.dependOn(&all_run.step);
    b.step("test-all", "Run tests/unit.zig, the cross-module claims, only").dependOn(&all_run.step);

    // LLVM: the self-hosted backend emits no coverage, so the fuzzer sees no PCs.
    const fuzz_test = b.addTest(.{ .name = "fuzz", .root_module = m.make("tests/fuzz.zig", &.{.{ .name = "vera", .module = vera }}), .use_llvm = true });
    b.step("fuzz", "The in-process fuzz targets on the stock runner (`zig build fuzz --fuzz[=N]`: coverage-guided)").dependOn(&b.addRunArtifact(fuzz_test).step);

    const rng_ref = m.make("tests/rng_reference.zig", &.{.{ .name = "kernels", .module = kernels }});
    rng_ref.link_libc = true;
    rng_ref.addCSourceFile(.{ .file = b.path("tests/rng_reference.c"), .flags = &.{"-ffp-contract=off"} });
    const rng_run = testRun(b, "rng_reference", rng_ref, runner, results_dir);
    const rng_step = b.step("test-rng-reference", "Compare rng_kernels with the IEEE 1364 §17.9.3 C listing, and run its domain refusals");
    rng_step.dependOn(&rng_run.step);
    test_step.dependOn(&rng_run.step);
    const rng_domains = b.addExecutable(.{ .name = "rng-domains", .root_module = m.make("tests/rng_reference.zig", &.{.{ .name = "kernels", .module = kernels }}) });
    for (0..46) |case| {
        const r = b.addRunArtifact(rng_domains);
        r.addArg(b.fmt("{d}", .{case}));
        r.expectExitCode(1);
        r.expectStdErrMatch(switch (case / 2) {
            6, 7, 9, 10, 12, 13, 21 => "error[E0816]: LRM 9.13.2: fractional or out-of-range",
            17, 18, 19, 22 => "error[E0816]: LRM 9.13.2: random uniform start shall be smaller than end",
            else => "error[E0816]: LRM 9.13.2: random distribution mean/df/stages shall be greater than zero",
        });
        rng_step.dependOn(&r.step);
        test_step.dependOn(&r.step);
    }
    // ReleaseSafe: 10^5 exact expansions take minutes in Debug. glibc: the oracle must conform.
    const printf_step = b.step("test-printf-reference", "Compare str_kernels.zCReal's %e/%f/%g with glibc's snprintf");
    if (target.result.isGnuLibC()) {
        const printf_ref = b.createModule(.{
            .root_source_file = b.path("tests/printf_reference.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .imports = &.{.{ .name = "kernels", .module = kernels }},
        });
        const printf_run = testRun(b, "printf_reference", printf_ref, runner, results_dir);
        printf_step.dependOn(&printf_run.step);
        test_step.dependOn(&printf_run.step);
    }

    const vpi_runs = vpiRuns(b);
    const vpi_run_paths = b.allocator.alloc([]const u8, vpi_runs.len) catch @panic("OOM");
    for (vpi_runs, vpi_run_paths) |r, *path| path.* = r.c;
    const o = b.addOptions();
    o.addOption([]const u8, "fixture_root", pathFromRoot(b, "tests/fixtures"));
    o.addOption([]const u8, "repo_root", pathFromRoot(b, "."));
    o.addOption([]const u8, "docs_root", pathFromRoot(b, "specification"));
    o.addOption([]const u8, "work_root", pathFromRoot(b, ".zig-cache/vera-suite"));
    o.addOption([]const u8, "contract", pathFromRoot(b, "lib/contract.zig"));
    o.addOption([]const u8, "vpi_include", pathFromRoot(b, "src/vpi"));
    o.addOption([]const []const u8, "vpi_runs", vpi_run_paths);
    o.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    const suite_mod = m.make("tests/suite.zig", &.{
        .{ .name = "vera", .module = vera },
        .{ .name = "sim", .module = sim },
        .{ .name = "digital", .module = byName(mods, "digital") },
    });
    suite_mod.addOptions("suite_options", o);
    const suite_exe = b.addExecutable(.{ .name = "vera-suite", .root_module = suite_mod });
    all_step.dependOn(&suite_exe.step);
    const suite_run = testRun(b, "suite", suite_mod, runner, results_dir);
    suite_run.has_side_effects = true; // reads tests/fixtures at test time
    test_step.dependOn(&suite_run.step);
    b.step("test-suite", "Run the suite runner's own unit tests only").dependOn(&suite_run.step);
    b.step("suite-exe", "Build the suite runner (tests/suite.zig)").dependOn(&suite_exe.step);

    const check = b.step("check", "Type-check every root without emitting a binary (`--watch -fincremental`: the edit loop)");
    for ([_]*Module{ exe.root_module, other_exe.root_module, suite_mod }) |r| {
        check.dependOn(&b.addExecutable(.{ .name = "check", .root_module = r, .use_llvm = false }).step);
    }
    for (mods) |mod| check.dependOn(&b.addTest(.{ .name = "check", .root_module = mod.module, .test_runner = runner, .use_llvm = false }).step);
    for ([_]*Module{ exe.root_module, osdi_mod, all_mod, suite_mod }) |r| {
        check.dependOn(&b.addTest(.{ .name = "check", .root_module = r, .test_runner = runner, .use_llvm = false }).step);
    }

    // No expectExitCode: a stdio check makes a Run cacheable, and the inputs are read at run time.
    for ([_]struct { []const u8, ?[]const u8, []const u8 }{
        .{ "benchmark", null, "Run every fixture through VerA — compile, build, run, judge — and time it (use -Doptimize=ReleaseFast)" },
        .{ "test-devices", "devices", "Run `vera --run` over ieee1364/ and digital/ and diff their transcripts" },
        .{ "test-1364", "ieee1364", "Run the IEEE 1364-2005 transcript suite (`-- --coverage`: its clause inventory; `-- --native`: through `vera --emit-exe`)" },
        .{ "test-ams", "ams", "Run the Verilog-AMS fixture suite strictly, without the benchmark timing pass" },
        .{ "test-vpi-fixtures", "vpi", "Compile the .c VPI fixtures against src/vpi/vpi_user.h" },
        .{ "golden", "golden", "Snapshot `vera --emit-zig`, the testbench runner, the `--emit-so` tree and the `.v` program text of every fixture (`-- <tag>`), or compare two (`-- diff [a b]`)" },
    }) |s| {
        const run = b.addRunArtifact(suite_exe);
        run.addArtifactArg2(exe, .{});
        if (s[1]) |mode| run.addArg(mode);
        run.addPassthruArgs();
        b.step(s[0], s[2]).dependOn(&run.step);
    }

    // ESPice depends on VerA, so VerA runs `espice` as a process and never
    // imports it. `dependencyStep` fetches ESPice (with Gompute and its model
    // tarballs) only when test-spice is requested; once fetched, every
    // configure runs its build.zig. `--fork .` makes ESPice's own `vera` this
    // tree (a fork replaces every package with its name and fingerprint), so
    // the decks' devices are compiled by the compiler under test. An unused
    // fork is a Zig error, so a -Despice run takes none. VerA never picks the
    // backend: espice's `--backend auto` does, `-- --backend=cuda` forces one;
    // the GPU options forward only so a built espice can be a GPU one.
    const test_spice = b.step("test-spice", "Run the .sp decks on espice and grade each against its oracle (`--fork .` builds ESPice against this tree; -Despice=PATH runs an installed one; `-- --backend=cuda` and other unknown args reach espice)");
    const spice_run = b.addRunArtifact(suite_exe);
    spice_run.addArtifactArg2(exe, .{});
    spice_run.addArg("spice");
    // espice compiles the decks' `.hdl` models at run time, with this build's Zig,
    // into its own cache (keyed on the model, its includes and the espice
    // binary), kept under this tree's cache rather than ~/.cache/espice.
    spice_run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    spice_run.setEnvironmentVariable("ESPICE_CACHE", pathFromRoot(b, ".zig-cache/vera-suite/espice"));
    if (espice_path) |path| {
        spice_run.addArg(b.fmt("--espice={s}", .{path}));
        test_spice.dependOn(&spice_run.step);
    } else if (b.pkg_hash.len == 0) {
        // The root package only: under `--fork .` ESPice's `vera` runs this
        // build.zig, whose test-spice would configure ESPice again, without end.
        if (b.dependencyStep(test_spice, "espice", .{ .target = b.graph.host, .optimize = optimize, .gpu = espice_gpu, .@"cuda-arch" = cuda_arch, .@"hip-arch" = hip_arch })) |espice| {
            // The arguments ESPice gives its host `vera`: that instance, not a new one.
            const vera_root = realRoot(espice.builder.dependency("vera", .{ .target = b.graph.host, .optimize = .fast }).builder);
            if (std.mem.eql(u8, vera_root, realRoot(b))) {
                // Not `espice.artifact("espice")`: ESPice also installs its
                // static C library as `espice`, which makes that name ambiguous.
                const espice_exe = for (espice.builder.install_tls.step.dependencies.items) |s| {
                    const a = (s.cast(Build.Step.InstallArtifact) orelse continue).artifact;
                    if (a.kind == .exe and std.mem.eql(u8, a.name, "espice")) break a;
                } else @panic("ESPice installs no `espice` executable");
                spice_run.addArtifactArg2(espice_exe, .{ .prefix = "--espice=" });
                test_spice.dependOn(&spice_run.step);
            } else {
                test_spice.dependOn(&b.addFail(b.fmt("test-spice: ESPice's vera is {s}, not this tree, so its devices would be compiled by another VerA: run `zig build test-spice --fork .` (or -Despice=PATH for an installed espice)", .{vera_root})).step);
            }
        }
    }
    spice_run.addPassthruArgs();

    // These host assertions inspect diagnostics that an HDL model cannot
    // observe about itself. Use the artifact from this build, never zig-out.
    const observations = b.addSystemCommand(&.{"python3"});
    observations.addFileArg(b.path("tests/host.py"));
    observations.addArg("diagnostic_observations");
    observations.addArg("--vera");
    observations.addArtifactArg2(exe, .{});
    if (results_dir) |dir| observations.addArgs(&.{ "--results", b.fmt("{s}/diagnostic_observations.tsv", .{dir}) });
    observations.addPassthruArgs();
    observations.has_side_effects = true;
    b.step("test-observations", "Check analog diagnostic output, retaining expected conformance failures").dependOn(&observations.step);

    const paired = b.addSystemCommand(&.{"python3"});
    paired.addFileArg(b.path("tests/host.py"));
    paired.addArg("paired_compiler_observations");
    paired.addArg("--vera");
    paired.addArtifactArg2(exe, .{});
    if (results_dir) |dir| paired.addArgs(&.{ "--results", b.fmt("{s}/paired_compiler_observations.tsv", .{dir}) });
    paired.has_side_effects = true;
    b.step("test-paired-compiler", "Check exact compiler refusals and their behavioral controls").dependOn(&paired.step);
    test_step.dependOn(&paired.step);

    // Conditional host capabilities are explicit skips until bound through
    // VERA_HOST_PROFILE_ADAPTER. Oracle self-tests never supply these results.
    const profiles = b.step("test-host-profiles", "Check conditional host observations with an explicitly configured adapter");
    for ([_][]const u8{ "report_observations", "indirect_equation_observations", "conditional_observations", "absdelta_rejection_observations", "scheduling_observations", "language_semantics_observations", "compact_modeling_observations", "directive_documentation" }) |name| {
        const profile = b.addSystemCommand(&.{"python3"});
        profile.addFileArg(b.path("tests/host.py"));
        profile.addArg(name);
        if (results_dir) |dir| profile.addArgs(&.{ "--results", b.fmt("{s}/{s}.tsv", .{ dir, name }) });
        profile.has_side_effects = true;
        profiles.dependOn(&profile.step);
        test_step.dependOn(&profile.step);
    }

    const canary = b.addRunArtifact(suite_exe);
    canary.addArtifactArg2(exe, .{});
    canary.addArg("canary");
    canary.expectExitCode(0);
    canary.has_side_effects = true;
    b.step("test-canary", "Check the harness FAILs every wrong-on-purpose fixture in tests/fixtures/canary/").dependOn(&canary.step);
    test_step.dependOn(&canary.step);

    const host_opts = b.addOptions();
    host_opts.addOption([]const u8, "contract", pathFromRoot(b, "lib/contract.zig"));
    host_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    host_opts.addOption([]const u8, "work_root", pathFromRoot(b, ".zig-cache/vera-vpi"));
    const vpi_host_mod = m.make("tests/fixtures/ch11_vpi/vpi_host.zig", &.{
        .{ .name = "vera", .module = vera },
        .{ .name = "vpi", .module = byName(mods, "vpi") },
        .{ .name = "sim", .module = sim },
        .{ .name = "vpi_host_options", .module = host_opts.createModule() },
        .{ .name = "dynlib", .module = dynlib },
    });
    vpi_host_mod.link_libc = true;
    vpi_host_mod.addAnonymousImport("vpi_design", .{ .root_source_file = b.path("tests/fixtures/ch11_vpi/vpi_design.va") });
    const vpi_host = b.addLibrary(.{ .name = "vera-vpi-host", .linkage = .static, .root_module = vpi_host_mod });
    all_step.dependOn(&vpi_host.step);
    const vpi_app = vpiApp(b, target, optimize, vpi_host, "tests/fixtures/ch11_vpi/vpi_app.c");
    vpi_app.expectExitCode(0);
    vpi_app.expectStdOutEqual("vpi: scopes=5 ports=11 nets=6 regs=2 params=8 checks=702\n");
    test_step.dependOn(&vpi_app.step);
    test_vpi.dependOn(&vpi_app.step);
    if (results_dir) |dir| {
        // This acceptance application contains named expected failures as
        // well as ordinary checks. Its XPASS guards make a resolved gap fail
        // until the expectation is updated. Record each named check.
        var rows: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, configText(b, "tests/fixtures/ch11_vpi/vpi_app.c"), '\n');
        while (lines.next()) |raw| {
            const rest = std.mem.cutPrefix(u8, std.mem.trim(u8, raw, " \t\r"), "// evidence: ") orelse continue;
            const status, const name = std.mem.cutScalar(u8, rest, ' ') orelse @panic("bad C evidence declaration");
            if (!std.mem.eql(u8, status, "pass") and !std.mem.eql(u8, status, "xfail")) @panic("bad C evidence status");
            vpi_app.expectStdErrMatch(b.fmt("{s} {s}:", .{
                if (std.mem.eql(u8, status, "xfail")) "XFAIL" else "PASS",
                name,
            }));
            rows.print(b.allocator, "{s}\tvpi_app.test.{s}\n", .{ status, name }) catch @panic("OOM");
        }
        const record = recordResults(b, vpi_app, dir, "vpi_acceptance.tsv", rows.items);
        test_step.dependOn(record);
        test_vpi.dependOn(record);
    }
    for (vpi_runs) |f| {
        const r = vpiApp(b, target, optimize, vpi_host, f.c);
        r.addFileArg(b.path(f.design));
        if (std.mem.endsWith(u8, f.design, ".va")) r.addFileArg(b.path(f.c));
        r.setCwd(b.path(".zig-cache"));
        if (f.xfail orelse f.refuse) |msg| {
            r.expectExitCode(1);
            r.expectStdErrMatch(msg);
            if (f.refuse != null) r.expectStdOutEqual(f.stdout);
        } else {
            r.expectExitCode(0);
            r.expectStdOutEqual(f.stdout);
            if (f.stderr) |e| r.expectStdErrEqual(e);
        }
        test_step.dependOn(&r.step);
        test_vpi.dependOn(&r.step);
        if (results_dir) |dir| {
            // A marker can only be written after the application's exit,
            // stdout and stderr checks succeed. Missing markers earn no credit.
            const slug = b.allocator.dupe(u8, f.c["tests/fixtures/".len .. f.c.len - 2]) catch @panic("OOM");
            std.mem.replaceScalar(u8, slug, '/', '_');
            const name = b.fmt("vpi--{s}.tsv", .{slug});
            const record = recordResults(b, r, dir, name, b.fmt("{s}\t{s}\n", .{
                if (f.xfail != null) "xfail" else "pass",
                f.c["tests/fixtures/".len..],
            }));
            test_step.dependOn(record);
            test_vpi.dependOn(record);
        }
    }

    if (language != .ams) return;
    const test_timers = b.step("test-timers", "Run emitted-device timer scheduling tests");
    const test_paramsets = b.step("test-paramsets", "Run emitted-device paramset binding and host shape tests");
    for (hostTests(b)) |h| {
        const gen = genRun(b, va_gen, h.va);
        gen.addArgs(&.{ "--emit-zig", "-I" });
        gen.addDirectoryArg2(b.path("tests/fixtures"), .{});
        gen.addFileArg(b.path(h.va));
        gen.addArg("-o");
        const device = gen.addOutputFileArg2("device.zig", .{});
        _ = gen.captureStdErr(.{});
        const host = m.make(h.host, &.{
            .{ .name = "contract", .module = contract },
            .{ .name = "device", .module = b.createModule(.{ .root_source_file = device, .target = target, .optimize = optimize, .imports = &.{.{ .name = "contract", .module = contract }} }) },
        });
        const ptx_opts: ?*Build.Step.Options = if (std.mem.find(u8, configText(b, h.host), "@import(\"ptx\")") != null) b.addOptions() else null;
        if (ptx_opts) |po| host.addOptions("ptx", po);
        const run_host = testRun(b, b.fmt("{s}--{s}", .{ std.fs.path.stem(h.host), std.fs.path.stem(h.va) }), host, runner, results_dir);
        test_step.dependOn(&run_host.step);
        if (std.mem.eql(u8, h.host, "tests/fixtures/ch05_analog_behavior/timer_host.zig")) test_timers.dependOn(&run_host.step);
        if (std.mem.eql(u8, h.host, "tests/fixtures/ch06_hierarchy/paramset_host.zig")) test_paramsets.dependOn(&run_host.step);

        // `<x>_gpu.zig` must export `<x>_ops_kernel`. NVPTX goes to LLVM IR, since the
        // backend refuses an @export alias of a kernel; `wide` and ptx hosts check its PTX.
        const stem = h.host[0 .. h.host.len - "_host.zig".len];
        const gpu_src = b.fmt("{s}_gpu.zig", .{stem});
        b.root.root_dir.handle.access(b.graph.io, gpu_src, .{}) catch continue;
        const wide_gpu = std.mem.eql(u8, std.fs.path.basename(stem), "wide");
        for ([_][2][]const u8{ .{ "nvptx64-cuda", "sm_70" }, .{ "amdgcn-amdhsa", "gfx906" } }) |gpu| {
            const gt = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = gpu[0], .cpu_features = gpu[1] }) catch unreachable);
            const gc: Import = .{ .name = "contract", .module = b.createModule(.{ .root_source_file = b.path("lib/contract.zig"), .target = gt, .optimize = .fast }) };
            const obj = b.addObject(.{ .name = std.fs.path.stem(gpu_src), .root_module = b.createModule(.{
                .root_source_file = b.path(gpu_src),
                .target = gt,
                .optimize = .fast,
                .strip = true,
                .imports = &.{ gc, .{ .name = "device", .module = b.createModule(.{ .root_source_file = device, .target = gt, .optimize = .fast, .imports = &.{gc} }) } },
            }) });
            const nvptx = gt.result.cpu.arch == .nvptx64;
            const out = if (!nvptx) obj.getEmittedBin() else if (wide_gpu or ptx_opts != null) obj.getEmittedAsm() else obj.getEmittedLlvmIr();
            if (nvptx) if (ptx_opts) |po| po.addOptionPath("path", out);
            test_step.dependOn(&b.addCheckFile(out, .{ .expected_matches = &.{b.fmt("{s}_ops_kernel", .{std.fs.path.basename(stem)})} }).step);
        }
    }

    const vdev_host = m.make("tests/fixtures/ch07_mixed_signal/vdev_host.zig", &.{.{ .name = "contract", .module = contract }});
    const so_opts = b.addOptions();
    const vdev_so_host = m.make("tests/fixtures/ch07_mixed_signal/vdev_so_host.zig", &.{
        .{ .name = "vdev_dyn", .module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/ch07_mixed_signal/vdev_dyn.zig"), .imports = &.{.{ .name = "contract", .module = contract }} }) },
        .{ .name = "vdev_so_options", .module = so_opts.createModule() },
        .{ .name = "dynlib", .module = dynlib },
    });
    vdev_so_host.link_libc = true;
    for ([_][]const u8{ "v_inv", "v_buf", "v_count", "v_a2d", "v_edge", "v_any", "v_wide", "v_huge", "v_say" }) |name| {
        const src_path = b.fmt("tests/fixtures/ch07_mixed_signal/{s}.v", .{name});
        const src = b.path(src_path);
        const gen = genRun(b, va_gen, src_path);
        gen.addArg("--emit-zig");
        gen.addFileArg(src);
        gen.addArg("-o");
        const dev_mod = b.createModule(.{
            .root_source_file = gen.addOutputFileArg2(b.fmt("{s}.zig", .{name}), .{}),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "contract", .module = contract }, .{ .name = "sim", .module = sim } },
        });
        vdev_host.addImport(name, dev_mod);
        if (!std.mem.eql(u8, name, "v_count") and !std.mem.eql(u8, name, "v_a2d") and !std.mem.eql(u8, name, "v_buf")) continue;
        vdev_so_host.addImport(name, dev_mod);
        const so = genRun(b, va_gen, src_path);
        so.addArgs(&.{ "--emit-so", "--contract" });
        so.addFileArg(b.path("lib/contract.zig"));
        so.addArg("--dyn");
        so.addFileArg(b.path("tests/fixtures/ch07_mixed_signal/vdev_dyn.zig"));
        so.addArg("--work-dir");
        const wd = so.addOutputDirectoryArg2(name, .{});
        so.addFileArg(src);
        const host = &b.graph.host.result;
        so_opts.addOptionPath(name, wd.path(b, b.fmt("{s}{s}.1{s}", .{ host.libPrefix(), name, host.dynamicLibSuffix() })));
    }
    test_step.dependOn(&testRun(b, "vdev_host", vdev_host, runner, results_dir).step);
    test_step.dependOn(&testRun(b, "vdev_so_host", vdev_so_host, runner, results_dir).step);

    for ([_]struct { []const []const u8, []const u8, u8, []const u8 }{
        .{ &.{"--emit-zig"}, "ch07_mixed_signal/v_inout.v", 1, "error[E1103]: design cannot be a contract device: module `v_inout`: an inout port" },
        .{ &.{"--emit-zig"}, "ch07_mixed_signal/v_integer.v", 1, "error[E1103]: design cannot be a contract device: module `v_integer`: an integer or time port" },
        .{ &.{"--emit-zig"}, "ch07_mixed_signal/v_pins.v", 1, "error[E1103]: design cannot be a contract device: module `v_pins`: more than 65535 pins" },
        .{ &.{"--emit-zig"}, "ch07_mixed_signal/v_tran.v", 1, "error[E1103]: design cannot be a contract device: module `v_tran`: a §7.6 pass switch" },
        .{ &.{ "--emit-zig", "--state=auto" }, "ch07_mixed_signal/v_inv.v", 1, "error[E1103]: design cannot be a contract device: a contract device is 4-state: --state=auto" },
        .{ &.{"--emit-zig"}, "ch07_mixed_signal/v_sv.sv", 2, "error[E1104]: a SystemVerilog source is not supported" },
        .{ &.{"--emit-zig"}, "ch07_mixed_signal/v_seconds.v", 0, "warning[W1155]: device digital tick is 1 s" },
    }) |r| {
        const run = b.addRunArtifact(exe);
        run.addArgs(r[0]);
        run.addFileArg(b.path(b.fmt("tests/fixtures/{s}", .{r[1]})));
        run.expectExitCode(r[2]);
        run.addCheck(.{ .expect_stderr_match = r[3] });
        test_step.dependOn(&run.step);
    }

    for ([_]struct { []const u8, u8, []const u8 }{
        .{ "ch05_analog_behavior/vera_reject_step_retry.va", 1, "error[E1099]" },
        .{ "ch04_expressions/noise_anticorrelated_coefficient.va", 0, "warning[W1098]" },
        .{ "ch07_mixed_signal/v_seconds.v", 0, "warning[W1155]" },
        .{ "ch03_data_types/module_without_parameters.va", 0, "" },
    }) |r| {
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ "--emit-osdi", "-I" });
        run.addDirectoryArg2(b.path("tests/fixtures"), .{});
        run.addArg("--work-dir");
        _ = run.addOutputDirectoryArg2("osdi", .{});
        if (r[1] == 0) {
            run.addArg("-o");
            _ = run.addOutputFileArg2("device.osdi", .{});
        }
        run.addFileArg(b.path(b.fmt("tests/fixtures/{s}", .{r[0]})));
        run.expectExitCode(r[1]);
        run.addCheck(.{ .expect_stderr_match = r[2] });
        test_step.dependOn(&run.step);
    }

    const grid_events = b.step("test-grid-events", "Check fixed-grid testbench diagnostics and execution");
    test_step.dependOn(grid_events);
    for ([_][]const u8{ "--run", "--emit-exe" }) |mode| for ([_][]const u8{ "allow", "warn", "deny", "forbid" }) |level| {
        const rejected = std.mem.eql(u8, level, "deny") or std.mem.eql(u8, level, "forbid");
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ mode, b.fmt("--{s}=W0750", .{level}), "--allow=W0650", "-I" });
        run.addDirectoryArg2(b.path("tests/fixtures"), .{});
        run.addArg("--work-dir");
        _ = run.addOutputDirectoryArg2("tb", .{});
        run.addFileArg(b.path("tests/fixtures/ch05_analog_behavior/event_cross_fires_on_a_time_grid.va"));
        run.expectExitCode(if (rejected) 1 else 0);
        if (rejected) {
            run.expectStdOutEqual("");
            run.addCheck(.{ .expect_stderr_match = "error[W0750]" });
        } else {
            if (std.mem.eql(u8, mode, "--run"))
                run.addCheck(.{ .expect_stderr_match = "one rising clk edge is one event got=1 want=1 ok=1" });
            if (std.mem.eql(u8, level, "warn"))
                run.addCheck(.{ .expect_stderr_match = "warning[W0750]" })
            else if (std.mem.eql(u8, mode, "--emit-exe"))
                run.expectStdErrEqual("");
        }
        grid_events.dependOn(&run.step);
    };

    const beh_step = b.step("test-beh-verilog", "Simulate --emit-verilog modules in iverilog and lint them in verilator");
    const vdd_vss = "`ifdef USE_POWER_PINS\n    , vdd\n    , vss\n`endif\n);";
    for ([_]struct { va: []const u8, args: []const []const u8, says: []const u8, supplies: []const u8 = vdd_vss }{
        .{ .va = "strongarm", .args = &.{ "--digital-pins", "clk,outp,outn" }, .says = "parameter real vera_fall_fp = 0.500000; // ns" },
        .{ .va = "async_ctrl", .args = &.{ "--digital-pins", "go adc_done xbar_rst adc_go latch_out done" }, .says = "parameter real vera_rise_s = 48.000000; // ns" },
        .{ .va = "tq_chain", .args = &.{ "--digital-pins", "in,tap1,tap2,tap3,tap4" }, .says = "parameter real vera_rise_m1 = 7.100000; // ns" },
        .{ .va = "attrs", .args = &.{}, .says = "parameter real vera_rise_z = 3.000000; // ns", .supplies = "`ifdef USE_POWER_PINS\n    , pwr\n    , gnd0\n`endif\n);" },
    }) |f| {
        const va = b.path(b.fmt("tests/fixtures/beh_verilog/{s}.va", .{f.va}));
        const gen = b.addRunArtifact(exe);
        gen.addArgs(&.{ "--emit-verilog", "--power-pins", "--allow=W0650" });
        gen.addArgs(f.args);
        gen.addFileArg(va);
        gen.addArg("-o");
        const v = gen.addOutputFileArg(b.fmt("{s}.v", .{f.va}));
        gen.expectExitCode(0);
        test_step.dependOn(&gen.step);
        const pinned = b.addRunArtifact(exe);
        pinned.addArgs(&.{ "--emit-verilog", "--power-pins", "--allow=W0650" });
        pinned.addArgs(f.args);
        pinned.addFileArg(va);
        pinned.addCheck(.{ .expect_stdout_match = f.says });
        pinned.addCheck(.{ .expect_stdout_match = f.supplies });
        test_step.dependOn(&pinned.step);
        for ([_][]const []const u8{ &.{}, &.{"-DUSE_POWER_PINS"} }) |def| {
            const lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wall", "--timing" });
            lint.addArgs(def);
            lint.addFileArg(v);
            lint.expectExitCode(0);
            beh_step.dependOn(&lint.step);
            const comp = b.addSystemCommand(&.{ "iverilog", "-Wall" });
            comp.addArgs(def);
            comp.addArg("-o");
            const vvp = comp.addOutputFileArg(b.fmt("tb_{s}.vvp", .{f.va}));
            comp.addFileArg(v);
            comp.addFileArg(b.path(b.fmt("tests/fixtures/beh_verilog/tb_{s}.v", .{f.va})));
            comp.expectExitCode(0);
            const sim_run = b.addSystemCommand(&.{ "vvp", "-n" });
            sim_run.addFileArg(vvp);
            sim_run.addCheck(.{ .expect_stdout_match = b.fmt("PASS tb_{s}", .{f.va}) });
            beh_step.dependOn(&sim_run.step);
        }
    }
    {
        const va = b.path("tests/fixtures/beh_verilog/rc_charge.va");
        const bad = b.addRunArtifact(exe);
        bad.addArgs(&.{ "--emit-verilog", "--allow=W0650", "--digital-pins", "a,y", "--param", "c=inf" });
        bad.addFileArg(va);
        bad.expectExitCode(1);
        bad.expectStdOutEqual("");
        bad.addCheck(.{ .expect_stderr_match = "--emit-verilog: node `y`: its delay is not finite" });
        test_step.dependOn(&bad.step);
        const ok = b.addRunArtifact(exe);
        ok.addArgs(&.{ "--emit-verilog", "--allow=W0650", "--digital-pins", "a,y" });
        ok.addFileArg(va);
        ok.expectExitCode(0);
        ok.addCheck(.{ .expect_stdout_match = "parameter real vera_rise_y = 0.693147; // ns" });
        ok.addCheck(.{ .expect_stdout_match = "parameter real vera_fall_y = 0.693147; // ns" });
        test_step.dependOn(&ok.step);
    }

    // `--emit-rtlil` read back by Yosys itself: `proc` lowers the processes
    // and `check -assert` finds a wire with no driver or two of them.
    const rtlil_step = b.step("test-rtlil", "Emit tests/fixtures/rtlil/*.v as RTLIL and have yosys read, proc and check it");
    for (globFiles(b, "tests/fixtures/rtlil", ".v")) |v| {
        const gen = b.addRunArtifact(exe);
        gen.addArg("--emit-rtlil");
        gen.addFileArg(b.path(v));
        gen.addArg("-o");
        const il = gen.addOutputFileArg(b.fmt("{s}.il", .{std.fs.path.stem(v)}));
        // Yosys reads the positional `.il` first, then runs the script.
        const yosys = b.addSystemCommand(&.{ "yosys", "-q", "-p", "hierarchy -check -top top; proc; opt_clean; check -assert; stat" });
        yosys.addFileArg(il);
        yosys.expectExitCode(0);
        rtlil_step.dependOn(&yosys.step);
    }

    const vampyre = b.addSystemCommand(&.{ "python3", "tools/external_vampyre.py", "--vera" });
    vampyre.addArtifactArg(exe);
    vampyre.setCwd(b.path("."));
    vampyre.has_side_effects = true;
    vampyre.expectExitCode(0);
    b.step("test-vampyre", "VAMPyRE and VerA on the same compact models, every disagreement triaged by name").dependOn(&vampyre.step);

    // --emit-so must still name the .va when the device fails to compile.
    {
        const wf = b.addWriteFiles();
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ "--emit-so", "--allow=W0650", "--contract" });
        run.addFileArg(wf.add("contract.zig", "comptime {\n    @compileError(\"broken contract\");\n}\n"));
        run.addArg("--dyn");
        run.addFileArg(wf.add("dyn.zig", "pub fn exportDevice(comptime D: type, comptime name: []const u8) void {\n    _ = D;\n    _ = name;\n}\n"));
        run.addArg("--work-dir");
        _ = run.addOutputDirectoryArg2("so", .{});
        run.addFileArg(b.path("tests/fixtures/ch11_vpi/vpi_design.va"));
        run.expectExitCode(1);
        run.expectStdOutEqual("");
        run.addCheck(.{ .expect_stderr_match = "vpi_design.va: codegen produced Zig that does not compile" });
        run.addCheck(.{ .expect_stderr_match = "broken contract" });
        test_step.dependOn(&run.step);
    }

    // E1013: a sparse file one byte past the lexer's u32 offsets is refused from its size.
    if (b.graph.host.result.os.tag != .windows) {
        const mk = b.addSystemCommand(&.{ "dd", "if=/dev/zero", "bs=1", "count=0", "seek=4294967296" });
        const big = mk.addPrefixedOutputFileArg("of=", "big.va");
        _ = mk.captureStdErr(.{});
        for ([_]bool{ false, true }) |netlist| {
            const run = b.addRunArtifact(exe);
            run.setCwd(b.path("."));
            run.addArg("--lint");
            if (netlist) run.addArg("--spice");
            run.addFileArg(big);
            if (netlist) run.addArg("tests/fixtures/ch02_lexical/identifier_1024_chars.va");
            run.expectExitCode(2);
            run.addCheck(.{ .expect_stderr_match = "big.va` is larger than 4294967295 bytes" });
            test_step.dependOn(&run.step);
        }
    }
}

/// The vera that generates test devices, and whether its runs are keyed on
/// their inputs alone (`-Dva-cache`).
const Gen = struct { exe: *Build.Step.Compile, cached: bool };

/// A run of the generating vera on `src` (build-root relative). Cached, vera
/// runs from a fixed copy under zig-out/gen named by a plain string, so the Run's
/// hash covers the arguments, `src`'s contents and its `include`s but not
/// vera's binary: a compiler edit leaves every generated device, and every
/// object built from it, cached. Rebuild them after a codegen change with
/// `-Dva-cache=false`.
fn genRun(b: *Build, gen: Gen, src: []const u8) *Run {
    if (!gen.cached) return b.addRunArtifact(gen.exe);
    const copy = b.fmt("zig-out/gen/{s}", .{gen.exe.out_filename});
    const usf = b.addUpdateSourceFiles();
    usf.addCopyFileToSource(gen.exe.getEmittedBin(), copy);
    const run = b.addSystemCommand(&.{b.fmt("./{s}", .{copy})});
    run.step.dependOn(&usf.step);
    addIncludes(b, run, src);
    // The device embeds contract.zig's `vera_version` and targets its
    // contract: a release bump or a contract edit regenerates it.
    run.addFileInput(b.path("lib/contract.zig"));
    return run;
}

/// Declares every file `src` reaches by `` `include "name" `` as an input of
/// `run`, searched in `src`'s directory then tests/fixtures (the `-I`).
fn addIncludes(b: *Build, run: *Run, src: []const u8) void {
    // A tree without tests/ (the flake's source package) declares no test
    // devices' includes; only a test step would run them.
    const text = b.root.root_dir.handle.readFileAlloc(b.graph.io, src, b.allocator, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return,
        else => std.debug.panic("{s}: {t}", .{ src, e }),
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const rest = std.mem.cutPrefix(u8, std.mem.trim(u8, line, " \t\r"), "`include") orelse continue;
        var q = std.mem.tokenizeScalar(u8, rest, '"');
        const name = q.next() orelse continue;
        const dirs = [_][]const u8{ std.fs.path.dirnamePosix(src) orelse ".", "tests/fixtures" };
        for (dirs) |dir| {
            const path = b.fmt("{s}/{s}", .{ dir, name });
            b.root.root_dir.handle.access(b.graph.io, path, .{}) catch continue;
            run.addFileInput(b.path(path));
            addIncludes(b, run, path);
            break;
        }
    }
}

/// Every `tests/*_host.zig`, once per `//! device <path under tests/fixtures>` line.
const HostTest = struct { host: []const u8, va: []const u8 };

fn hostTests(b: *Build) []const HostTest {
    var found: std.ArrayList(HostTest) = .empty;
    for (globFiles(b, "tests", "_host.zig")) |host| {
        var lines = std.mem.splitScalar(u8, configText(b, host), '\n');
        while (lines.next()) |raw| {
            const va = std.mem.cutPrefix(u8, std.mem.trimEnd(u8, raw, "\r"), "//! device ") orelse continue;
            found.append(b.allocator, .{ .host = host, .va = b.fmt("tests/fixtures/{s}", .{va}) }) catch @panic("OOM");
        }
    }
    return found.items;
}

fn cliExe(b: *Build, target: Build.ResolvedTarget, optimize: std.lang.Optimize, mods: []const Import, name: []const u8, ams: bool) *Build.Step.Compile {
    const o = b.addOptions();
    o.addOption(bool, "ams", ams);
    o.addOption([]const u8, "version", @import("build.zig.zon").version);
    var imports: std.ArrayList(Import) = .empty;
    for (mods) |m| if (!std.mem.eql(u8, m.name, "vpi")) imports.append(b.allocator, m) catch @panic("OOM");
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .imports = imports.items });
    mod.addOptions("build_options", o);
    mod.addImport("sim_sources", simSources(b));
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

/// `files`: every source under `lib/`, the tree `vera --emit-exe` and
/// `--emit-so` build against: the runtime (`sim`), the contract, the OSDI dyn
/// and the modules they import. `src/main.zig`'s `simTree` writes it out.
fn simSources(b: *Build) *Module {
    const wf = b.addWriteFiles();
    var root: std.Io.Writer.Allocating = .init(b.allocator);
    root.writer.writeAll("pub const files = [_][2][]const u8{\n") catch @panic("OOM");
    for (globFiles(b, "lib", ".zig")) |path| {
        b.dependOnFileContents(b.path(path));
        // By contents: addCopyFile hashes the absolute source path, so every worktree missed the cache.
        _ = wf.add(path, configText(b, path));
        root.writer.print("    .{{ \"{s}\", @embedFile(\"{s}\") }},\n", .{ path, path }) catch @panic("OOM");
    }
    root.writer.writeAll("};\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = wf.add("sim_sources.zig", root.written()) });
}

fn vpiApp(b: *Build, target: Build.ResolvedTarget, optimize: std.lang.Optimize, host: *Build.Step.Compile, c: []const u8) *Run {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addCSourceFile(.{ .file = b.path(c), .flags = &.{ "-std=c99", "-Wall", "-Werror" } });
    mod.addIncludePath(b.path("src/vpi"));
    mod.addIncludePath(b.path(std.fs.path.dirname(c).?));
    mod.linkLibrary(host);
    const app = b.addExecutable(.{ .name = b.fmt("vpi-{s}", .{std.fs.path.stem(c)}), .root_module = mod });
    b.top_level_steps.get("build-all").?.step.dependOn(&app.step);
    return b.addRunArtifact(app);
}

/// A `.c` fixture with `//! design`, plus its `//! stdout|stderr|xfail|refuse` lines.
const VpiRun = struct {
    c: []const u8,
    design: []const u8 = "",
    stdout: []const u8 = "",
    stderr: ?[]const u8 = null,
    xfail: ?[]const u8 = null,
    refuse: ?[]const u8 = null,
};

fn vpiRuns(b: *Build) []const VpiRun {
    var runs: std.ArrayList(VpiRun) = .empty;
    for (globFiles(b, "tests/fixtures", ".c")) |c| {
        var r: VpiRun = .{ .c = c };
        var out: std.ArrayList(u8) = .empty;
        var err: ?std.ArrayList(u8) = null;
        var lines = std.mem.splitScalar(u8, configText(b, c), '\n');
        while (lines.next()) |raw| {
            const line = std.mem.cutPrefix(u8, std.mem.trimEnd(u8, raw, "\r"), "//! ") orelse continue;
            const key, const val = std.mem.cutScalar(u8, line, ' ') orelse .{ line, "" };
            if (std.mem.eql(u8, key, "design")) {
                r.design = b.fmt("tests/fixtures/{s}", .{val});
            } else if (std.mem.eql(u8, key, "stdout")) {
                out.print(b.allocator, "{s}\n", .{val}) catch @panic("OOM");
            } else if (std.mem.eql(u8, key, "stderr")) {
                if (err == null) err = .empty;
                if (val.len != 0) err.?.print(b.allocator, "{s}\n", .{val}) catch @panic("OOM");
            } else if (std.mem.eql(u8, key, "xfail")) {
                r.xfail = val;
            } else if (std.mem.eql(u8, key, "refuse")) {
                r.refuse = val;
            }
        }
        if (r.design.len == 0) continue;
        r.stdout = out.items;
        if (err) |e| r.stderr = e.items;
        runs.append(b.allocator, r) catch @panic("OOM");
    }
    return runs.items;
}

/// Sorted `/`-separated files under `dir` ending in `suffix`; none if `dir` is absent.
/// Poisons the configure cache: dependOnDirectoryContents over the fixtures aborted Zig 0.17 on Windows.
fn globFiles(b: *Build, dir: []const u8, suffix: []const u8) []const []const u8 {
    const io = b.graph.io;
    var d = b.root.root_dir.handle.openDir(io, dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => std.debug.panic("{s}: {t}", .{ dir, e }),
    };
    defer d.close(io);
    b.graph.poisonCache();
    var walker = d.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    var found: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch |e| std.debug.panic("{s}: {t}", .{ dir, e })) |e| {
        const rel = b.fmt("{s}/{s}", .{ dir, e.path });
        std.mem.replaceScalar(u8, rel, '\\', '/');
        if (e.kind == .file and std.mem.endsWith(u8, rel, suffix)) found.append(b.allocator, rel) catch @panic("OOM");
    }
    std.mem.sort([]const u8, found.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return found.items;
}

fn configText(b: *Build, path: []const u8) []const u8 {
    return b.root.root_dir.handle.readFileAlloc(b.graph.io, path, b.allocator, .unlimited) catch |e| std.debug.panic("{s}: {t}", .{ path, e });
}

/// `module_specs` as modules, exported with `addModule` when `exported`.
fn defineModules(b: *Build, target: Build.ResolvedTarget, exported: bool) []const Import {
    var created: std.ArrayList(Import) = .empty;
    for (module_specs) |spec| {
        const deps = b.allocator.alloc(Import, spec.imports.len) catch @panic("OOM");
        for (deps, spec.imports) |*d, name| d.* = .{ .name = name, .module = byName(created.items, name) };
        const opts: Module.CreateOptions = .{ .root_source_file = b.path(spec.path), .target = target, .imports = deps };
        const mod = if (exported) b.addModule(spec.name, opts) else b.createModule(opts);
        if (std.mem.eql(u8, spec.name, "elab")) {
            mod.addAnonymousImport("resolution_unknown_fixture", .{ .root_source_file = b.path("tests/fixtures/annex_f_resolution/detail_resolution_unknown_after_bottom_up.va") });
            mod.addAnonymousImport("resolution_digital_parent_fixture", .{ .root_source_file = b.path("tests/fixtures/annex_f_resolution/detail_resolution_digital_parent.va") });
        }
        if (spec.c) |c| {
            mod.addCSourceFile(.{ .file = b.path(c), .flags = &.{ "-std=c99", "-Wall", "-Werror" } });
            mod.addIncludePath(b.path(std.fs.path.dirname(c).?));
        }
        created.append(b.allocator, .{ .name = spec.name, .module = mod }) catch @panic("OOM");
    }
    return created.items;
}

fn pathFromRoot(b: *Build, sub_path: []const u8) []u8 {
    return b.pathResolve(&.{ b.root.root_dir.path orelse ".", b.root.sub_path, sub_path });
}

/// `b`'s build root, canonical. A forked package's root is its `--fork`
/// argument as given (`.`) and the root package's is absolute, so only their
/// real paths compare.
fn realRoot(b: *Build) []const u8 {
    const root = pathFromRoot(b, ".");
    return std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, root, b.allocator) catch |e| std.debug.panic("{s}: {t}", .{ root, e });
}

fn byName(mods: []const Import, name: []const u8) *Module {
    for (mods) |m| if (std.mem.eql(u8, m.name, name)) return m.module;
    std.debug.panic("no module {s} above its importer in module_specs", .{name});
}

/// Publish C application results only after its checked execution succeeds.
fn recordResults(b: *Build, run: *Run, dir: []const u8, name: []const u8, contents: []const u8) *Build.Step {
    run.has_side_effects = true;
    const files = b.addWriteFiles();
    files.mode = .{ .mutate = .{ .cwd_relative = pathFromRoot(b, dir) } };
    _ = files.add(name, contents);
    files.step.dependOn(&run.step);
    return &files.step;
}

/// CLICOLOR_FORCE keeps zrunner's report colored under the build's capture.
fn testRun(b: *Build, name: []const u8, mod: *Module, runner: Build.Step.Compile.TestRunner, results_dir: ?[]const u8) *Run {
    const t = b.addTest(.{ .name = name, .root_module = mod, .test_runner = runner });
    b.top_level_steps.get("build-all").?.step.dependOn(&t.step);
    const r = b.addRunArtifact(t);
    r.setEnvironmentVariable("CLICOLOR_FORCE", "true");
    // A simple-mode runner gets no stdio check, and a Run without one reruns
    // every build. The exit code makes it cacheable on the binary and args;
    // a test that reads files at run time sets has_side_effects instead.
    r.expectExitCode(0);
    if (results_dir) |dir| {
        r.addArg(b.fmt("--results={s}/{s}.tsv", .{ pathFromRoot(b, dir), name }));
        r.has_side_effects = true;
    }
    return r;
}
