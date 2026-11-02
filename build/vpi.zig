//! The VPI library and its applications: `libvera-vpi.a` (`library`), the
//! acceptance application, the negative-input, escaped-name and memory
//! tables, and one run per `.c` fixture with a `//! design`. `build.zig`
//! builds the library with `library` and calls `add` once.
//!
//! Contents:
//! - `pub fn library(b: *Build, m: M, mods: []const Import, vera: *Module, sim: *Module, dynlib: *Module) *Build.Step.Compile`
//! - `pub fn add(g: Graph, vpi_host: *Build.Step.Compile) void`

const std = @import("std");
const common = @import("common.zig");
const Build = std.Build;
const Module = Build.Module;
const Import = Module.Import;
const Run = Build.Step.Run;
const M = common.M;
const Graph = common.Graph;
const byName = common.byName;
const simSources = common.simSources;
const configText = common.configText;
const globFiles = common.globFiles;
const pathFromRoot = common.pathFromRoot;
const checkoutWorkDir = common.checkoutWorkDir;
const recordResults = common.recordResults;

/// A `.c` fixture with `//! design` (relative to the `.c`), plus its `//! stdout|stderr|xfail` lines;
/// `//! exit 1` is a refusal, whose message is the `.expected.stderr.txt` beside it;
/// `//@ protect-keys F` (relative to the `.c`) reaches the host as `$VERA_PROTECT_KEYS`.
const VpiRun = struct {
    c: []const u8,
    design: []const u8 = "",
    protect_keys: ?[]const u8 = null,
    stdout: []const u8 = "",
    stderr: ?[]const u8 = null,
    xfail: ?[]const u8 = null,
    refuse: ?[]const u8 = null,
};

/// `libvera-vpi.a` (src/vpi/host.zig): the simulator a VPI application links
/// against, its `main` included.
pub fn library(b: *Build, m: M, mods: []const Import, vera: *Module, sim: *Module, dynlib: *Module) *Build.Step.Compile {
    const mod = m.make("src/vpi/host.zig", &.{
        .{ .name = "vera", .module = vera },
        .{ .name = "frontend", .module = byName(mods, "frontend") },
        .{ .name = "exe", .module = byName(mods, "exe") },
        .{ .name = "zigbuild", .module = byName(mods, "zigbuild") },
        .{ .name = "vpi", .module = byName(mods, "vpi") },
        .{ .name = "sim", .module = sim },
        .{ .name = "dynlib", .module = dynlib },
    });
    mod.link_libc = true;
    // The contract the device is built against: `lib/contract.zig` and `lib/contract/`.
    mod.addImport("sim_sources", simSources(b));
    return b.addLibrary(.{ .name = "vera-vpi", .linkage = .static, .root_module = mod });
}

pub fn add(g: Graph, vpi_host: *Build.Step.Compile) void {
    const b = g.b;
    const target = g.m.target;
    const optimize = g.m.optimize;
    const test_step = g.test_step;
    const all_step = g.all_step;
    const results_dir = g.results_dir;

    all_step.dependOn(&vpi_host.step);
    const vpi_app = vpiApp(b, target, optimize, vpi_host, "tests/conformance/tests/verilog-ams/ch11_vpi/vpi_app.c");
    vpi_app.addFileArg(b.path("tests/conformance/tests/verilog-ams/ch11_vpi/vpi_design.va"));
    vpi_app.expectExitCode(0);
    vpi_app.expectStdOutEqual("vpi: scopes=5 ports=11 nets=6 regs=2 params=8 checks=702\n");
    test_step.dependOn(&vpi_app.step);
    if (results_dir) |dir| {
        // This acceptance application contains named expected failures as
        // well as ordinary checks. Its XPASS guards make a resolved gap fail
        // until the expectation is updated. Record each named check.
        var rows: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, configText(b, "tests/conformance/tests/verilog-ams/ch11_vpi/vpi_app.c"), '\n');
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
    }
    // The negative-input table: every exported vpi_* entry point handed each
    // invalid argument it takes must return its failure value with an error
    // vpi_chk_error reports. The app prints a row per case and judges itself.
    const negative = vpiApp(b, target, optimize, vpi_host, "tests/vpi_negative/negative.c");
    negative.addFileArg2(b.path("tests/vpi_negative/negative.v"), .{ .make_absolute = true });
    negative.setCwd(b.tmpPath());
    negative.expectExitCode(0);
    negative.expectStdOutMatch("vpi-negative=ok\n");
    test_step.dependOn(&negative.step);
    b.step("test-vpi-negative", "Run the VPI negative-input table (tests/vpi_negative) only").dependOn(&negative.step);
    // Escaped identifiers through vpi_handle_by_name: each object's
    // vpiFullName must name that object again.
    const escaped = vpiApp(b, target, optimize, vpi_host, "tests/vpi_escaped/roundtrip.c");
    escaped.addFileArg2(b.path("tests/vpi_escaped/escaped.v"), .{ .make_absolute = true });
    escaped.setCwd(b.tmpPath());
    escaped.expectExitCode(0);
    escaped.expectStdOutMatch("vpi-escaped=ok objects=32 ");
    test_step.dependOn(&escaped.step);
    b.step("test-vpi-escaped", "Run the escaped-identifier vpi_handle_by_name round trip (tests/vpi_escaped) only").dependOn(&escaped.step);
    // The VPI analog library's runner sizes a device's arrays as `vera
    // --emit-exe`'s does: `tbl`'s 4096 reals are 32768 bytes (the .va's header,
    // by hand). Read from the library's own runner, which nothing at run time
    // prints.
    const mem_app = vpiApp(b, target, optimize, vpi_host, "tests/vpi_mem/memory_array_library.c");
    mem_app.addFileArg2(b.path("tests/vpi_mem/memory_array_library.va"), .{ .make_absolute = true });
    mem_app.addFileArg2(b.path("tests/vpi_mem/memory_array_library.c"), .{ .make_absolute = true });
    mem_app.setCwd(b.tmpPath());
    mem_app.expectExitCode(0);
    const mem_bytes = b.addSystemCommand(&.{
        "sh", "-c",
        \\f="$1/memory_array_library/memory_array_library.tb.zig"
        \\grep -F 'const mem_bytes: usize = 32768;' "$f" || { echo "$f does not size tbl as 32768 bytes:" >&2; grep -F mem_bytes "$f" >&2; exit 1; }
        ,
        "sh", checkoutWorkDir(b, "vera-vpi"),
    });
    mem_bytes.step.dependOn(&mem_app.step);
    mem_bytes.has_side_effects = true; // reads the library's work tree
    mem_bytes.expectExitCode(0);
    test_step.dependOn(&mem_bytes.step);
    b.step("test-vpi-mem", "Check the VPI analog library's runner sizes a memory-backed array (tests/vpi_mem) only").dependOn(&mem_bytes.step);
    for (vpiRuns(b)) |f| {
        const r = vpiApp(b, target, optimize, vpi_host, f.c);
        // Each run gets its own cwd: an application writes fixed names there
        // (`b_27_mcd_a.log`), and worktrees share one symlinked .zig-cache, so a
        // shared cwd lets concurrent runs overwrite each other's files. The
        // inputs are absolute to match.
        r.addFileArg2(b.path(f.design), .{ .make_absolute = true });
        if (std.mem.endsWith(u8, f.design, ".va")) r.addFileArg2(b.path(f.c), .{ .make_absolute = true });
        r.setCwd(b.tmpPath());
        if (f.protect_keys) |k| r.setEnvironmentVariable("VERA_PROTECT_KEYS", pathFromRoot(b, k));
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
        // The same run with stdout a file, as conform runs it: the application's
        // printf and the host's writer share one offset only if both stream.
        if (f.xfail == null and f.refuse == null and !std.mem.endsWith(u8, f.design, ".va")) {
            const filed = b.addSystemCommand(&.{ "sh", "-c", "\"$1\" \"$2\" > \"$3\" && cat \"$3\"", "sh" });
            filed.addArtifactArg2(r.producer.?, .{ .make_absolute = true });
            filed.addFileArg2(b.path(f.design), .{ .make_absolute = true });
            _ = filed.addOutputFileArg2(b.fmt("{s}.stdout", .{std.fs.path.stem(f.c)}), .{});
            filed.setCwd(b.tmpPath());
            filed.setEnvironmentVariable("VERA_ZIG", b.graph.zig_exe);
            if (f.protect_keys) |k| filed.setEnvironmentVariable("VERA_PROTECT_KEYS", pathFromRoot(b, k));
            filed.expectExitCode(0);
            filed.expectStdOutEqual(f.stdout);
            test_step.dependOn(&filed.step);
        }
        if (results_dir) |dir| {
            // A marker can only be written after the application's exit,
            // stdout and stderr checks succeed. Missing markers earn no credit.
            const slug = b.allocator.dupe(u8, f.c["tests/conformance/tests/".len .. f.c.len - 2]) catch @panic("OOM");
            std.mem.replaceScalar(u8, slug, '/', '_');
            const name = b.fmt("vpi--{s}.tsv", .{slug});
            const record = recordResults(b, r, dir, name, b.fmt("{s}\t{s}\n", .{
                if (f.xfail != null) "xfail" else "pass",
                f.c["tests/conformance/tests/".len..],
            }));
            test_step.dependOn(record);
        }
    }
}

// ---- private ----

fn vpiApp(b: *Build, target: Build.ResolvedTarget, optimize: std.lang.Optimize, host: *Build.Step.Compile, c: []const u8) *Run {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addCSourceFile(.{ .file = b.path(c), .flags = &.{ "-std=c99", "-Wall", "-Werror" } });
    mod.addIncludePath(b.path("src/vpi"));
    mod.addIncludePath(b.path(std.fs.path.dirname(c).?));
    mod.linkLibrary(host);
    const app = b.addExecutable(.{ .name = b.fmt("vpi-{s}", .{std.fs.path.stem(c)}), .root_module = mod });
    b.top_level_steps.get("build-all").?.step.dependOn(&app.step);
    const run = b.addRunArtifact(app);
    run.setEnvironmentVariable("VERA_ZIG", b.graph.zig_exe);
    run.setEnvironmentVariable("VERA_VPI_WORK", checkoutWorkDir(b, "vera-vpi"));
    return run;
}

fn vpiRuns(b: *Build) []const VpiRun {
    var runs: std.ArrayList(VpiRun) = .empty;
    for (globFiles(b, "tests/conformance/tests", ".c")) |c| {
        var r: VpiRun = .{ .c = c };
        var out: std.ArrayList(u8) = .empty;
        var err: ?std.ArrayList(u8) = null;
        var lines = std.mem.splitScalar(u8, configText(b, c), '\n');
        while (lines.next()) |raw| {
            if (std.mem.cutPrefix(u8, std.mem.trimEnd(u8, raw, "\r"), "//@ protect-keys ")) |k| {
                r.protect_keys = b.fmt("{s}/{s}", .{ std.fs.path.dirnamePosix(c).?, k });
                continue;
            }
            const line = std.mem.cutPrefix(u8, std.mem.trimEnd(u8, raw, "\r"), "//! ") orelse continue;
            const key, const val = std.mem.cutScalar(u8, line, ' ') orelse .{ line, "" };
            if (std.mem.eql(u8, key, "design")) {
                r.design = b.fmt("{s}/{s}", .{ std.fs.path.dirnamePosix(c).?, val });
            } else if (std.mem.eql(u8, key, "stdout")) {
                out.print(b.allocator, "{s}\n", .{val}) catch @panic("OOM");
            } else if (std.mem.eql(u8, key, "stderr")) {
                if (err == null) err = .empty;
                if (val.len != 0) err.?.print(b.allocator, "{s}\n", .{val}) catch @panic("OOM");
            } else if (std.mem.eql(u8, key, "xfail")) {
                r.xfail = val;
            } else if (std.mem.eql(u8, key, "exit")) {
                if (!std.mem.eql(u8, val, "1")) @panic(b.fmt("{s}: only `//! exit 1` (a refusal) is supported", .{c}));
                r.refuse = configText(b, b.fmt("{s}.expected.stderr.txt", .{c[0 .. c.len - 2]}));
            }
        }
        if (r.design.len == 0) continue;
        r.stdout = out.items;
        if (err) |e| r.stderr = e.items;
        runs.append(b.allocator, r) catch @panic("OOM");
    }
    return runs.items;
}
