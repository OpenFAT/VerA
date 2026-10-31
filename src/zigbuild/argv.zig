//! Build policy: a library build's `Options` in, the `zig` command lines of
//! its children out: the whole library, one object per split piece, the link
//! over those objects, and the prebuilt engine object. Each `--dep` applies to
//! the next `-M`, and the first `-M` is the root module, as in
//! `std.Build.Step.Compile.getZigArgs`. Cites no LRM clause: the flags are
//! Zig's.
//!
//! Contents:
//! - `pub const Backend = enum { self_hosted, llvm }`, `Backend.auto`, `Backend.forHost`, `Backend.flags`
//! - `pub const Module = struct { name, root, deps }`
//! - `pub const Split = enum { by_size, whole, parts }`
//! - `pub const Options = struct`
//! - `pub const link_libc: []const []const u8`
//! - `pub fn strip(optimize: std.lang.Optimize, debug_info: bool) bool`
//! - `pub fn libraryArgv(arena: Allocator, o: Options, p: ?Piece) Allocator.Error![]const []const u8`
//! - `pub fn linkArgv(arena: Allocator, o: Options, objects: []const []const u8) Allocator.Error![]const []const u8`
//! - `pub fn engineArgv(arena: Allocator, o: Options, cache_dir: []const u8, root: []const u8) Allocator.Error![]const []const u8`

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const shim = @import("shim.zig");
const Piece = shim.Piece;

/// Which Zig code generator builds an artifact, independent of the optimize
/// mode. `.self_hosted` does not optimise and has no nvptx/amdgcn target.
pub const Backend = enum {
    self_hosted,
    llvm,

    /// Returns `.self_hosted` for Debug on x86_64, where build time dominates,
    /// and `.llvm` otherwise.
    pub fn auto(optimize: std.lang.Optimize, arch: std.Target.Cpu.Arch) Backend {
        return if (optimize == .debug and arch == .x86_64) .self_hosted else .llvm;
    }

    /// Returns the backend a build on this host actually uses: `.llvm` on
    /// Windows and off x86_64, whatever was asked. The self-hosted COFF linker
    /// writes a DLL at a fixed base with its relocations stripped, so a second
    /// one cannot load in the same process; and off x86_64 the self-hosted
    /// code generator panics "TODO" on a device (aarch64-macos, seen in CI).
    pub fn forHost(b: Backend) Backend {
        return if (builtin.target.os.tag == .windows or builtin.target.cpu.arch != .x86_64) .llvm else b; // os: picks a backend; every target builds
    }

    /// Returns the `zig` flags that select `forHost(b)`.
    pub fn flags(b: Backend) []const []const u8 {
        return switch (b.forHost()) {
            .self_hosted => &.{ "-fno-llvm", "-fno-lld" },
            .llvm => &.{"-fllvm"},
        };
    }
};

/// One support module on the compiler command line. Strings are borrowed and
/// must outlive the build.
pub const Module = struct {
    /// The `@import` string.
    name: []const u8,
    /// The module's root source file, relative to the process cwd or
    /// absolute. Every file the module can import sits in this file's
    /// directory or below it (Zig refuses an import outside the module path).
    root: []const u8,
    /// Names of other modules on the same command line that this one imports.
    deps: []const []const u8 = &.{},
};

/// How a library build is cut into compiler processes.
pub const Split = enum {
    /// One object per piece for an LLVM build of at least
    /// `split_min_bytes` of device text, else whole.
    by_size,
    /// One `zig build-lib` child.
    whole,
    /// One `zig build-obj` child per piece, in parallel, then a link.
    parts,
};

/// How a library build compiles and where it writes. Strings are borrowed
/// and must outlive the build.
pub const Options = struct {
    /// VerA-owned directory: the generated device tree and shims, the
    /// compiler cache, and the versioned libraries. Created if absent.
    work_dir: []const u8,
    /// Device name. The library is `<work_dir>/lib<name>.<generation>.so`
    /// as the target spells it.
    name: []const u8,
    /// Independent of `backend`; `Backend.auto` is the usual pairing.
    optimize: std.lang.Optimize,
    backend: Backend,
    /// Support modules, in argv order. A library build needs `contract`
    /// (the device imports it) and `dyn`, whose root exposes
    /// `pub fn exportDevice(comptime D: type, comptime name: []const u8) void`
    /// and may expose `exportDevicePart` for a split build
    /// (`contract.DevicePart`).
    modules: []const Module,
    /// The compiler to spawn, looked up on `PATH` when bare. It must be the
    /// Zig VerA was built with, or the build fails with
    /// `error.ProtocolMismatch`.
    zig_exe: []const u8 = "zig",
    /// Keep DWARF in a ReleaseFast/ReleaseSmall build. Off by default: debug
    /// information is about half of a large device's LLVM time, and the
    /// machine code is the same with or without it. Debug and ReleaseSafe
    /// always keep it (their safety panics print stack traces).
    debug_info: bool = false,
    split: Split = .by_size,
    /// A `.v` device's prebuilt engine object (`buildEngine`): linked in, and
    /// the shim declares `vera_prebuilt_engine`.
    engine: ?[]const u8 = null,
    /// In a split LLVM build, compile every piece but `eval` and `state` on
    /// the self-hosted backend: they run once per instance or card, so
    /// unoptimized code costs the simulation nothing, and they leave LLVM's
    /// critical path (psp103's three setup chunks, 1.35 s each under LLVM,
    /// take 0.7 s). Sound only for a `dyn` that keeps every per-iterate entry
    /// point out of `.setup`, as `osdi_dyn` does; applied only where the two
    /// backends' objects link together. Not in the artifact key: no type
    /// layout depends on the backend.
    cold_self_hosted: bool = false,
    /// A directory of finished libraries keyed by every input that decides
    /// their bytes: a build whose key is there copies it instead of
    /// compiling, whatever its `work_dir`. Null: no such cache. Not used with
    /// `engine`, a prebuilt object outside the key.
    artifact_cache: ?[]const u8 = null,
    /// `-target` for every compile, e.g. `x86_64-linux-gnu`: a host that
    /// dlopens the library passes its own, so the library links the host's
    /// libc. Null builds for the detected native target, which inside a Nix
    /// sandbox is musl.
    target: ?[]const u8 = null,
};

/// `-lc` for every library VerA builds on a dynamic-linking host: a host
/// loads it with `dlopen`, and a thread-local in it (Zig 0.18's
/// `std.debug.print` reads `Io.Threaded.Thread.current`) must then use the
/// libc dynamic TLS model (`__tls_get_addr`). Without libc, Zig 0.18.0-dev's
/// shared library reads it at a static offset and faults (a `--emit-so`
/// device that prints, VPI, OSDI). Windows DLLs do not need it.
pub const link_libc: []const []const u8 = if (builtin.target.os.tag == .windows) &.{} else &.{"-lc"}; // os: picks a flag for the host build; every target builds, Windows with none

/// Which support modules `appendModules` writes.
const Which = enum { all, except_dyn };

/// The path separator and `link_libc` as an array, for the expected argvs
/// in the tests.
const sep: []const u8 = std.fs.path.sep_str;
const lc: [link_libc.len][]const u8 = link_libc[0..link_libc.len].*;

/// Returns whether a native build passes `-fstrip`: optimized without safety
/// checks, unless the caller asked for debug information.
pub fn strip(optimize: std.lang.Optimize, debug_info: bool) bool {
    return !debug_info and (optimize == .fast or optimize == .small);
}

/// Returns the `zig build-lib --listen=-` of the whole library, rooted at
/// `shim.zig`, or for a piece `p` the `zig build-obj --listen=-` of
/// `shim_<p>.zig` into `<name>_<p>.o`. Support modules follow in
/// `o.modules` order; each is a dependency of the root and of the device.
/// Only the whole library takes `o.engine`. Allocated in `arena`.
/// Asserts that `o.name` and `o.work_dir` are not empty.
pub fn libraryArgv(arena: Allocator, o: Options, p: ?Piece) Allocator.Error![]const []const u8 {
    assert(o.name.len > 0);
    assert(o.work_dir.len > 0);
    var a: std.ArrayList([]const u8) = .empty;
    const name = if (p) |q| try arena.print("{s}_{f}", .{ o.name, q }) else o.name;
    // An object linked into a shared library must be position independent.
    const kind: []const []const u8 = if (p == null) &.{"-dynamic"} else &.{"-fPIC"};
    try head(arena, &a, o, if (p == null) "build-lib" else "build-obj", kind, name, try workCache(arena, o));

    const host = o.backend.forHost();
    const backend: Backend = if (p) |q| (if (coldSelfHosted(o, q)) .self_hosted else host) else host;
    try a.appendSlice(arena, backend.flags());
    // The only backend that patches in place, so the only one where
    // `-fincremental` pays. Not for a cold piece of an LLVM build
    // (`coldSelfHosted`): lld links it beside the LLVM objects and refuses an
    // incremental object's padded `.eh_frame` ("corrupted .eh_frame: FDE
    // version 1 or 3 expected").
    if (backend == .self_hosted and host == .self_hosted) try a.append(arena, "-fincremental");
    if (strip(o.optimize, o.debug_info)) try a.append(arena, "-fstrip");
    if (p == null) if (o.engine) |e| try a.append(arena, e);

    // The root shim imports `device` plus every support module.
    for (o.modules) |m| try a.appendSlice(arena, &.{ "--dep", m.name });
    const root = if (p) |q| try shim.fileName(arena, q) else "shim.zig";
    try a.appendSlice(arena, &.{
        "--dep",
        "device",
        try arena.print("-Mroot={s}", .{try std.fs.path.join(arena, &.{ o.work_dir, root })}),
    });
    // The device imports `contract`, and may import any support module.
    for (o.modules) |m| try a.appendSlice(arena, &.{ "--dep", m.name });
    try a.append(arena, try arena.print("-Mdevice={s}", .{try std.fs.path.join(arena, &.{ o.work_dir, "device.zig" })}));
    try appendModules(arena, &a, o.modules, .all);
    assert(a.items.len > o.modules.len);
    return a.items;
}

/// Returns the `zig build-lib --listen=- -dynamic` that links a split build's
/// `objects` (and `o.engine`) into the library. The link takes `-O` and
/// `-fstrip` for the compiler_rt it adds. Allocated in `arena`. Asserts that
/// there is an object to link.
pub fn linkArgv(arena: Allocator, o: Options, objects: []const []const u8) Allocator.Error![]const []const u8 {
    assert(objects.len > 0);
    var a: std.ArrayList([]const u8) = .empty;
    // No Zig root module brings start.zig's `_DllMainCRTStartup`, which a
    // Windows DLL otherwise needs as its entry point.
    try head(arena, &a, o, "build-lib", &.{ "-dynamic", "-fno-entry" }, o.name, try workCache(arena, o));
    if (strip(o.optimize, o.debug_info)) try a.append(arena, "-fstrip");
    try a.appendSlice(arena, objects);
    if (o.engine) |e| try a.append(arena, e);
    assert(a.items.len >= objects.len);
    return a.items;
}

/// Returns the `zig build-obj --listen=- -fPIC` of `sim`'s runtime engine,
/// rooted at `root` and cached under `cache_dir`, with every support module
/// but `dyn`. Allocated in `arena`. Asserts that `root` and `cache_dir` are
/// not empty.
pub fn engineArgv(arena: Allocator, o: Options, cache_dir: []const u8, root: []const u8) Allocator.Error![]const []const u8 {
    assert(cache_dir.len > 0);
    assert(root.len > 0);
    var a: std.ArrayList([]const u8) = .empty;
    try head(arena, &a, o, "build-obj", &.{"-fPIC"}, "vera_engine", cache_dir);
    try a.appendSlice(arena, o.backend.flags());
    if (strip(o.optimize, o.debug_info)) try a.append(arena, "-fstrip");
    try a.appendSlice(arena, &.{ "--dep", "sim", try arena.print("-Mroot={s}", .{root}) });
    try appendModules(arena, &a, o.modules, .except_dyn);
    assert(a.items.len > 0);
    return a.items;
}

// ---- private ----

/// Appends the prefix every child here opens with: compiler, `verb`, the
/// server flag, `kind`, `-O`, the artifact name, the cache directory, libc
/// and the target.
fn head(
    arena: Allocator,
    a: *std.ArrayList([]const u8),
    o: Options,
    verb: []const u8,
    kind: []const []const u8,
    name: []const u8,
    cache_dir: []const u8,
) Allocator.Error!void {
    assert(a.items.len == 0);
    try a.appendSlice(arena, &.{ o.zig_exe, verb, "--listen=-" });
    try a.appendSlice(arena, kind);
    try a.appendSlice(arena, &.{
        try arena.print("-O{t}", .{o.optimize}),
        "--name",
        name,
        "--cache-dir",
        cache_dir,
    });
    try a.appendSlice(arena, link_libc);
    if (o.target) |t| try a.appendSlice(arena, &.{ "-target", t });
}

fn workCache(arena: Allocator, o: Options) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ o.work_dir, ".zig-cache" });
}

/// Appends one `--dep`... `-M<name>=<root>` group per module.
fn appendModules(arena: Allocator, a: *std.ArrayList([]const u8), modules: []const Module, which: Which) Allocator.Error!void {
    for (modules) |m| {
        assert(m.name.len > 0);
        if (which == .except_dyn and std.mem.eql(u8, m.name, "dyn")) continue;
        for (m.deps) |d| try a.appendSlice(arena, &.{ "--dep", d });
        try a.append(arena, try arena.print("-M{s}={s}", .{ m.name, m.root }));
    }
}

/// Whether split piece `p` builds on the self-hosted backend under
/// `Options.cold_self_hosted`: a piece other than `eval` and `state`, in an
/// LLVM build for the native x86_64 Linux target, the one place this
/// compiler's self-hosted ELF objects link beside its LLVM ones.
fn coldSelfHosted(o: Options, p: Piece) bool {
    if (!o.cold_self_hosted or o.backend.forHost() != .llvm or o.target != null) return false;
    if (builtin.target.cpu.arch != .x86_64 or builtin.target.os.tag != .linux) return false; // os: the self-hosted backend's ELF objects link beside LLVM's here
    return switch (p) {
        .part => |which| which == .setup,
        .chunk => true,
    };
}

/// Fails unless `got` is `want`, element by element.
fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    for (want, 0..) |w, i| {
        if (i >= got.len) return error.TestExpectedEqual;
        try std.testing.expectEqualStrings(w, got[i]);
    }
    try std.testing.expectEqual(want.len, got.len);
}

fn hasFlag(argv: []const []const u8, flag: []const u8) bool {
    for (argv) |x| if (std.mem.eql(u8, x, flag)) return true;
    return false;
}

// The oracle for every argv is a command line derived by hand from `zig
// build-lib --help` and `std.Build.Step.Compile.getZigArgs`'s `--dep` rule;
// the library tests in library.zig run them through a real `zig`.

test "Backend.auto is self-hosted only for Debug on x86_64" {
    try std.testing.expectEqual(Backend.self_hosted, Backend.auto(.debug, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.fast, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.debug, .aarch64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.debug, .nvptx64));
    for ([_]std.lang.Optimize{ .safe, .fast, .small }) |m|
        try std.testing.expectEqual(Backend.llvm, Backend.auto(m, .x86_64));
}

test strip {
    // Only fast and small drop safety, and only they strip; debug_info vetoes.
    for (std.enums.values(std.lang.Optimize)) |m| {
        try std.testing.expect(!strip(m, true));
        try std.testing.expectEqual(m == .fast or m == .small, strip(m, false));
    }
}

test libraryArgv {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mods = [_]Module{
        .{ .name = "contract", .root = "c.zig" },
        .{ .name = "dyn", .root = "d.zig", .deps = &.{"contract"} },
    };

    // The whole library: every support module is a dependency of the root
    // and of the device, and each `--dep` applies to the `-M` after it.
    const whole = [_][]const u8{
        "zig",
        "build-lib",
        "--listen=-",
        "-dynamic",
        "-Ofast",
        "--name",
        "dev",
        "--cache-dir",
        "w" ++ sep ++ ".zig-cache",
    } ++ lc ++ [_][]const u8{
        "-fllvm",
        "-fstrip",
        "eng.o",
        "--dep",
        "contract",
        "--dep",
        "dyn",
        "--dep",
        "device",
        "-Mroot=w" ++ sep ++ "shim.zig",
        "--dep",
        "contract",
        "--dep",
        "dyn",
        "-Mdevice=w" ++ sep ++ "device.zig",
        "-Mcontract=c.zig",
        "--dep",
        "contract",
        "-Mdyn=d.zig",
    };
    try expectArgv(&whole, try libraryArgv(a, .{
        .work_dir = "w",
        .name = "dev",
        .optimize = .fast,
        .backend = .llvm,
        .modules = &mods,
        .engine = "eng.o",
    }, null));

    // One part: an object, position independent, named for its piece, rooted
    // at its own shim, with no engine (only the link takes it). Self-hosted
    // adds `-fincremental`; Debug keeps its symbols. A host that builds only
    // with LLVM (`forHost`) passes `-fllvm` instead.
    const self_hosted_flags: []const []const u8 = comptime if (Backend.self_hosted.forHost() == .self_hosted)
        &.{ "-fno-llvm", "-fno-lld", "-fincremental" }
    else
        &.{"-fllvm"};
    const piece = [_][]const u8{
        "zig",
        "build-obj",
        "--listen=-",
        "-fPIC",
        "-Odebug",
        "--name",
        "dev_setup",
        "--cache-dir",
        "w" ++ sep ++ ".zig-cache",
    } ++ lc ++ self_hosted_flags[0..self_hosted_flags.len].* ++ [_][]const u8{
        "--dep",
        "device",
        "-Mroot=w" ++ sep ++ "shim_setup.zig",
        "-Mdevice=w" ++ sep ++ "device.zig",
    };
    try expectArgv(&piece, try libraryArgv(a, .{
        .work_dir = "w",
        .name = "dev",
        .optimize = .debug,
        .backend = .self_hosted,
        .modules = &.{},
        .engine = "eng.o",
    }, .{ .part = .setup }));

    // A chunk is named `setup<k>` in its object and its root.
    const chunk = try libraryArgv(a, .{ .work_dir = "w", .name = "dev", .optimize = .fast, .backend = .llvm, .modules = &.{} }, .{ .chunk = 3 });
    try std.testing.expect(hasFlag(chunk, "dev_setup3"));
    try std.testing.expect(hasFlag(chunk, "-Mroot=w" ++ sep ++ "shim_setup3.zig"));
}

test linkArgv {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const o: Options = .{ .work_dir = "w", .name = "dev", .optimize = .small, .backend = .llvm, .modules = &.{}, .engine = "eng.o" };
    const want = [_][]const u8{
        "zig",
        "build-lib",
        "--listen=-",
        "-dynamic",
        "-fno-entry",
        "-Osmall",
        "--name",
        "dev",
        "--cache-dir",
        "w" ++ sep ++ ".zig-cache",
    } ++ lc ++ [_][]const u8{
        "-fstrip",
        "a.o",
        "b.o",
        "eng.o",
    };
    try expectArgv(&want, try linkArgv(arena.allocator(), o, &.{ "a.o", "b.o" }));
}

test engineArgv {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const mods = [_]Module{
        .{ .name = "dyn", .root = "d.zig" },
        .{ .name = "sim", .root = "s.zig", .deps = &.{"base"} },
        .{ .name = "base", .root = "b.zig" },
    };
    const o: Options = .{ .work_dir = "w", .name = "dev", .optimize = .fast, .backend = .llvm, .modules = &mods, .target = "x86_64-linux-gnu" };
    // The cache directory is the caller's, not the work directory's, and
    // `dyn` is left out: the engine is the same object for every device.
    const want = [_][]const u8{
        "zig",
        "build-obj",
        "--listen=-",
        "-fPIC",
        "-Ofast",
        "--name",
        "vera_engine",
        "--cache-dir",
        "ec",
    } ++ lc ++ [_][]const u8{
        "-target",
        "x86_64-linux-gnu",
        "-fllvm",
        "-fstrip",
        "--dep",
        "sim",
        "-Mroot=ec/root.zig",
        "--dep",
        "base",
        "-Msim=s.zig",
        "-Mbase=b.zig",
    };
    try expectArgv(&want, try engineArgv(arena.allocator(), o, "ec", "ec/root.zig"));
}

test "coldSelfHosted: every piece but eval and state, only when asked, in an LLVM build for the native x86_64 Linux target" {
    var o: Options = .{ .work_dir = ".", .name = "d", .optimize = .fast, .backend = .llvm, .modules = &.{}, .cold_self_hosted = true };
    const here = builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag == .linux; // os: the rule under test is per host
    try std.testing.expectEqual(here, coldSelfHosted(o, .{ .part = .setup }));
    try std.testing.expectEqual(here, coldSelfHosted(o, .{ .chunk = 0 }));
    try std.testing.expect(!coldSelfHosted(o, .{ .part = .eval }));
    try std.testing.expect(!coldSelfHosted(o, .{ .part = .state }));
    if (here) {
        // A cold piece builds self-hosted without `-fincremental`, which lld
        // could not link; `eval` stays on LLVM.
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();
        const cold = try libraryArgv(arena_state.allocator(), o, .{ .part = .setup });
        const hot = try libraryArgv(arena_state.allocator(), o, .{ .part = .eval });
        try std.testing.expect(hasFlag(cold, "-fno-llvm"));
        try std.testing.expect(!hasFlag(cold, "-fincremental"));
        try std.testing.expect(!hasFlag(cold, "-fllvm"));
        try std.testing.expect(hasFlag(hot, "-fllvm"));
        try std.testing.expect(!hasFlag(hot, "-fno-llvm"));
    }
    o.target = "x86_64-linux-gnu";
    try std.testing.expect(!coldSelfHosted(o, .{ .part = .setup }));
    o.target = null;
    o.cold_self_hosted = false;
    try std.testing.expect(!coldSelfHosted(o, .{ .part = .setup }));
}
