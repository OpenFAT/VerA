//! The steps that run a built tool over inputs: the fixture runner (`suite`,
//! `test-spice`), tests/host.py's observations and profiles, the
//! conformance tool's selftest, the degenerate-argv table, the runner
//! templates and the canaries. `build.zig` calls `add` once.
//!
//! Contents:
//! - `pub fn add(g: Graph, suite_exe: *Build.Step.Compile, check: *Build.Step, espice_path: ?[]const u8) void`

const std = @import("std");
const common = @import("common.zig");
const Build = std.Build;
const Module = Build.Module;
const Import = Module.Import;
const Run = Build.Step.Run;
const Graph = common.Graph;
const byName = common.byName;
const globFiles = common.globFiles;
const checkoutWorkDir = common.checkoutWorkDir;
const testRun = common.testRun;

pub fn add(g: Graph, suite_exe: *Build.Step.Compile, check: *Build.Step, espice_path: ?[]const u8) void {
    const b = g.b;
    const m = g.m;
    const mods = g.mods;
    const exe = g.exe;
    const test_step = g.test_step;
    const all_step = g.all_step;
    const runner = g.runner;
    const results_dir = g.results_dir;
    const vera = byName(g.mods, "vera");

    // No expectExitCode: a stdio check makes a Run cacheable, and the inputs are read at run time.
    const suite_run_all = b.addRunArtifact(suite_exe);
    suite_run_all.addArtifactArg2(exe, .{});
    suite_run_all.addPassthruArgs();
    b.step("suite", "The fixture runner: `-- ams` (strict AMS), `-- devices` (digital transcripts), `-- ieee1364`, `-- vpi` (C fixtures, compile only), `-- golden <tag>|diff [a b]`; no mode: every fixture, timed (-Doptimize=ReleaseFast)").dependOn(&suite_run_all.step);

    // ESPice depends on VerA and VerA does not depend on ESPice: VerA runs an
    // espice it is handed (-Despice=PATH, an ESPice release) as a process and
    // never builds or imports it. Such an espice compiles the decks' devices
    // with its own VerA, so this step checks compatibility with that release,
    // not this tree's compiler. VerA never picks the backend: espice's
    // `--backend auto` does, `-- --backend=cuda` forces one.
    const test_spice = b.step("test-spice", "Run the .sp decks on espice -Despice=PATH and grade each against its oracle (`-- --backend=cuda` and other unknown args reach espice)");
    const spice_run = b.addRunArtifact(suite_exe);
    spice_run.addArtifactArg2(exe, .{});
    spice_run.addArg("spice");
    // espice compiles the decks' `.hdl` models at run time, with this build's Zig,
    // into its own cache (keyed on the model, its includes and the espice
    // binary), kept under this tree's cache rather than ~/.cache/espice.
    spice_run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    spice_run.setEnvironmentVariable("ESPICE_CACHE", b.fmt("{s}/espice", .{checkoutWorkDir(b, "vera-suite")}));
    if (espice_path) |path| {
        spice_run.addArg(b.fmt("--espice={s}", .{path}));
        test_spice.dependOn(&spice_run.step);
    } else {
        test_spice.dependOn(&b.addFail("test-spice: pass -Despice=PATH, an espice release; VerA does not build ESPice").step);
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
    observations.has_side_effects = true;
    test_step.dependOn(&observations.step);

    const paired = b.addSystemCommand(&.{"python3"});
    paired.addFileArg(b.path("tests/host.py"));
    paired.addArg("paired_compiler_observations");
    paired.addArg("--vera");
    paired.addArtifactArg2(exe, .{});
    if (results_dir) |dir| paired.addArgs(&.{ "--results", b.fmt("{s}/paired_compiler_observations.tsv", .{dir}) });
    paired.has_side_effects = true;
    test_step.dependOn(&paired.step);

    // The host profiles need a real host bound through an adapter, which VerA
    // does not ship: they are `test-host-profiles -Dhost-adapter=EXE`, which
    // fails without one (unsupported fails, never skips). The documentation
    // profile needs no host and runs in `test`, beside the oracles' selftest.
    const host_adapter = b.option([]const u8, "host-adapter", "test-host-profiles: the executable that binds a real host to tests/host.py's profiles");
    const host_profiles = b.step("test-host-profiles", "Run tests/host.py's host profiles through -Dhost-adapter=EXE");
    if (host_adapter == null) host_profiles.dependOn(&b.addFail("test-host-profiles: pass -Dhost-adapter=EXE, an adapter binding a real host (tests/README.md)").step);
    for ([_][]const u8{ "report_observations", "indirect_equation_observations", "conditional_observations", "absdelta_rejection_observations", "scheduling_observations", "language_semantics_observations", "compact_modeling_observations", "directive_documentation", "selftest" }) |name| {
        const profile = b.addSystemCommand(&.{"python3"});
        profile.addFileArg(b.path("tests/host.py"));
        profile.addArg(name);
        if (results_dir) |dir| if (!std.mem.eql(u8, name, "selftest")) profile.addArgs(&.{ "--results", b.fmt("{s}/{s}.tsv", .{ dir, name }) });
        profile.has_side_effects = true;
        if (std.mem.eql(u8, name, "directive_documentation") or std.mem.eql(u8, name, "selftest")) {
            test_step.dependOn(&profile.step);
        } else if (host_adapter) |exe_path| {
            profile.addArgs(&.{ "--adapter", exe_path });
            host_profiles.dependOn(&profile.step);
        }
    }

    // The release measures' and fixture-maintenance signals' own checks: no
    // compiler, a couple of seconds. UTF-8 whatever the host's locale, as the
    // fixtures are (Windows' default is cp1252).
    const conformance_selftest = b.addSystemCommand(&.{"python3"});
    conformance_selftest.addFileArg(b.path("tools/conformance.py"));
    conformance_selftest.addArg("selftest");
    conformance_selftest.setEnvironmentVariable("PYTHONUTF8", "1");
    conformance_selftest.expectExitCode(0);
    conformance_selftest.has_side_effects = true; // reads the fixtures and tools/install.sh
    test_step.dependOn(&conformance_selftest.step);

    // The degenerate-argv table: every documented flag x "", "-", "=", a
    // 128 KiB value, missing, repeated, through this build's vera.
    const argv_exe = b.addExecutable(.{ .name = "vera-argv", .root_module = m.make("tests/argv.zig", &.{}) });
    all_step.dependOn(&argv_exe.step);
    check.dependOn(&b.addExecutable(.{ .name = "check", .root_module = argv_exe.root_module, .use_llvm = false }).step);
    const argv_run = b.addRunArtifact(argv_exe);
    argv_run.addArtifactArg2(exe, .{ .make_absolute = true }); // the rows run in the scratch dir
    _ = argv_run.addOutputDirectoryArg("argv");
    argv_run.expectExitCode(0);
    test_step.dependOn(&argv_run.step);
    test_step.dependOn(&testRun(b, "argv", m.make("tests/argv.zig", &.{}), runner, results_dir).step);
    b.step("test-argv", "Run the degenerate-argv table through the vera CLI only").dependOn(&argv_run.step);

    // The runner templates (src/codegen/exe/text): one runner per variant,
    // type-checked as its build compiles it (tests/runners.zig).
    const runners_mod = m.make("tests/runners.zig", &.{
        .{ .name = "vera", .module = vera },
        .{ .name = "exe", .module = byName(mods, "exe") },
        .{ .name = "zigbuild", .module = byName(mods, "zigbuild") },
    });
    const runners_exe = b.addExecutable(.{ .name = "vera-runners", .root_module = runners_mod });
    all_step.dependOn(&runners_exe.step);
    check.dependOn(&b.addExecutable(.{ .name = "check", .root_module = runners_mod, .use_llvm = false }).step);
    const runners = b.addRunArtifact(runners_exe);
    _ = runners.addOutputDirectoryArg("runners");
    runners.addFileArg2(b.path("lib/contract.zig"), .{ .make_absolute = true });
    runners.addDirectoryArg2(b.path("tests/conformance/tests/include"), .{ .make_absolute = true });
    for ([_][2][]const u8{
        .{ "fixed", "verilog-a/ch04_expressions/multiply.va" },
        .{ "mixed", "verilog-ams/ch07_mixed_signal/continuous_variable_read_from_digital.va" },
        .{ "mixed_d2a", "verilog-ams/ch07_mixed_signal/explicit_d2a_reads_post_active.va" },
        .{ "vpi", "verilog-ams/ch12_vpi_routines/dc_divider.va" },
    }) |row| {
        runners.addArg(row[0]);
        runners.addFileArg2(b.path(b.fmt("tests/conformance/tests/{s}", .{row[1]})), .{ .make_absolute = true });
    }
    // The runners import the contract and `sim` trees at their build.
    for (globFiles(b, "lib", "")) |f| runners.addFileInput(b.path(f));
    runners.setEnvironmentVariable("VERA_RUNNERS_ZIG", b.graph.zig_exe);
    runners.setEnvironmentVariable("VERA_RUNNERS_CACHE", b.fmt("{s}/zig-cache", .{checkoutWorkDir(b, "vera-runners")}));
    runners.expectExitCode(0);
    test_step.dependOn(&runners.step);
    b.step("test-runners", "Compile one emitted runner per template variant (tests/runners.zig) only").dependOn(&runners.step);

    const canary = b.addRunArtifact(suite_exe);
    canary.addArtifactArg2(exe, .{});
    canary.addArg("canary");
    canary.expectExitCode(0);
    canary.has_side_effects = true;
    test_step.dependOn(&canary.step);
}
