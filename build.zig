//! VerA's build graph: `module_specs` -> the `vera` executable and the steps
//! that check and test it (`check`, `test`, `suite`, `test-<module>`,
//! `conformance`, `fuzz`, ...; `TESTING.md` maps them to tiers). This file
//! is the spine: the options, the modules, `vera` and its install, then
//! each phase under `build/` in turn. Clauses: none (build wiring).
//!
//! Contents:
//! - `pub fn build(b: *Build) void`

const std = @import("std");
const common = @import("build/common.zig");
const devices = @import("build/devices.zig");
const external = @import("build/external.zig");
const runs = @import("build/runs.zig");
const unit = @import("build/unit.zig");
const vpi = @import("build/vpi.zig");
const Build = std.Build;
const M = common.M;
const byName = common.byName;
const cliExe = common.cliExe;
const defineModules = common.defineModules;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    // Not standardOptimizeOption: it returns Optimize on 0.17 and ?Optimize on 0.18.
    const optimize = b.option(std.lang.Optimize, "optimize", "Prioritize performance, safety, or binary size") orelse .debug;
    const m: M = .{ .b = b, .target = target, .optimize = optimize };
    const results_dir = b.option([]const u8, "test-results", "Write executed unit, host and VPI test results to this directory");
    const espice_path = b.option([]const u8, "espice", "test-spice: the espice executable to run the decks on (an ESPice release, a nix profile, a local `zig build` of ../ESPice, CPU or GPU)");
    const mods = defineModules(b, target, true);
    const vera = byName(mods, "vera");
    const sim = byName(mods, "sim");
    const dynlib = byName(mods, "dynlib");

    const Language = enum { verilog, ams };
    const language = b.option(Language, "language", "verilog: an IEEE 1364-2005 `vera` without the analog backend; ams (default): the Verilog-AMS compiler") orelse .ams;
    const exe = cliExe(b, target, optimize, mods, "vera", language == .ams);
    b.installArtifact(exe);
    b.installFile("lib/contract.zig", "share/vera/contract.zig");
    // The contract root imports its files from `contract/` beside it.
    b.installDirectory(.{ .source_dir = b.path("lib/contract"), .install_dir = .prefix, .install_subdir = "share/vera/contract" });
    // The VPI simulator a C application links (src/vpi/host.zig), where
    // `zig cc` finds it: `-I<prefix>/include <prefix>/lib/libvera-vpi.a`.
    const vpi_host = vpi.library(b, m, mods, vera, sim, dynlib);
    if (target.result.os.tag != .wasi) {
        b.installArtifact(vpi_host);
        b.installFile("src/vpi/vpi_user.h", "include/vpi_user.h");
    }

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
        \\mkdir -p zig-out && VERA="$1" VERA_VPI_LIB="$2" VERA_VPI_INCLUDE="$3" conform -t tests/conformance/tools/vera.conf -x tools/vera.xfail -j "${CONFORM_JOBS:-$(nproc)}" -T 300 \
        \\  -o zig-out/conformance.tsv tests/conformance/tests tests/conformance/external/*.manifest
        ,
        "sh",
    });
    conformance.addArtifactArg2(exe, .{ .make_absolute = true });
    // `$2`, `$3`: the `libvera-vpi.a` and `vpi_user.h` directory the `.c`
    // applications build against (vera.conf's `compile.vpi`).
    conformance.addArtifactArg2(vpi_host, .{ .make_absolute = true });
    conformance.addDirectoryArg2(b.path("src/vpi"), .{ .make_absolute = true });
    conformance.has_side_effects = true;
    b.step("conformance", "Run the conformance suite (tests/conformance) against the installed vera").dependOn(&conformance.step);

    const test_step = b.step("test", "The merge tier's fast part: unit, host, reference and harness tests (the fixtures: `suite -- ams`, `suite -- devices`)");
    const all_step = b.step("build-all", "Compile every artifact for -Dtarget without running one");
    all_step.dependOn(&exe.step);
    const gen_exe = if (target.query.isNative()) exe else cliExe(b, b.graph.host, optimize, defineModules(b, b.graph.host, false), "vera-gen", true);
    // One copy for every generating run: a copy per run rewrote the binary
    // while another run executed it (ETXTBSY, FileBusy).
    const gen_copy = b.addUpdateSourceFiles();
    gen_copy.addCopyFileToSource(gen_exe.getEmittedBin(), b.fmt("zig-out/gen/{s}", .{gen_exe.out_filename}));
    const va_gen: devices.Gen = .{ .exe = gen_exe, .copy = gen_copy, .cached = b.option(bool, "va-cache", "Regenerate a test device's Zig only when its source, its `include`s or its arguments change, not when vera does (default true; false: every vera change regenerates)") orelse true };

    const runner: Build.Step.Compile.TestRunner = .{ .path = b.path("tools/zrunner.zig"), .mode = .simple };
    const g: common.Graph = .{ .b = b, .m = m, .mods = mods, .exe = exe, .test_step = test_step, .all_step = all_step, .runner = runner, .results_dir = results_dir };

    const added = unit.add(g, language == .ams);
    runs.add(g, added.suite_exe, added.check, espice_path);
    vpi.add(g, vpi_host);
    if (language != .ams) return;
    devices.add(g, va_gen);
    external.add(g);
}
