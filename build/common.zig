//! What every phase of the build reads: `module_specs` -> the modules
//! (`defineModules`), the `vera` executable (`cliExe`) and its embedded
//! `lib/` tree (`simSources`), the `Graph` the phases share, and the
//! helpers they all call (`testRun`, `globFiles`, ...). Clauses: none
//! (build wiring).
//!
//! Contents:
//! - `pub const module_specs`
//! - `pub const M = struct { b, target, optimize }`, `pub fn M.make(m: M, root: []const u8, imports: []const Import) *Module`
//! - `pub const Graph = struct`
//! - `pub fn defineModules(b: *Build, target: Build.ResolvedTarget, exported: bool) []const Import`
//! - `pub fn cliExe(b: *Build, target: Build.ResolvedTarget, optimize: std.lang.Optimize, mods: []const Import, name: []const u8, ams: bool) *Build.Step.Compile`
//! - `pub fn simSources(b: *Build) *Module`
//! - `pub fn testRoot(b: *Build, mod: Import) *Module`
//! - `pub fn testRun(b: *Build, name: []const u8, mod: *Module, runner: Build.Step.Compile.TestRunner, results_dir: ?[]const u8) *Run`
//! - `pub fn recordResults(b: *Build, run: *Run, dir: []const u8, name: []const u8, contents: []const u8) *Build.Step`
//! - `pub fn globFiles(b: *Build, dir: []const u8, suffix: []const u8) []const []const u8`
//! - `pub fn configText(b: *Build, path: []const u8) []const u8`
//! - `pub fn checkoutWorkDir(b: *Build, name: []const u8) []u8`
//! - `pub fn pathFromRoot(b: *Build, sub_path: []const u8) []u8`
//! - `pub fn byName(mods: []const Import, name: []const u8) *Module`

const std = @import("std");
const Build = std.Build;
const Module = Build.Module;
const Import = Module.Import;
const Run = Build.Step.Run;

/// In dependency order: a module may import only rows above it.
pub const module_specs = [_]struct {
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
    .{ .name = "verilog", .path = "src/codegen/verilog/root.zig", .imports = &.{"ir"} },
    .{ .name = "exe", .path = "src/codegen/exe/root.zig", .imports = &.{ "diag", "frontend", "ir" } },
    .{ .name = "vera", .path = "src/Compilation.zig", .imports = &.{ "base", "diag", "frontend", "elab", "ir", "analog", "prove", "device", "verilog", "exe", "kernels", "zigbuild" } },
    .{ .name = "sim", .path = "lib/sim/root.zig", .imports = &.{ "contract", "base", "diag", "frontend", "kernels" } },
    .{ .name = "digital", .path = "src/codegen/digital/root.zig", .imports = &.{ "sim", "frontend", "diag", "contract", "kernels", "base" } },
    .{ .name = "vpi", .path = "src/vpi/root.zig", .imports = &.{ "frontend", "elab", "ir", "vera", "sim" }, .c = "src/vpi/varargs.c" },
};

pub const M = struct {
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.lang.Optimize,

    pub fn make(m: M, root: []const u8, imports: []const Import) *Module {
        return m.b.createModule(.{ .root_source_file = m.b.path(root), .target = m.target, .optimize = m.optimize, .imports = imports });
    }
};

/// What every phase reads: the build and its mode (`m`), the modules, the
/// `vera` under test, the steps phases add to, and how tests run and report.
pub const Graph = struct {
    b: *Build,
    m: M,
    mods: []const Import,
    exe: *Build.Step.Compile,
    test_step: *Build.Step,
    all_step: *Build.Step,
    runner: Build.Step.Compile.TestRunner,
    results_dir: ?[]const u8,
};

/// `module_specs` as modules, exported with `addModule` when `exported`.
pub fn defineModules(b: *Build, target: Build.ResolvedTarget, exported: bool) []const Import {
    var created: std.ArrayList(Import) = .empty;
    for (module_specs) |spec| {
        const deps = b.allocator.alloc(Import, spec.imports.len) catch @panic("OOM");
        for (deps, spec.imports) |*d, name| d.* = .{ .name = name, .module = byName(created.items, name) };
        const opts: Module.CreateOptions = .{ .root_source_file = b.path(spec.path), .target = target, .imports = deps };
        const mod = if (exported) b.addModule(spec.name, opts) else b.createModule(opts);
        if (std.mem.eql(u8, spec.name, "elab")) {
            mod.addAnonymousImport("resolution_unknown_fixture", .{ .root_source_file = b.path("tests/conformance/tests/verilog-ams/annex_f_resolution/detail_resolution_unknown_after_bottom_up.va") });
            mod.addAnonymousImport("resolution_digital_parent_fixture", .{ .root_source_file = b.path("tests/conformance/tests/verilog-ams/annex_f_resolution/detail_resolution_digital_parent.va") });
        }
        if (spec.c) |c| {
            mod.addCSourceFile(.{ .file = b.path(c), .flags = &.{ "-std=c99", "-Wall", "-Werror" } });
            mod.addIncludePath(b.path(std.fs.path.dirname(c).?));
        }
        created.append(b.allocator, .{ .name = spec.name, .module = mod }) catch @panic("OOM");
    }
    return created.items;
}

pub fn cliExe(b: *Build, target: Build.ResolvedTarget, optimize: std.lang.Optimize, mods: []const Import, name: []const u8, ams: bool) *Build.Step.Compile {
    const o = b.addOptions();
    o.addOption(bool, "ams", ams);
    o.addOption([]const u8, "version", @import("../build.zig.zon").version);
    var imports: std.ArrayList(Import) = .empty;
    for (mods) |m| if (!std.mem.eql(u8, m.name, "vpi")) imports.append(b.allocator, m) catch @panic("OOM");
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .imports = imports.items });
    mod.addOptions("build_options", o);
    mod.addImport("sim_sources", simSources(b));
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

/// `files`: every source under `lib/`, the tree `vera --emit-exe` and
/// `--emit-so` build against: the runtime (`sim`), the contract, the OSDI dyn
/// and the modules they import. `src/main.zig`'s `simTree` writes it out;
/// `src/vpi/host.zig` writes the contract's files beside a VPI device.
pub fn simSources(b: *Build) *Module {
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

/// The root a module's tests compile from: the module, or on Linux, when its
/// tests load a library (it is `dynlib` or imports it), a twin with the same
/// file and imports that links glibc, so `std.DynLib` is `dlopen`
/// (src/dynlib.zig refuses std's ElfDynLib, which applies no relocations).
/// A twin, not the module: `vera` shares the module and links no libc.
pub fn testRoot(b: *Build, mod: Import) *Module {
    const m = mod.module;
    if (m.resolved_target.?.result.os.tag != .linux) return m;
    if (!std.mem.eql(u8, mod.name, "dynlib") and m.import_table.get("dynlib") == null) return m;
    const twin = b.createModule(.{ .root_source_file = m.root_source_file, .target = m.resolved_target, .optimize = m.optimize, .link_libc = true });
    var it = m.import_table.iterator();
    while (it.next()) |e| twin.addImport(e.key_ptr.*, e.value_ptr.*);
    return twin;
}

/// CLICOLOR_FORCE keeps zrunner's report colored under the build's capture.
pub fn testRun(b: *Build, name: []const u8, mod: *Module, runner: Build.Step.Compile.TestRunner, results_dir: ?[]const u8) *Run {
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

/// Publish C application results only after its checked execution succeeds.
pub fn recordResults(b: *Build, run: *Run, dir: []const u8, name: []const u8, contents: []const u8) *Build.Step {
    run.has_side_effects = true;
    const files = b.addWriteFiles();
    files.mode = .{ .mutate = .{ .cwd_relative = pathFromRoot(b, dir) } };
    _ = files.add(name, contents);
    files.step.dependOn(&run.step);
    return &files.step;
}

/// Sorted `/`-separated files under `dir` ending in `suffix`; none if `dir` is absent.
/// Poisons the configure cache: dependOnDirectoryContents over the fixtures aborted Zig 0.17 on Windows.
pub fn globFiles(b: *Build, dir: []const u8, suffix: []const u8) []const []const u8 {
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

pub fn configText(b: *Build, path: []const u8) []const u8 {
    return b.root.root_dir.handle.readFileAlloc(b.graph.io, path, b.allocator, .unlimited) catch |e| std.debug.panic("{s}: {t}", .{ path, e });
}

/// `.vera-work/<name>/<checkout>` under the build root (git-ignored): the
/// suite's and the VPI apps' scratch builds. Not under `.zig-cache`, which a
/// worktree symlinks to the main checkout's, so every worktree's scratch
/// piled up in one cache (a few filtered runs added about 10 GB). Keyed by the
/// checkout too, so two checkouts never build and run in one work dir at
/// once even if `.vera-work` is shared (ETXTBSY: `suite -- ams` failed with
/// FileBusy beside another worktree's). Nothing collects it: delete it while
/// no build runs.
pub fn checkoutWorkDir(b: *Build, name: []const u8) []u8 {
    const key = std.hash.Wyhash.hash(0, pathFromRoot(b, "."));
    return pathFromRoot(b, b.fmt(".vera-work/{s}/{x}", .{ name, key }));
}

pub fn pathFromRoot(b: *Build, sub_path: []const u8) []u8 {
    return b.pathResolve(&.{ b.root.root_dir.path orelse ".", b.root.sub_path, sub_path });
}

pub fn byName(mods: []const Import, name: []const u8) *Module {
    for (mods) |m| if (std.mem.eql(u8, m.name, name)) return m.module;
    std.debug.panic("no module {s} above its importer in module_specs", .{name});
}
