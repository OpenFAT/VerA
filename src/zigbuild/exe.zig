//! Testbench build: device.zig and runner text in, one `zig build-exe` (or
//! `build-lib`) out, as the binary's path or the compiler's stderr. The runner
//! text is the caller's (`tb.renderRunner`); this file owns the argv, the
//! module files on disk and the batch root.

const std = @import("std");
const builtin = @import("builtin");
const orchestrator = @import("orchestrator.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// The modules an emitted executable or a `.v` device links beside `contract`,
/// build.zig's `module_specs` rows for `sim` and what it imports. Each root is
/// relative to the VerA tree the contract sits in (`treeOf`), which is what
/// `vera` writes under its work directory (`src/main.zig`'s `simTree`).
pub const runtime_modules = [_]orchestrator.Module{
    .{ .name = "sim", .root = "lib/sim/root.zig", .deps = &.{ "contract", "base", "diag", "frontend", "kernels" } },
    .{ .name = "base", .root = "lib/base/root.zig" },
    .{ .name = "diag", .root = "lib/diag/root.zig" },
    .{ .name = "frontend", .root = "lib/frontend/root.zig", .deps = &.{ "base", "diag", "kernels" } },
    .{ .name = "kernels", .root = "lib/kernels/root.zig", .deps = &.{"contract"} },
};

/// The VerA tree a `contract` root sits in: `<tree>/lib/contract.zig`.
pub fn treeOf(contract: []const u8) []const u8 {
    return std.fs.path.dirname(std.fs.path.dirname(contract) orelse ".") orelse ".";
}

/// How `buildExe` builds and where it writes.
pub const BuildOptions = struct {
    /// Scratch: `device.zig` and `tb.zig` are written here, and the binary
    /// lands here too unless `out_path` says otherwise.
    work_dir: []const u8,
    /// Root of the `contract` module the generated device imports.
    contract: []const u8,
    /// Artifact name: the module name, so the binary is `./<module>` plus the
    /// target's executable extension (`.exe` on Windows).
    name: []const u8,
    /// The binary's path instead of `<work_dir>/<name>`. Copied, never kept.
    out_path: ?[]const u8 = null,
    /// The compiler to spawn; looked up on `PATH` when bare.
    zig_exe: []const u8 = "zig",
    /// `-O` for the testbench. Debug by default: see `buildExe`.
    optimize: std.lang.Optimize = .debug,
    /// Null is `Backend.auto(optimize, <this host>)`.
    backend: ?orchestrator.Backend = null,
    /// `renderMixed`'s runner imports `sim` and `diag`, compiled from the
    /// VerA tree `contract` sits in (`<root>/lib/contract.zig`).
    mixed: bool = false,
    /// Build `renderVpiLib`'s runner as a shared library for a Clause 12
    /// analog host to load, instead of an executable.
    shared_lib: bool = false,
    /// Keep DWARF in a ReleaseFast/ReleaseSmall build (`orchestrator.strip`).
    debug_info: bool = false,
    /// Overrides `orchestrator.strip` when set. The fixture suite strips its
    /// Debug testbenches: DWARF is 7-26% of a testbench build's compiler
    /// work and the suite reads only the transcript. A safety panic
    /// still prints its message, without the stack trace; rebuild by hand
    /// with `vera --emit-exe` to get one.
    strip: ?bool = null,
};

/// Outcome of `buildExe`. Either payload is owned by the `gpa` passed to
/// `buildExe`; release it with `deinit`.
pub const BuildResult = union(enum) {
    /// Path of the built binary.
    ok: []const u8,
    /// `zig`'s stderr, verbatim. Generated code that does not compile is an
    /// engine bug, and this is the report.
    failed: []const u8,

    /// Frees the payload; `gpa` must be the allocator `buildExe` was given.
    pub fn deinit(self: BuildResult, gpa: Allocator) void {
        switch (self) {
            .ok, .failed => |p| gpa.free(p),
        }
    }
};

/// Builds device.zig and the runner into one native binary under
/// `opts.work_dir`. A null `device_zig` builds `runner_zig` alone over `sim`
/// and `diag` (an IEEE 1364 design). Asserts that `device_zig` is set or
/// `opts.mixed` is, and that a `shared_lib` build has a device. Spawns
/// `opts.zig_exe` and blocks until it exits; an
/// error return means it could not be spawned or a file could not be
/// written. Caller owns the result and must free it with `deinit(gpa)`.
///
/// Calls `build-exe` directly: orchestrator.zig's `.so` path serves hot
/// reload, which a build-once testbench does not need. Debug is the default
/// because compile time dominates and safety checks turn a codegen bug into a
/// trap instead of a plausible wrong number.
pub fn buildExe(
    gpa: Allocator,
    io: Io,
    device_zig: ?[]const u8,
    runner_zig: []const u8,
    opts: BuildOptions,
) !BuildResult {
    assert(device_zig != null or opts.mixed);
    // `renderVpiLib`'s runner calls the device; there is no 1364 library form.
    if (opts.shared_lib) assert(device_zig != null);
    var dir = try openWorkDir(io, opts);
    defer dir.close(io);

    // Every argv string lives for this call only.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bin = if (opts.out_path) |p| try gpa.dupe(u8, p) else try binPath(gpa, arena, opts);
    errdefer gpa.free(bin);

    const m_root = try arena.print("-Mroot={s}", .{try writeModule(arena, io, dir, opts, "tb", runner_zig)});

    // `--dep` binds to the NEXT `-M`, and the FIRST `-M` is the root module.
    var argv = try argvHead(arena, opts, if (opts.shared_lib) "build-lib" else "build-exe", bin);
    if (opts.shared_lib) {
        try argv.append(arena, "-dynamic");
        // A host `dlopen`s it: libc's dynamic TLS model (`orchestrator.link_libc`).
        try argv.appendSlice(arena, orchestrator.link_libc);
    }
    if (device_zig != null) try argv.appendSlice(arena, &.{ "--dep", "device" });
    if (opts.mixed) try argv.appendSlice(arena, &.{ "--dep", "sim", "--dep", "diag" });
    if (device_zig) |text| {
        try argv.appendSlice(arena, &.{ "--dep", "contract", m_root });
        // A `.v` device (`digital.emitDevice`) runs on `sim`'s engine.
        if (opts.mixed) try argv.appendSlice(arena, &.{ "--dep", "sim" });
        try argv.appendSlice(arena, &.{ "--dep", "contract", try arena.print("-Mdevice={s}", .{try writeModule(arena, io, dir, opts, "device", text)}) });
    } else try argv.append(arena, m_root);
    try argv.append(arena, try arena.print("-Mcontract={s}", .{opts.contract}));
    if (opts.mixed) {
        const root = treeOf(opts.contract);
        for (runtime_modules) |rm| {
            for (rm.deps) |d| try argv.appendSlice(arena, &.{ "--dep", d });
            try argv.append(arena, try arena.print("-M{s}={s}", .{ rm.name, try std.fs.path.join(arena, &.{ root, rm.root }) }));
        }
    }
    return runZig(gpa, io, argv.items, bin);
}

/// Creates `opts.work_dir` if absent and opens it. The caller closes it.
fn openWorkDir(io: Io, opts: BuildOptions) !Io.Dir {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, opts.work_dir);
    return cwd.openDir(io, opts.work_dir, .{});
}

/// Returns `<work_dir>/<fileStem(name)>` plus the target's executable
/// extension. Caller owns the path and must free it with `gpa`.
fn binPath(gpa: Allocator, arena: Allocator, opts: BuildOptions) ![]const u8 {
    return std.mem.concat(gpa, u8, &.{
        try std.fs.path.join(arena, &.{ opts.work_dir, try orchestrator.fileStem(arena, opts.name) }),
        builtin.target.exeFileExt(),
    });
}

/// Returns the argv every build here opens with: compiler, `verb`, output,
/// `-O`, cache directory, backend, then `-fstrip` when stripping. Allocated in
/// `arena`, as everything later appended to it must be.
fn argvHead(arena: Allocator, opts: BuildOptions, verb: []const u8, bin: []const u8) !std.ArrayList([]const u8) {
    assert(std.mem.eql(u8, verb, "build-exe") or std.mem.eql(u8, verb, "build-lib"));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        opts.zig_exe,
        verb,
        try arena.print("-femit-bin={s}", .{bin}),
        try arena.print("-O{t}", .{opts.optimize}),
        "--cache-dir",
        ".zig-cache",
        // The binary is loaded at run time (`dynlib.zig`), never linked
        // against, and Zig 0.17's COFF linker writes the import library to
        // the output's directory joined to itself (FileNotFound, or
        // BadPathName on an absolute path).
        "-fno-emit-implib",
    });
    try argv.appendSlice(arena, switch ((opts.backend orelse orchestrator.Backend.auto(opts.optimize, builtin.target.cpu.arch)).forHost()) {
        .self_hosted => &.{ "-fno-llvm", "-fno-lld" },
        .llvm => &.{"-fllvm"},
    });
    // No debug info where there are no safety checks to trace: emitting it
    // is most of an unsafe build's LLVM time.
    if (opts.strip orelse orchestrator.strip(opts.optimize, opts.debug_info)) try argv.append(arena, "-fstrip");
    // Compiler, verb, output, `-O`, the cache pair, implib, then a backend.
    assert(argv.items.len >= 8);
    return argv;
}

/// Runs `argv` to its exit. On success `bin`, which `gpa` owns, becomes the
/// `.ok` payload; on a failed build it is freed and `zig`'s stderr becomes the
/// `.failed` payload. On an error return `bin` is still the caller's.
fn runZig(gpa: Allocator, io: Io, argv: []const []const u8, bin: []const u8) !BuildResult {
    assert(argv.len >= 8); // `argvHead`'s floor.
    const r = try std.process.run(gpa, io, .{ .argv = argv });
    gpa.free(r.stdout);
    const failed = switch (r.term) {
        .exited => |c| c != 0,
        else => true,
    };
    if (failed) {
        gpa.free(bin);
        return .{ .failed = r.stderr };
    }
    gpa.free(r.stderr);
    return .{ .ok = bin };
}

/// Writes one module's source to `<name>.<suffix>.zig` in `dir` and returns
/// its path, allocated in `arena`. The name-qualified file keeps two
/// artifacts sharing a work root from overwriting each other.
fn writeModule(arena: Allocator, io: Io, dir: Io.Dir, opts: BuildOptions, suffix: []const u8, text: []const u8) ![]const u8 {
    assert(suffix.len != 0);
    assert(std.mem.findAny(u8, suffix, "/\\") == null);
    const file = try arena.print("{s}.{s}.zig", .{ try orchestrator.fileStem(arena, opts.name), suffix });
    try dir.writeFile(io, .{ .sub_path = file, .data = text });
    return std.fs.path.join(arena, &.{ opts.work_dir, file });
}

/// A testbench's module files on disk, as `stage` wrote them.
pub const Staged = struct { root: []const u8, device: []const u8 };

/// Writes the two module files `buildExe` would build for this device and
/// runner, under `opts.work_dir`, without building. Paths live in `arena`.
/// Asserts that `opts` is a plain build, as `buildBatch` requires.
pub fn stage(arena: Allocator, io: Io, device_zig: []const u8, runner_zig: []const u8, opts: BuildOptions) !Staged {
    assert(!opts.mixed);
    assert(!opts.shared_lib);
    var dir = try openWorkDir(io, opts);
    defer dir.close(io);
    return .{
        .root = try writeModule(arena, io, dir, opts, "tb", runner_zig),
        .device = try writeModule(arena, io, dir, opts, "device", device_zig),
    };
}

/// A `buildBatch` binary runs member `i` when its `argv[0]` ends in
/// `batch_argv0 ++ "<i>"`: a symlink of that name stands in for each member's
/// own binary. No runner reads `argv[0]` (its plusargs start at `argv[1]`),
/// so a member's transcript is the one its own binary would print.
pub const batch_argv0 = "vera-batch-";

/// Builds several plain (not `mixed`, not `shared_lib`) staged testbenches
/// into ONE binary at `<opts.work_dir>/<opts.name>`, dispatching on `argv[0]`
/// (`batch_argv0`). A fixture testbench's build is mostly the compiler's fixed
/// cost per invocation (std, start code, the panic handler), which a batch
/// pays once. Measured with a shared warm cache, 8 Debug testbenches:
/// 17.57 Gi built one by one, 3.53 Gi as one batch, transcripts identical.
/// `.failed` names no member: the caller rebuilds them one by one to learn
/// which broke. Asserts that `members` is nonempty and `opts` is neither
/// `mixed` nor `shared_lib`. Caller owns the result and must free it with
/// `deinit(gpa)`.
pub fn buildBatch(gpa: Allocator, io: Io, members: []const Staged, opts: BuildOptions) !BuildResult {
    assert(!opts.mixed);
    assert(!opts.shared_lib);
    assert(members.len != 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = try openWorkDir(io, opts);
    defer dir.close(io);
    const root_path = try writeModule(arena, io, dir, opts, "batch", try batchRoot(arena, members.len));
    const bin = try binPath(gpa, arena, opts);
    errdefer gpa.free(bin);

    var argv = try argvHead(arena, opts, "build-exe", bin);
    for (0..members.len) |i| try argv.appendSlice(arena, &.{ "--dep", try arena.print("tb{d}", .{i}) });
    try argv.append(arena, try arena.print("-Mroot={s}", .{root_path}));
    for (members, 0..) |m, i| try argv.appendSlice(arena, &.{
        "--dep",                                        try arena.print("device=dev{d}", .{i}),
        "--dep",                                        "contract",
        try arena.print("-Mtb{d}={s}", .{ i, m.root }), "--dep",
        "contract",                                     try arena.print("-Mdev{d}={s}", .{ i, m.device }),
    });
    try argv.append(arena, try arena.print("-Mcontract={s}", .{opts.contract}));
    return runZig(gpa, io, argv.items, bin);
}

/// Returns the root module of a `buildBatch` binary over `n` members,
/// allocated in `arena`: its `main` runs `@import("tb<i>").main` for the `i`
/// that `argv[0]` ends in after `batch_argv0`, and panics on any other. It
/// also holds `vera_domain_muted`, the root decl a device's `zDomain` reads.
fn batchRoot(arena: Allocator, n: usize) Allocator.Error![]const u8 {
    assert(n != 0); // `buildBatch`'s precondition: a switch with only `else`.
    var root: std.ArrayList(u8) = .empty;
    try root.print(arena,
        \\const std = @import("std");
        \\/// The §4.3.2 domain-report mute each member's runner sets while its
        \\/// self-checks run (`runner_text` `muteDomain`): a device's `zDomain`
        \\/// reads it from the root, which here is this file.
        \\pub var vera_domain_muted: bool = false;
        \\pub fn main(init: std.process.Init.Minimal) void {{
        \\    const argv = init.args.toSlice(std.heap.page_allocator) catch @panic("argv");
        \\    const at = std.mem.findLast(u8, argv[0], "{s}") orelse @panic("argv[0] names no batch member");
        \\    const i = std.fmt.parseInt(usize, argv[0][at + {d} ..], 10) catch @panic("argv[0] names no batch member");
        \\    switch (i) {{
        \\
    , .{ batch_argv0, batch_argv0.len });
    for (0..n) |i| try root.print(arena, "        {d} => @import(\"tb{d}\").main(init),\n", .{ i, i });
    try root.appendSlice(arena, "        else => @panic(\"argv[0] names no batch member\"),\n    }\n}\n");
    return root.items;
}

/// Fails the test unless `src` passes Zig's AstGen with no error.
fn expectAstGen(src: []const u8) !void {
    const gpa = std.testing.allocator;
    const z = try gpa.dupeSentinel(u8, src, 0);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .{ .mode = .zig });
    defer tree.deinit(gpa);
    var zir = try std.zig.AstGen.generate(gpa, tree);
    defer zir.deinit(gpa);
    if (tree.errors.len == 0 and !zir.hasCompileErrors()) return;
    std.debug.print("{s}\n", .{src});
    return error.TestUnexpectedResult;
}

test batchRoot {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src = try batchRoot(arena_state.allocator(), 3);
    try expectAstGen(src);
    // One arm per member and no more.
    try std.testing.expect(std.mem.find(u8, src, "        2 => @import(\"tb2\").main(init),\n") != null);
    try std.testing.expect(std.mem.find(u8, src, "3 =>") == null);
    // A member's device reads the §4.3.2 mute from the root, which is this file.
    try std.testing.expect(std.mem.find(u8, src, "pub var vera_domain_muted: bool = false;\n") != null);
    // The member index is read after the whole of `batch_argv0`.
    try std.testing.expect(std.mem.find(u8, src, "\"vera-batch-\"") != null);
    try std.testing.expect(std.mem.find(u8, src, "argv[0][at + 11 ..]") != null);
}

test argvHead {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base: BuildOptions = .{ .work_dir = "w", .contract = "c.zig", .name = "m", .zig_exe = "zigx" };
    const Case = struct { opts: BuildOptions, verb: []const u8, want: []const []const u8 };
    var fast = base;
    fast.optimize = .fast;
    fast.backend = .llvm;
    var fast_dwarf = fast;
    fast_dwarf.debug_info = true;
    var fast_unstripped = fast;
    fast_unstripped.strip = false;
    var debug_stripped = base;
    debug_stripped.backend = .self_hosted;
    debug_stripped.strip = true;
    // `orchestrator.strip`: an unsafe build strips unless DWARF was asked
    // for; `strip` overrides it either way.
    const cases = [_]Case{
        .{ .opts = debug_stripped, .verb = "build-exe", .want = if (orchestrator.Backend.self_hosted.forHost() == .self_hosted)
            &.{ "zigx", "build-exe", "-femit-bin=b", "-Odebug", "--cache-dir", ".zig-cache", "-fno-emit-implib", "-fno-llvm", "-fno-lld", "-fstrip" }
        else
            &.{ "zigx", "build-exe", "-femit-bin=b", "-Odebug", "--cache-dir", ".zig-cache", "-fno-emit-implib", "-fllvm", "-fstrip" } },
        .{ .opts = fast, .verb = "build-lib", .want = &.{ "zigx", "build-lib", "-femit-bin=b", "-Ofast", "--cache-dir", ".zig-cache", "-fno-emit-implib", "-fllvm", "-fstrip" } },
        .{ .opts = fast_dwarf, .verb = "build-exe", .want = &.{ "zigx", "build-exe", "-femit-bin=b", "-Ofast", "--cache-dir", ".zig-cache", "-fno-emit-implib", "-fllvm" } },
        .{ .opts = fast_unstripped, .verb = "build-exe", .want = &.{ "zigx", "build-exe", "-femit-bin=b", "-Ofast", "--cache-dir", ".zig-cache", "-fno-emit-implib", "-fllvm" } },
    };
    for (cases) |c| {
        const argv = (try argvHead(arena, c.opts, c.verb, "b")).items;
        try std.testing.expectEqual(c.want.len, argv.len);
        for (c.want, argv) |w, a| try std.testing.expectEqualStrings(w, a);
    }
}

test "buildExe hands back zig's stderr for a testbench that does not compile" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);
    try tmp.dir.writeFile(io, .{ .sub_path = "c.zig", .data = "" });
    const contract = try std.fs.path.join(gpa, &.{ work, "c.zig" });
    defer gpa.free(contract);
    const opts: BuildOptions = .{ .work_dir = work, .contract = contract, .name = "broken" };

    // `std.testing.allocator` fails the test if `bin` or the report leaks.
    const r = buildExe(gpa, io, "pub const x = 1;\n", "pub fn main() void { _ = @import(\"device\").y; }\n", opts) catch |e| switch (e) {
        // No `zig` on PATH in this environment: nothing to assert.
        error.FileNotFound => return error.SkipZigTest,
        else => return e,
    };
    defer r.deinit(gpa);
    try std.testing.expect(r == .failed);
    try std.testing.expect(std.mem.find(u8, r.failed, "no member named 'y'") != null);

    // A compiler that cannot be spawned is an error, and `bin` is freed.
    var gone = opts;
    gone.zig_exe = "/nonexistent/zig";
    try std.testing.expectError(error.FileNotFound, buildExe(gpa, io, "", "", gone));
}

test stage {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try arena.print(".zig-cache/tmp/{s}", .{tmp.sub_path});

    const s = try stage(arena, io, "DEVICE", "RUNNER", .{ .work_dir = work, .contract = "c.zig", .name = "res" });
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ work, "res.tb.zig" }), s.root);
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ work, "res.device.zig" }), s.device);
    try std.testing.expectEqualStrings("RUNNER", try tmp.dir.readFileAlloc(io, "res.tb.zig", arena, .limited(64)));
    try std.testing.expectEqualStrings("DEVICE", try tmp.dir.readFileAlloc(io, "res.device.zig", arena, .limited(64)));

    // A second artifact in the same work root keeps its own files: an
    // escaped module name takes a hashed stem (`orchestrator.fileStem`).
    const t = try stage(arena, io, "D2", "R2", .{ .work_dir = work, .contract = "c.zig", .name = "res+" });
    try std.testing.expect(!std.mem.eql(u8, s.root, t.root));
    try std.testing.expectEqualStrings("RUNNER", try tmp.dir.readFileAlloc(io, "res.tb.zig", arena, .limited(64)));
}
