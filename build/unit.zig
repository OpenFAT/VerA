//! The merge tier's compiled tests: every module's tests (`test-<module>`),
//! the CLI's, the cross-module claims (`test-unit`), the references, the
//! codegen probe, the generators and the fixture runner's own tests, and
//! the pre-commit `check` step that type-checks every root. `build.zig`
//! calls `add` once.
//!
//! Contents:
//! - `pub const Added = struct { suite_exe, check }`
//! - `pub fn add(g: Graph, ams: bool) Added`

const std = @import("std");
const common = @import("common.zig");
const Build = std.Build;
const Module = Build.Module;
const Import = Module.Import;
const Run = Build.Step.Run;
const Graph = common.Graph;
const byName = common.byName;
const globFiles = common.globFiles;
const pathFromRoot = common.pathFromRoot;
const checkoutWorkDir = common.checkoutWorkDir;
const testRun = common.testRun;
const testRoot = common.testRoot;
const cliExe = common.cliExe;
const defineModules = common.defineModules;

/// What later phases build on: the fixture runner and the `check` step.
pub const Added = struct { suite_exe: *Build.Step.Compile, check: *Build.Step };

pub fn add(g: Graph, ams: bool) Added {
    const b = g.b;
    const m = g.m;
    const target = g.m.target;
    const optimize = g.m.optimize;
    const mods = g.mods;
    const exe = g.exe;
    const test_step = g.test_step;
    const all_step = g.all_step;
    const runner = g.runner;
    const results_dir = g.results_dir;
    const contract = byName(g.mods, "contract");
    const kernels = byName(g.mods, "kernels");
    const vera = byName(g.mods, "vera");
    const sim = byName(g.mods, "sim");

    const fmt = b.addFmt(.{ .paths = b.pathList(&.{ "lib", "src", "tests", "tools", "build.zig", "build" }), .check = true });
    test_step.dependOn(&fmt.step);

    for (mods) |mod| {
        const r = testRun(b, mod.name, testRoot(b, mod), runner, results_dir);
        test_step.dependOn(&r.step);
        b.step(b.fmt("test-{s}", .{mod.name}), b.fmt("Run the {s} module tests only", .{mod.name})).dependOn(&r.step);
    }
    test_step.dependOn(&exe.step);
    const cli_run = testRun(b, "cli", exe.root_module, runner, results_dir);
    // src/cli/lsp.zig's tests walk tests/conformance/tests; globFiles re-runs configure, so a new fixture counts.
    for (globFiles(b, "tests/conformance/tests", "")) |f| cli_run.addFileInput(b.path(f));
    test_step.dependOn(&cli_run.step);
    b.step("test-cli", "Run the CLI's tests (src/main.zig, src/cli/) only").dependOn(&cli_run.step);

    const osdi_mod = m.make("lib/osdi_dyn.zig", &.{.{ .name = "contract", .module = contract }});
    test_step.dependOn(&testRun(b, "osdi_dyn", osdi_mod, runner, results_dir).step);
    // zrunner cannot be its own runner's root: stock runner.
    const zrunner_test = b.addTest(.{ .name = "zrunner", .root_module = m.make("tools/zrunner.zig", &.{}) });
    all_step.dependOn(&zrunner_test.step);
    test_step.dependOn(&b.addRunArtifact(zrunner_test).step);
    const other_exe = cliExe(b, target, optimize, mods, if (ams) "vera-verilog" else "vera-ams", !ams);
    test_step.dependOn(&other_exe.step);
    all_step.dependOn(&other_exe.step);

    const all_mod = m.make("tests/unit.zig", mods);
    const repo = b.addOptions();
    repo.addOption([]const u8, "repo_root", pathFromRoot(b, "."));
    all_mod.addOptions("repo_options", repo);
    const all_run = testRun(b, "test_all", all_mod, runner, results_dir);
    // Reads the tree at test time: every file it can reach is an input, so a
    // no-op build reuses the result (globFiles re-runs configure for new files).
    for ([_][]const u8{ "lib", "src", "tools", "tests", "docs" }) |dir| {
        for (globFiles(b, dir, "")) |f| all_run.addFileInput(b.path(f));
    }
    all_run.addFileInput(b.path("build.zig"));
    all_run.addFileInput(b.path("build.zig.zon"));
    test_step.dependOn(&all_run.step);
    b.step("test-unit", "Run tests/unit.zig, the cross-module claims, only").dependOn(&all_run.step);

    // LLVM: the self-hosted backend emits no coverage, so the fuzzer sees no PCs.
    const fuzz_test = b.addTest(.{ .name = "fuzz", .root_module = m.make("tests/fuzz.zig", &.{ .{ .name = "vera", .module = vera }, .{ .name = "exe", .module = byName(mods, "exe") }, .{ .name = "sim", .module = sim } }), .use_llvm = true });
    b.step("fuzz", "The in-process fuzz targets on the stock runner (`zig build fuzz --fuzz[=N]`: coverage-guided)").dependOn(&b.addRunArtifact(fuzz_test).step);

    const rng_ref = m.make("tests/rng_reference.zig", &.{.{ .name = "kernels", .module = kernels }});
    rng_ref.link_libc = true;
    rng_ref.addCSourceFile(.{ .file = b.path("tests/rng_reference.c"), .flags = &.{"-ffp-contract=off"} });
    const rng_run = testRun(b, "rng_reference", rng_ref, runner, results_dir);
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
        test_step.dependOn(&r.step);
    }
    const probe = codegenProbe(b);
    test_step.dependOn(&probe.step);
    b.step("test-probe", "Hold tests/codegen_probe.zig's x86_64_v3 assembly to its `expect:` lines (tools/asm_probe.py)").dependOn(&probe.step);
    // ReleaseSafe: 10^5 exact expansions take minutes in Debug. glibc: the oracle must conform.
    if (target.result.isGnuLibC()) {
        const printf_ref = b.createModule(.{
            .root_source_file = b.path("tests/printf_reference.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .imports = &.{.{ .name = "kernels", .module = kernels }},
        });
        test_step.dependOn(&testRun(b, "printf_reference", printf_ref, runner, results_dir).step);
    }

    const o = b.addOptions();
    o.addOption([]const u8, "fixture_root", pathFromRoot(b, "tests/conformance/tests"));
    o.addOption([]const u8, "repo_root", pathFromRoot(b, "."));
    o.addOption([]const u8, "work_root", checkoutWorkDir(b, "vera-suite"));
    o.addOption([]const u8, "contract", pathFromRoot(b, "lib/contract.zig"));
    o.addOption([]const u8, "vpi_include", pathFromRoot(b, "src/vpi"));
    o.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    const suite_mod = m.make("tests/suite.zig", &.{
        .{ .name = "vera", .module = vera },
        .{ .name = "frontend", .module = byName(mods, "frontend") },
        .{ .name = "exe", .module = byName(mods, "exe") },
        .{ .name = "zigbuild", .module = byName(mods, "zigbuild") },
        .{ .name = "sim", .module = sim },
        .{ .name = "digital", .module = byName(mods, "digital") },
    });
    suite_mod.addOptions("suite_options", o);
    const suite_exe = b.addExecutable(.{ .name = "vera-suite", .root_module = suite_mod });
    // Generated inputs through every pass (tests/generators.zig).
    const gen_mod = m.make("tests/generators.zig", &.{
        .{ .name = "vera", .module = vera },
        .{ .name = "zigbuild", .module = byName(mods, "zigbuild") },
        .{ .name = "sim", .module = sim },
        .{ .name = "digital", .module = byName(mods, "digital") },
    });
    const gen_tests = testRun(b, "generators", gen_mod, runner, results_dir);
    test_step.dependOn(&gen_tests.step);
    const generators = b.addExecutable(.{ .name = "vera-generators", .root_module = gen_mod });
    all_step.dependOn(&generators.step);
    const gen_run = b.addRunArtifact(generators);
    _ = gen_run.addOutputDirectoryArg("generators");
    gen_run.expectExitCode(0);
    test_step.dependOn(&gen_run.step);
    const gen_step = b.step("test-generators", "Run the generated-input tables and tests (tests/generators.zig) only");
    gen_step.dependOn(&gen_run.step);
    gen_step.dependOn(&gen_tests.step);
    all_step.dependOn(&suite_exe.step);
    const suite_run = testRun(b, "suite", suite_mod, runner, results_dir);
    suite_run.has_side_effects = true; // reads tests/conformance at test time
    test_step.dependOn(&suite_run.step);
    b.step("test-suite", "Run the fixture runner's own tests (tests/suite.zig) only").dependOn(&suite_run.step);

    const check = b.step("check", "The pre-commit tier: type-check every root without emitting a binary, and `zig fmt --check` (`--watch -fincremental`: the edit loop)");
    check.dependOn(&fmt.step);
    for ([_]*Module{ exe.root_module, other_exe.root_module, suite_mod }) |r| {
        check.dependOn(&b.addExecutable(.{ .name = "check", .root_module = r, .use_llvm = false }).step);
    }
    for (mods) |mod| check.dependOn(&b.addTest(.{ .name = "check", .root_module = testRoot(b, mod), .test_runner = runner, .use_llvm = false }).step);
    for ([_]*Module{ exe.root_module, osdi_mod, all_mod, suite_mod, gen_mod }) |r| {
        check.dependOn(&b.addTest(.{ .name = "check", .root_module = r, .test_runner = runner, .use_llvm = false }).step);
    }
    return .{ .suite_exe = suite_exe, .check = check };
}

// ---- private ----

/// A run of the generating vera on `src` (build-root relative). Cached, vera
/// runs from a fixed copy under zig-out/gen named by a plain string, so the Run's
/// hash covers the arguments, `src`'s contents and its `include`s but not
/// vera's binary: a compiler edit leaves every generated device, and every
/// object built from it, cached. Rebuild them after a codegen change with
/// `-Dva-cache=false`.
/// `tests/codegen_probe.zig` as x86_64_v3 ReleaseFast assembly, judged by
/// `tools/asm_probe.py` against the file's `expect:` lines (after its
/// selftest: a judge that passes everything proves nothing). The target is
/// fixed, so every host checks the same instructions.
fn codegenProbe(b: *Build) *Run {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 } });
    const mods = defineModules(b, target, false);
    const obj = b.addObject(.{ .name = "codegen_probe", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/codegen_probe.zig"),
        .target = target,
        .optimize = .fast,
        .strip = true,
        .imports = &.{.{ .name = "kernels", .module = byName(mods, "kernels") }},
    }) });
    const selftest = b.addSystemCommand(&.{"python3"});
    selftest.addFileArg(b.path("tools/asm_probe.py"));
    selftest.addArg("selftest");
    selftest.expectExitCode(0);
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("tools/asm_probe.py"));
    run.addFileArg(b.path("tests/codegen_probe.zig"));
    run.addFileArg(obj.getEmittedAsm());
    run.expectExitCode(0);
    run.step.dependOn(&selftest.step);
    return run;
}
