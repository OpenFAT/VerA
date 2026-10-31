//! Library builds: device text (`Output`) and `Options` in, a
//! generation-versioned `lib<name>.<generation>.so` out (§8.3 device-side
//! ABI), or the compiler's error bundle. VerA produces the artifact; the host
//! owns dlopen, dlclose and state reset, and a fresh path per generation gives
//! it a fresh inode. Each build is one cold `zig build-lib --listen=-` child
//! (the compiler server protocol), or for a large LLVM device one `zig
//! build-obj` child per piece in parallel plus a linking `build-lib`, all
//! reaped before `buildLibrary` returns. No build.zig is generated. Also the
//! prebuilt engine object a `.v` device links (`buildEngine`).
//!
//! `buildLibrary` is the spine: key, fetch, spawn, `writeTree`, write the
//! shims, send every update, collect, link, publish, store.
//!
//! Contents:
//! - `pub const Artifact = union(enum) { ok: []u8, failed: std.zig.ErrorBundle }`, `Artifact.deinit`
//! - `pub const BuildError`
//! - `pub const split_min_bytes: usize`
//! - `pub fn buildLibrary(gpa: Allocator, io: Io, o: Options, device: Output, generation: u32) BuildError!Artifact`
//! - `pub fn buildEngine(gpa: Allocator, io: Io, o: Options, cache_dir: []const u8) BuildError!Artifact`

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = std.Build.Cache;
const assert = std.debug.assert;
const argv = @import("argv.zig");
const artifact_cache = @import("artifact_cache.zig");
const server = @import("server.zig");
const shim = @import("shim.zig");
const tree = @import("tree.zig");
const Options = argv.Options;
const Module = argv.Module;
const Output = tree.Output;
const Piece = shim.Piece;
const Server = server.Server;

/// A build's outcome. Either payload is owned by the `gpa` the build was
/// given; free it with `deinit`.
pub const Artifact = union(enum) {
    /// The built file's path: for `buildLibrary`, the fresh
    /// `<work_dir>/lib<name>.<generation>.so`; for `buildEngine`, the object
    /// in the cache directory.
    ok: []u8,
    /// The compiler's report on the generated code.
    failed: std.zig.ErrorBundle,

    /// Frees the payload with `gpa` and invalidates `self`.
    pub fn deinit(self: *Artifact, gpa: Allocator) void {
        switch (self.*) {
            .ok => |path| gpa.free(path),
            .failed => |*bundle| bundle.deinit(gpa),
        }
        self.* = undefined;
    }
};

/// Every way a build fails short of a compiler report: the child could not
/// be run or answered wrongly (`server.Error`: `CompilerGone`,
/// `ProtocolMismatch`, `NoArtifact`, which also names a library that is not
/// where the compiler said), or a file could not be written, read or copied
/// (std's names). Every child is reaped and every allocation freed;
/// files already written stay.
pub const BuildError = server.Error || tree.TreeError || artifact_cache.KeyError ||
    Io.Dir.CopyFileError || Io.Dir.AccessError || Io.File.Atomic.ReplaceError ||
    Io.File.Writer.Error;

/// Emitted device text from which `Split.by_size` splits an LLVM build into
/// pieces. Measured 2026-10-01 (stripped, slots grouped): the split leaves
/// eval's instructions per call unchanged but moves code, and that layout
/// shift was neutral to favourable on bsim4va (818 KB), psp103 (1.4 MB) and
/// coupled_ltra (5.8 MB) yet cost txl (590 KB) +47% eval cycles at identical
/// instructions; the threshold sits between them. Each extra process also
/// costs fixed std/process work, so mos1 (125 KB) gains nothing.
pub const split_min_bytes: usize = 768 * 1024;

/// The `Part`s, then at most `setup_chunks_max` chunks.
const pieces_max = std.enums.values(shim.Part).len + shim.setup_chunks_max;

/// A `dyn` stand-in whose only obligation is the `exportDevice` the shim calls.
const plain_dyn =
    \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    \\    _ = name;
    \\    @export(&D.eval, .{ .name = "arp_eval" });
    \\}
    \\
;

/// Builds `device` cold into `<o.work_dir>/lib<o.name>.<generation>.so` as
/// this target spells a library. With `o.artifact_cache` (and no
/// `o.engine`), a build whose key is cached copies that library instead, and
/// a fresh build is stored there. Caller owns the result and frees it with
/// `Artifact.deinit` and `gpa`. Fails as `BuildError` says; a compile error
/// in the generated code is `.failed`, not an error. Asserts that
/// `o.modules` is not empty and that `device.setup_chunks` is at most
/// `shim.setup_chunks_max`.
pub fn buildLibrary(gpa: Allocator, io: Io, o: Options, device: Output, generation: u32) BuildError!Artifact {
    assert(o.modules.len > 0);
    assert(device.setup_chunks <= shim.setup_chunks_max);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const split = splits(o, device);

    const cached: ?[]const u8 = cached: {
        const dir = o.artifact_cache orelse break :cached null;
        if (o.engine != null) break :cached null;
        const k = try artifact_cache.key(gpa, arena, io, o, device, split) orelse break :cached null;
        break :cached try std.fs.path.join(arena, &.{ dir, try arena.print("{x:0>16}{s}", .{ k, builtin.target.dynamicLibSuffix() }) });
    };
    if (cached) |c| {
        const dst = try generationPath(gpa, o, generation);
        errdefer gpa.free(dst);
        try Io.Dir.cwd().createDirPath(io, o.work_dir);
        switch (try artifact_cache.fetch(io, c, dst)) {
            .hit => return .{ .ok = dst },
            .miss => gpa.free(dst),
        }
    }

    const built = try compile(gpa, io, arena, o, device, generation, split);
    if (cached) |c| if (built == .ok) {
        // A cache that cannot be written costs a later build a compile,
        // never this one its library.
        _ = artifact_cache.store(io, built.ok, c);
    };
    return built;
}

/// Builds `sim`'s design-independent runtime (`rt/engine.zig`) as a
/// position-independent object for `Options.engine`, with `o`'s compiler,
/// optimize mode, backend, `-fstrip` and modules (`dyn` aside), under
/// `cache_dir`. Every device built with the same of each shares one object:
/// the compiler's own cache keys it on its version, the target and CPU, every
/// flag, and the path and content of every source file reached, and answers
/// an unchanged build from the cache. A stale object cannot be linked: the
/// engine's symbol names carry its layout hash (`engine.tag`). Caller owns
/// the result and frees it with `Artifact.deinit` and `gpa`. Fails as
/// `BuildError` says. Asserts that `cache_dir` is not empty.
pub fn buildEngine(gpa: Allocator, io: Io, o: Options, cache_dir: []const u8) BuildError!Artifact {
    assert(cache_dir.len > 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd: Io.Dir = .cwd();
    try cwd.createDirPath(io, cache_dir);
    // Named by its content, so it is written once and never changes.
    const name = comptime std.fmt.comptimePrint("vera_engine_{x:0>16}.zig", .{std.hash.Wyhash.hash(0, shim.engine_root)});
    const root = try std.fs.path.join(arena, &.{ cache_dir, name });
    cwd.access(io, root, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Atomic: a concurrent `vera` never reads half the file.
            var af = try cwd.createFileAtomic(io, root, .{ .replace = true });
            defer af.deinit(io);
            try af.file.writeStreamingAll(io, shim.engine_root);
            try af.replace(io);
        },
        else => |e| return e,
    };

    // SAFETY: `spawn` writes every field before anything reads one.
    var s: Server = undefined;
    try s.spawn(io, arena, try argv.engineArgv(arena, o, cache_dir, root));
    defer s.close(io);
    try s.update(io);
    return switch (try s.wait(gpa)) {
        .failed => |b| .{ .failed = b },
        .ok => |digest| ok: {
            const object = try std.fs.path.join(gpa, &.{
                cache_dir, "o", &Cache.binToHex(digest), "vera_engine" ++ comptime builtin.target.ofmt.fileExt(builtin.target.cpu.arch),
            });
            assert(std.mem.startsWith(u8, object, cache_dir));
            break :ok .{ .ok = object };
        },
    };
}

// ---- private ----

/// Whether `buildLibrary` builds `device` as pieces.
fn splits(o: Options, device: Output) bool {
    const split = switch (o.split) {
        .whole => false,
        .parts => true,
        .by_size => o.backend.forHost() == .llvm and device.text.len >= split_min_bytes,
    };
    if (o.split == .by_size and split) assert(device.text.len >= split_min_bytes);
    return split;
}

/// `buildLibrary` past the artifact cache: spawn, write, compile, link,
/// publish. `arena` holds what lives only for the build.
fn compile(gpa: Allocator, io: Io, arena: Allocator, o: Options, device: Output, generation: u32, split: bool) BuildError!Artifact {
    const all = try pieces(arena, if (split) device.setup_chunks else 0);
    const children: []const ?Piece = if (split) all else &.{null};
    assert(children.len > 0);
    assert(children.len <= pieces_max);

    // Spawned before the tree is written, so the compilers start up while
    // VerA writes.
    const servers = try arena.alloc(Server, children.len);
    var started: usize = 0;
    defer for (servers[0..started]) |*s| s.close(io);
    for (servers, children) |*s, p| {
        try s.spawn(io, arena, try argv.libraryArgv(arena, o, p));
        started += 1;
    }

    const engine: shim.Engine = if (o.engine != null) .prebuilt else .none;
    _ = try tree.writeTree(gpa, io, .{ .work_dir = o.work_dir, .name = o.name, .engine = engine }, device);
    if (split) {
        var dir = try Io.Dir.cwd().openDir(io, o.work_dir, .{});
        defer dir.close(io);
        const setup: shim.Setup = if (device.setup_chunks != 0) .chunked else .whole;
        for (all) |p| {
            const text = try shim.piece(arena, o.name, p.?, engine, setup);
            _ = try tree.writeIfChanged(gpa, io, dir, try shim.fileName(arena, p.?), text);
        }
    }
    // Every update is sent before any reply is read: the pieces compile at once.
    for (servers) |*s| try s.update(io);

    if (!split) return switch (try servers[0].wait(gpa)) {
        .failed => |b| .{ .failed = b },
        .ok => |digest| .{ .ok = try publish(gpa, io, o, digest, generation) },
    };

    // Each piece analyses the whole device, so a device error arrives once
    // per piece; the first piece's report is the one returned.
    const objects = try arena.alloc([]const u8, children.len);
    var failed: ?std.zig.ErrorBundle = null;
    errdefer if (failed) |*b| b.deinit(gpa);
    for (servers, children, objects) |*s, p, *object| switch (try s.wait(gpa)) {
        .failed => |b| if (failed == null) {
            failed = b;
        } else {
            var extra = b;
            extra.deinit(gpa);
        },
        .ok => |digest| object.* = try objectPath(arena, o, digest, p.?),
    };
    if (failed) |b| {
        failed = null;
        return .{ .failed = b };
    }

    // SAFETY: `spawn` writes every field before anything reads one.
    var link: Server = undefined;
    try link.spawn(io, arena, try argv.linkArgv(arena, o, objects));
    defer link.close(io);
    try link.update(io);
    return switch (try link.wait(gpa)) {
        .failed => |b| .{ .failed = b },
        .ok => |digest| .{ .ok = try publish(gpa, io, o, digest, generation) },
    };
}

/// The pieces of a split build: the `Part`s in order, then `setup`'s chunks.
/// Optional so a whole build's single child is `null` beside them.
/// Allocated in `arena`.
fn pieces(arena: Allocator, chunks: u32) Allocator.Error![]const ?Piece {
    assert(chunks <= shim.setup_chunks_max);
    const parts = comptime std.enums.values(shim.Part);
    const all = try arena.alloc(?Piece, parts.len + chunks);
    for (all[0..parts.len], parts) |*p, which| p.* = .{ .part = which };
    for (all[parts.len..], 0..) |*p, k| p.* = .{ .chunk = @intCast(k) };
    assert(all.len <= pieces_max);
    return all;
}

/// The object a piece's child wrote, in the work directory's compiler cache.
fn objectPath(arena: Allocator, o: Options, digest: Cache.BinDigest, p: Piece) Allocator.Error![]const u8 {
    assert(o.name.len > 0);
    const t = &builtin.target;
    return std.fs.path.join(arena, &.{
        o.work_dir,                                                                ".zig-cache", "o", &Cache.binToHex(digest),
        try arena.print("{s}_{f}{s}", .{ o.name, p, t.ofmt.fileExt(t.cpu.arch) }),
    });
}

/// Copies the compiler's output to the generation's path, so the host
/// dlopens a fresh inode; a hard link would share the cache entry's. Caller
/// owns the returned path. Fails with `error.NoArtifact` when the library is
/// not where the compiler's digest says.
fn publish(gpa: Allocator, io: Io, o: Options, digest: Cache.BinDigest, generation: u32) BuildError![]u8 {
    const t = &builtin.target;
    const lib_name = try gpa.print("{s}{s}{s}", .{ t.libPrefix(), o.name, t.dynamicLibSuffix() });
    defer gpa.free(lib_name);
    const src = try std.fs.path.join(gpa, &.{ o.work_dir, ".zig-cache", "o", &Cache.binToHex(digest), lib_name });
    defer gpa.free(src);

    const dst = try generationPath(gpa, o, generation);
    errdefer gpa.free(dst);
    const cwd: Io.Dir = .cwd();
    cwd.copyFile(src, cwd, dst, io, .{}) catch return error.NoArtifact;
    assert(std.mem.startsWith(u8, dst, o.work_dir));
    return dst;
}

/// `<work_dir>/lib<name>.<generation>.so`, spelled as this target names a
/// library: the fresh path a host dlopens. Caller owns it.
fn generationPath(gpa: Allocator, o: Options, generation: u32) Allocator.Error![]u8 {
    const t = &builtin.target;
    const path = try gpa.print("{s}{c}{s}{s}.{d}{s}", .{
        o.work_dir, std.fs.path.sep, t.libPrefix(),
        o.name,     generation,      t.dynamicLibSuffix(),
    });
    assert(std.mem.endsWith(u8, path, t.dynamicLibSuffix()));
    return path;
}

/// `name` as `publish` names this target's library: `testdev.1` is
/// `libtestdev.1.so` on Linux and `testdev.1.dll` on Windows.
fn testLib(comptime name: []const u8) []const u8 {
    const t = &builtin.target;
    return comptime t.libPrefix() ++ name ++ t.dynamicLibSuffix();
}

/// The path of a successful build, or the test fails with its report.
fn expectOk(io: Io, r: Artifact) ![]u8 {
    return switch (r) {
        .failed => |b| {
            b.renderToStderr(io, .{}, .off) catch |e| std.debug.print("rendering the report failed: {t}\n", .{e});
            return error.UnexpectedBuildFailure;
        },
        .ok => |path| path,
    };
}

/// Opens `path` and returns `arp_eval(x)`: the oracle is the built code run.
fn callEval(path: []const u8, x: f64) !f64 {
    var lib = try @import("dynlib").DynLib.open(path);
    defer lib.close();
    const eval = lib.lookup(*const fn (f64) callconv(.c) f64, "arp_eval") orelse return error.MissingSymbol;
    return eval(x);
}

/// Writes `contract.zig` (`contract_text`) and `dyn.zig` (`dyn_text`) under
/// `sub` of `tmp` and returns their modules, roots allocated in `arena`.
fn standIns(arena: Allocator, tmp: std.testing.TmpDir, sub: []const u8, contract_text: []const u8, dyn_text: []const u8) ![2]Module {
    const io = std.testing.io;
    const dir = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, sub });
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "contract.zig" }), .data = contract_text });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "dyn.zig" }), .data = dyn_text });
    return .{
        .{ .name = "contract", .root = try std.fs.path.join(arena, &.{ dir, "contract.zig" }) },
        .{ .name = "dyn", .root = try std.fs.path.join(arena, &.{ dir, "dyn.zig" }) },
    };
}

// The oracle for a library build is the reference tool and the built code:
// a real `zig` compiles each tree, and the tests dlopen the library and call
// it, or read back the bytes a cache hit must have copied.

test "buildLibrary builds and versions a device" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try arena.allocator().print(".zig-cache/tmp/{s}/w", .{tmp.sub_path});
    const mods = try standIns(arena.allocator(), tmp, "mods", "pub const k: f64 = 2.0;\n", plain_dyn);
    const o: Options = .{ .work_dir = work, .name = "testdev", .optimize = .debug, .backend = .self_hosted, .modules = &mods };

    const dev_v1 =
        \\const contract = @import("contract");
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k; }
        \\
    ;
    var r1 = try buildLibrary(gpa, io, o, .{ .text = dev_v1 }, 1);
    defer r1.deinit(gpa);
    const so1 = try expectOk(io, r1);
    try std.testing.expect(std.mem.endsWith(u8, so1, testLib("testdev.1")));
    try std.testing.expectEqual(@as(f64, 6.0), try callEval(so1, 3.0));

    // A changed unit rebuilds to a fresh inode under a new generation.
    const dev_v2 =
        \\const contract = @import("contract");
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k + 1.0; }
        \\
    ;
    var r2 = try buildLibrary(gpa, io, o, .{ .text = dev_v2 }, 2);
    defer r2.deinit(gpa);
    const so2 = try expectOk(io, r2);
    try std.testing.expect(std.mem.endsWith(u8, so2, testLib("testdev.2")));
    try std.testing.expectEqual(@as(f64, 7.0), try callEval(so2, 3.0));

    // A broken unit is reported as diagnostics.
    var r3 = try buildLibrary(gpa, io, o, .{ .text = "pub fn eval() void { @compileError(\"boom\"); }\n" }, 3);
    defer r3.deinit(gpa);
    try std.testing.expect(r3 == .failed);

    // The split form compiles: `device.zig` and the unit files import each
    // other, which is legal Zig.
    var r5 = try buildLibrary(gpa, io, o, tree.splitOutput(&.{ "unit_a", "unit_b" }), 5);
    defer r5.deinit(gpa);
    const so5 = try expectOk(io, r5);
    try std.testing.expect(std.mem.endsWith(u8, so5, testLib("testdev.5")));
    // unit_a(3) + unit_b(3) = 3*2 + (3+2).
    try std.testing.expectEqual(@as(f64, 11.0), try callEval(so5, 3.0));
}

test "buildEngine reuses its object only while every key component is unchanged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);
    const cache = try std.fs.path.join(gpa, &.{ work, "engine-cache" });
    defer gpa.free(cache);

    // A stand-in `sim` whose engine reads a constant from a second file.
    try tmp.dir.writeFile(io, .{ .sub_path = "sim.zig", .data =
        \\pub const rt = struct {
        \\    pub const engine = struct {
        \\        pub fn exportAll() void {
        \\            @export(&k, .{ .name = "vera_rt_test_k" });
        \\        }
        \\        fn k() callconv(.c) u32 {
        \\            return @import("k.zig").k;
        \\        }
        \\    };
        \\};
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "k.zig", .data = "pub const k: u32 = 1;\n" });
    const mods = [_]Module{
        .{ .name = "dyn", .root = "never-read.zig" },
        .{ .name = "sim", .root = try std.fs.path.join(gpa, &.{ work, "sim.zig" }) },
    };
    defer gpa.free(mods[1].root);
    var o: Options = .{ .work_dir = work, .name = "unused", .optimize = .debug, .backend = .self_hosted, .modules = &mods };

    const Build = struct {
        fn path(o_: Options, cache_: []const u8) ![]u8 {
            var r = try buildEngine(gpa, io, o_, cache_);
            errdefer r.deinit(gpa);
            return try expectOk(io, r);
        }
    };
    const first = try Build.path(o, cache);
    defer gpa.free(first);

    // Unchanged: the same object.
    const again = try Build.path(o, cache);
    defer gpa.free(again);
    try std.testing.expectEqualStrings(first, again);

    // A changed source file, a changed optimize mode, a changed backend:
    // each a different object.
    try tmp.dir.writeFile(io, .{ .sub_path = "k.zig", .data = "pub const k: u32 = 2;\n" });
    const edited = try Build.path(o, cache);
    defer gpa.free(edited);
    try std.testing.expect(!std.mem.eql(u8, first, edited));

    o.optimize = .small;
    o.backend = .llvm;
    const small = try Build.path(o, cache);
    defer gpa.free(small);
    try std.testing.expect(!std.mem.eql(u8, edited, small));

    // ... and the change undone finds the first object again.
    o.optimize = .debug;
    o.backend = .self_hosted;
    try tmp.dir.writeFile(io, .{ .sub_path = "k.zig", .data = "pub const k: u32 = 1;\n" });
    const back = try Build.path(o, cache);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(first, back);
}

test "a split build links one object per part into a library that runs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try arena.allocator().print(".zig-cache/tmp/{s}/w", .{tmp.sub_path});

    // A host with `exportDevicePart` exports each symbol from one part: the
    // library resolves both only if every part was compiled and linked.
    const parts_dyn =
        \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
        \\    _ = .{ D, name };
        \\    @compileError("a split build calls exportDevicePart");
        \\}
        \\pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: @TypeOf(.setup)) void {
        \\    _ = name;
        \\    if (part == .setup) @export(&D.k, .{ .name = "arp_k" });
        \\    if (part == .eval) @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\
    ;
    // One without it is built whole in the setup object.
    const whole_dyn =
        \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
        \\    _ = name;
        \\    @export(&D.k, .{ .name = "arp_k" });
        \\    @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\
    ;
    const dev =
        \\const contract = @import("contract");
        \\pub fn k() callconv(.c) f64 { return contract.k; }
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k; }
        \\
    ;
    for ([_][]const u8{ parts_dyn, whole_dyn }, [_][]const u8{ "parts", "whole" }, 1..) |dyn, sub, gen| {
        const mods = try standIns(arena.allocator(), tmp, sub, "pub const k: f64 = 2.0;\n", dyn);
        const o: Options = .{ .work_dir = work, .name = "splitdev", .optimize = .fast, .backend = .llvm, .modules = &mods, .split = .parts };
        try std.testing.expect(splits(o, .{ .text = dev }));
        var r = try buildLibrary(gpa, io, o, .{ .text = dev }, @intCast(gen));
        defer r.deinit(gpa);
        const so = try expectOk(io, r);
        var lib = try @import("dynlib").DynLib.open(so);
        defer lib.close();
        const k = lib.lookup(*const fn () callconv(.c) f64, "arp_k") orelse return error.MissingSymbol;
        try std.testing.expectEqual(@as(f64, 2.0), k());
        try std.testing.expectEqual(@as(f64, 6.0), try callEval(so, 3.0));
    }

    // The default splits only a large LLVM build.
    const base: Options = .{ .work_dir = work, .name = "d", .optimize = .fast, .backend = .llvm, .modules = &.{} };
    try std.testing.expect(!splits(base, .{ .text = dev }));
    const big = try gpa.alloc(u8, split_min_bytes);
    defer gpa.free(big);
    try std.testing.expect(splits(base, .{ .text = big }));
    var native = base;
    native.backend = .self_hosted;
    try std.testing.expectEqual(argv.Backend.self_hosted.forHost() == .llvm, splits(native, .{ .text = big }));
}

test "splits: an explicit choice wins over the size rule" {
    const tiny: Output = .{ .text = "x" };
    var o: Options = .{ .work_dir = "w", .name = "d", .optimize = .fast, .backend = .self_hosted, .modules = &.{}, .split = .parts };
    try std.testing.expect(splits(o, tiny));
    o.backend = .llvm;
    o.split = .whole;
    const huge = try std.testing.allocator.alloc(u8, split_min_bytes);
    defer std.testing.allocator.free(huge);
    try std.testing.expect(!splits(o, .{ .text = huge }));
    // One byte under the threshold stays whole.
    o.split = .by_size;
    try std.testing.expect(!splits(o, .{ .text = huge[1..] }));
}

test pieces {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The names a split build gives its objects and shims, written out.
    for ([_]u32{ 0, 2 }, [_][]const u8{ "setup state eval ", "setup state eval setup0 setup1 " }) |chunks, want| {
        var got: std.ArrayList(u8) = .empty;
        for (try pieces(a, chunks)) |p| try got.print(a, "{f} ", .{p.?});
        try std.testing.expectEqualStrings(want, got.items);
    }
}

test "a split build that fails returns one report and leaks the others' none" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try arena.allocator().print(".zig-cache/tmp/{s}/w", .{tmp.sub_path});
    // Every part reaches `eval`, so every piece fails and two reports are
    // dropped (`std.testing.allocator` sees a leak if one is not freed).
    const mods = try standIns(arena.allocator(), tmp, "mods", "pub const k: f64 = 2.0;\n",
        \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
        \\    _ = name;
        \\    @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: @TypeOf(.setup)) void {
        \\    _ = .{ name, part };
        \\    @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\
    );
    const o: Options = .{ .work_dir = work, .name = "faildev", .optimize = .fast, .backend = .llvm, .modules = &mods, .split = .parts };
    const dev = "pub fn eval() callconv(.c) void { @compileError(\"boom\"); }\n";
    var r = try buildLibrary(gpa, io, o, .{ .text = dev }, 1);
    defer r.deinit(gpa);
    try std.testing.expect(r == .failed);
    try std.testing.expect(r.failed.errorMessageCount() > 0);
}

test "artifact_cache: a second work directory reuses the first's library, and a changed device misses" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try arena.allocator().print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    const mods = try standIns(arena.allocator(), tmp, "mods", "pub const k: f64 = 2.0;\n", plain_dyn);
    const cache = try std.fs.path.join(arena.allocator(), &.{ base, "cache" });
    const dev = "pub fn eval(x: f64) callconv(.c) f64 { return x * @import(\"contract\").k; }\n";

    // The first build fills the cache; its entry is then replaced by a
    // marker, which a hit publishes and a miss cannot.
    const marker = "not a library";
    var got: [3]bool = undefined;
    for ([_][]const u8{ "w1", "w2", "w3" }, 0..) |w, i| {
        const wd = try std.fs.path.join(arena.allocator(), &.{ base, w });
        const o: Options = .{ .work_dir = wd, .name = "cachedev", .optimize = .debug, .backend = .self_hosted, .modules = &mods, .artifact_cache = cache };
        var r = try buildLibrary(gpa, io, o, .{ .text = if (i == 2) dev ++ "pub const z = 1;\n" else dev }, 1);
        defer r.deinit(gpa);
        const bytes = try Io.Dir.cwd().readFileAlloc(io, try expectOk(io, r), gpa, .unlimited);
        defer gpa.free(bytes);
        got[i] = std.mem.eql(u8, bytes, marker);
        if (i == 0) {
            var cdir = try Io.Dir.cwd().openDir(io, cache, .{ .iterate = true });
            defer cdir.close(io);
            var it = cdir.iterate();
            var n: usize = 0;
            while (try it.next(io)) |e| : (n += 1) try cdir.writeFile(io, .{ .sub_path = e.name, .data = marker });
            try std.testing.expectEqual(@as(usize, 1), n);
        }
    }
    try std.testing.expectEqualSlices(bool, &.{ false, true, false }, &got);
}

test "artifact_cache: an edit to a file a module root imports misses the cache" {
    // Regression: the key once hashed only each module's root file, so a
    // build after an edit to a sibling it imports returned the stale library.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try arena.allocator().print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    const mods = try standIns(arena.allocator(), tmp, "mods", "pub const k = @import(\"k.zig\").k;\n", plain_dyn);
    const cache = try std.fs.path.join(arena.allocator(), &.{ base, "cache" });
    const dev = "pub fn eval(x: f64) callconv(.c) f64 { return x * @import(\"contract\").k; }\n";

    for ([_][]const u8{ "w1", "w2" }, [_]f64{ 2.0, 3.0 }) |w, k| {
        try tmp.dir.writeFile(io, .{ .sub_path = "mods/k.zig", .data = try arena.allocator().print("pub const k: f64 = {d:.1};\n", .{k}) });
        const wd = try std.fs.path.join(arena.allocator(), &.{ base, w });
        const o: Options = .{ .work_dir = wd, .name = "sibdev", .optimize = .debug, .backend = .self_hosted, .modules = &mods, .artifact_cache = cache };
        var r = try buildLibrary(gpa, io, o, .{ .text = dev }, 1);
        defer r.deinit(gpa);
        try std.testing.expectEqual(k, try callEval(try expectOk(io, r), 1.0));
    }
}
