//! The contract devices: each `tests/host/*_host.zig` against the devices
//! its `//! device` lines name (and its GPU twin's kernels), the `.v`
//! devices' hosts, and the refusals and warnings of `--emit-zig`,
//! `--emit-osdi`, `--run` and `--emit-exe`. Analog builds only; `build.zig`
//! calls `add` once.
//!
//! Contents:
//! - `pub const Gen = struct { exe, copy, cached }`
//! - `pub fn add(g: Graph, va_gen: Gen) void`

const std = @import("std");
const common = @import("common.zig");
const Build = std.Build;
const Module = Build.Module;
const Import = Module.Import;
const Run = Build.Step.Run;
const Graph = common.Graph;
const byName = common.byName;
const configText = common.configText;
const globFiles = common.globFiles;
const testRun = common.testRun;

/// The vera that generates test devices, and whether its runs are keyed on
/// their inputs alone (`-Dva-cache`).
pub const Gen = struct { exe: *Build.Step.Compile, copy: *Build.Step.UpdateSourceFiles, cached: bool };

/// Every `tests/host/*_host.zig`, once per `//! device <path>` line: a path
/// under `tests/conformance`, or `tests/host/...` for a device only VerA's
/// host judges (the suite holds only tests any tool can be judged on). A
/// `//! display emit` line builds the devices `--display=emit`.
const HostTest = struct { host: []const u8, va: []const u8, emit: bool };

pub fn add(g: Graph, va_gen: Gen) void {
    const b = g.b;
    const m = g.m;
    const target = g.m.target;
    const optimize = g.m.optimize;
    const exe = g.exe;
    const test_step = g.test_step;
    const runner = g.runner;
    const results_dir = g.results_dir;
    const contract = byName(g.mods, "contract");
    const sim = byName(g.mods, "sim");
    const dynlib = byName(g.mods, "dynlib");

    for (hostTests(b)) |h| {
        const gen = genRun(b, va_gen, h.va);
        gen.addArg("--emit-zig");
        if (h.emit) gen.addArg("--display=emit");
        gen.addArg("-I"); // its directory is the next argument
        gen.addDirectoryArg2(b.path("tests/conformance/tests/include"), .{});
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

        // `<x>_gpu.zig` must export `<x>_ops_kernel`. NVPTX goes to LLVM IR, since the
        // backend refuses an @export alias of a kernel; ptx hosts check its PTX.
        const stem = h.host[0 .. h.host.len - "_host.zig".len];
        const gpu_src = b.fmt("{s}_gpu.zig", .{stem});
        b.root.root_dir.handle.access(b.graph.io, gpu_src, .{}) catch continue;
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
            const out = if (!nvptx) obj.getEmittedBin() else if (ptx_opts != null) obj.getEmittedAsm() else obj.getEmittedLlvmIr();
            if (nvptx) if (ptx_opts) |po| po.addOptionPath("path", out);
            test_step.dependOn(&b.addCheckFile(out, .{ .expected_matches = &.{b.fmt("{s}_ops_kernel", .{std.fs.path.basename(stem)})} }).step);
        }
    }

    const vdev_host = m.make("tests/host/vdev_host.zig", &.{.{ .name = "contract", .module = contract }});
    const so_opts = b.addOptions();
    const vdev_so_host = m.make("tests/host/vdev_so_host.zig", &.{
        .{ .name = "vdev_dyn", .module = b.createModule(.{ .root_source_file = b.path("tests/host/vdev_dyn.zig"), .imports = &.{.{ .name = "contract", .module = contract }} }) },
        .{ .name = "vdev_so_options", .module = so_opts.createModule() },
        .{ .name = "dynlib", .module = dynlib },
    });
    vdev_so_host.link_libc = true;
    for ([_][]const u8{ "v_inv", "v_buf", "v_count", "v_a2d", "v_edge", "v_any", "v_wide", "v_huge", "v_say" }) |name| {
        const src_path = b.fmt("tests/conformance/tests/verilog-ams/ch07_mixed_signal/{s}.v", .{name});
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
        for (globFiles(b, "lib/contract", ".zig")) |f| so.addFileInput(b.path(f));
        so.addArg("--dyn");
        so.addFileArg(b.path("tests/host/vdev_dyn.zig"));
        so.addArg("--work-dir");
        const wd = so.addOutputDirectoryArg2(name, .{});
        so.addFileArg(src);
        const host = &b.graph.host.result;
        so_opts.addOptionPath(name, wd.path(b, b.fmt("{s}{s}.1{s}", .{ host.libPrefix(), name, host.dynamicLibSuffix() })));
    }
    test_step.dependOn(&testRun(b, "vdev_host", vdev_host, runner, results_dir).step);
    test_step.dependOn(&testRun(b, "vdev_so_host", vdev_so_host, runner, results_dir).step);

    for ([_]struct { []const []const u8, []const u8, u8, []const u8 }{
        .{ &.{"--emit-zig"}, "verilog-ams/ch07_mixed_signal/v_inout.v", 1, "error[E1103]: design cannot be a contract device: module `v_inout`: an inout port" },
        .{ &.{"--emit-zig"}, "verilog-ams/ch07_mixed_signal/v_integer.v", 1, "error[E1103]: design cannot be a contract device: module `v_integer`: an integer or time port" },
        .{ &.{"--emit-zig"}, "verilog-ams/ch07_mixed_signal/v_pins.v", 1, "error[E1103]: design cannot be a contract device: module `v_pins`: more than 65535 pins" },
        .{ &.{"--emit-zig"}, "verilog-ams/ch07_mixed_signal/v_tran.v", 1, "error[E1103]: design cannot be a contract device: module `v_tran`: a §7.6 pass switch" },
        .{ &.{ "--emit-zig", "--state=auto" }, "verilog-ams/ch07_mixed_signal/v_inv.v", 1, "error[E1103]: design cannot be a contract device: a contract device is 4-state: --state=auto" },
        .{ &.{"--emit-zig"}, "verilog-ams/ch07_mixed_signal/v_sv.sv", 2, "error[E1104]: a SystemVerilog source is not supported" },
        .{ &.{"--emit-zig"}, "verilog-ams/ch07_mixed_signal/v_seconds.v", 0, "warning[W1155]: device digital tick is 1 s" },
    }) |r| {
        const run = b.addRunArtifact(exe);
        run.addArgs(r[0]);
        run.addFileArg(b.path(b.fmt("tests/conformance/tests/{s}", .{r[1]})));
        run.expectExitCode(r[2]);
        run.addCheck(.{ .expect_stderr_match = r[3] });
        test_step.dependOn(&run.step);
    }

    for ([_]struct { []const u8, u8, []const u8 }{
        .{ "verilog-a/ch05_analog_behavior/vera_reject_step_retry.va", 1, "error[E1099]" },
        .{ "verilog-a/ch04_expressions/noise_anticorrelated_coefficient.va", 0, "warning[W1098]" },
        .{ "verilog-ams/ch07_mixed_signal/v_seconds.v", 0, "warning[W1155]" },
        .{ "verilog-a/ch03_data_types/module_without_parameters.va", 0, "" },
    }) |r| {
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ "--emit-osdi", "-I" });
        run.addDirectoryArg2(b.path("tests/conformance/tests/include"), .{});
        run.addArg("--work-dir");
        _ = run.addOutputDirectoryArg2("osdi", .{});
        if (r[1] == 0) {
            run.addArg("-o");
            _ = run.addOutputFileArg2("device.osdi", .{});
        }
        run.addFileArg(b.path(b.fmt("tests/conformance/tests/{s}", .{r[0]})));
        run.expectExitCode(r[1]);
        run.addCheck(.{ .expect_stderr_match = r[2] });
        test_step.dependOn(&run.step);
    }

    for ([_][]const u8{ "--run", "--emit-exe" }) |mode| for ([_][]const u8{ "allow", "warn", "deny", "forbid" }) |level| {
        const rejected = std.mem.eql(u8, level, "deny") or std.mem.eql(u8, level, "forbid");
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ mode, b.fmt("--{s}=W0750", .{level}), "--allow=W0650", "-I" });
        run.addDirectoryArg2(b.path("tests/conformance/tests/include"), .{});
        run.addArg("--work-dir");
        _ = run.addOutputDirectoryArg2("tb", .{});
        run.addFileArg(b.path("tests/conformance/tests/verilog-a/ch05_analog_behavior/event_cross_fires_on_a_time_grid.va"));
        run.expectExitCode(if (rejected) 1 else 0);
        if (rejected) {
            run.expectStdOutEqual("");
            run.addCheck(.{ .expect_stderr_match = "error[W0750]" });
        } else {
            if (std.mem.eql(u8, mode, "--run"))
                run.addCheck(.{ .expect_stderr_match = "one rising clk edge is one event got=          1 want=          1 ok=1" });
            if (std.mem.eql(u8, level, "warn"))
                run.addCheck(.{ .expect_stderr_match = "warning[W0750]" })
            else if (std.mem.eql(u8, mode, "--emit-exe"))
                run.expectStdErrEqual("");
        }
        test_step.dependOn(&run.step);
    };
}

// ---- private ----

fn hostTests(b: *Build) []const HostTest {
    var found: std.ArrayList(HostTest) = .empty;
    for (globFiles(b, "tests/host", "_host.zig")) |host| {
        const emit = std.mem.find(u8, configText(b, host), "\n//! display emit\n") != null;
        var lines = std.mem.splitScalar(u8, configText(b, host), '\n');
        while (lines.next()) |raw| {
            const va = std.mem.cutPrefix(u8, std.mem.trimEnd(u8, raw, "\r"), "//! device ") orelse continue;
            const path = if (std.mem.startsWith(u8, va, "tests/host/")) va else b.fmt("tests/conformance/{s}", .{va});
            found.append(b.allocator, .{ .host = host, .va = path, .emit = emit }) catch @panic("OOM");
        }
    }
    return found.items;
}

fn genRun(b: *Build, gen: Gen, src: []const u8) *Run {
    if (!gen.cached) return b.addRunArtifact(gen.exe);
    const run = b.addSystemCommand(&.{b.fmt("./zig-out/gen/{s}", .{gen.exe.out_filename})});
    run.step.dependOn(&gen.copy.step);
    addIncludes(b, run, src);
    // The device embeds contract.zig's `vera_version` and targets its
    // contract: a release bump or a contract edit regenerates it.
    run.addFileInput(b.path("lib/contract.zig"));
    for (globFiles(b, "lib/contract", ".zig")) |f| run.addFileInput(b.path(f));
    return run;
}

/// Declares every file `src` reaches by `` `include "name" `` as an input of
/// `run`, searched in `src`'s directory then tests/conformance/tests/include (the `-I`).
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
        const dirs = [_][]const u8{ std.fs.path.dirnamePosix(src) orelse ".", "tests/conformance/tests/include" };
        for (dirs) |dir| {
            const path = b.fmt("{s}/{s}", .{ dir, name });
            b.root.root_dir.handle.access(b.graph.io, path, .{}) catch continue;
            run.addFileInput(b.path(path));
            addIncludes(b, run, path);
            break;
        }
    }
}
