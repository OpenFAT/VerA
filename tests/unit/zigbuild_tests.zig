//! `zigbuild` through its root as other modules see it: `Backend.auto`,
//! testbench staging and builds (`stage`, `buildExe`), library and engine
//! builds (`buildLibrary`, `buildEngine`, `Options.artifact_cache`) and the
//! device tree (`writeTree`, `fileStem`). The oracles: the backend rule
//! written out by hand; a real `zig` child (its stderr, the files it reads
//! and writes, the engine object's cache path, a cache hit's copied bytes);
//! the files read back off disk. Tests of the files' private declarations
//! (argv builders, shims, the server protocol, the cache key) stay beside
//! them in src/zigbuild/.

const std = @import("std");
const zigbuild = @import("zigbuild");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Backend = zigbuild.Backend;
const Module = zigbuild.Module;
const Options = zigbuild.Options;
const Output = zigbuild.Output;
const Artifact = zigbuild.Artifact;
const buildLibrary = zigbuild.buildLibrary;
const buildEngine = zigbuild.buildEngine;
const BuildOptions = zigbuild.BuildOptions;
const buildExe = zigbuild.buildExe;
const stage = zigbuild.stage;
const Tree = zigbuild.Tree;
const writeTree = zigbuild.writeTree;
const fileStem = zigbuild.fileStem;

/// A `dyn` stand-in whose only obligation is the `exportDevice` the shim calls.
const plain_dyn =
    \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    \\    _ = name;
    \\    @export(&D.eval, .{ .name = "arp_eval" });
    \\}
    \\
;

// A copy of src/zigbuild/tree.zig's `split_prologue`, `split_tail` and
// `split_prelude`, which its `splitOutput` still reads: the pieces a
// hand-tiled device is cut from.
const split_prologue =
    \\const contract = @import("contract");
    \\pub const k2: f64 = 2.0;
    \\
;
const split_tail =
    \\pub fn eval(x: f64) callconv(.c) f64 {
    \\    return unit_a(x) + unit_b(x);
    \\}
    \\
;
const split_prelude = "const dev = @import(\"../device.zig\");\nconst k2 = dev.k2;\n";

// ---- private ----

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

test "Backend.auto is self-hosted only for Debug on x86_64" {
    try std.testing.expectEqual(Backend.self_hosted, Backend.auto(.debug, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.fast, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.debug, .aarch64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.debug, .nvptx64));
    for ([_]std.lang.Optimize{ .safe, .fast, .small }) |m|
        try std.testing.expectEqual(Backend.llvm, Backend.auto(m, .x86_64));
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
    const r = try buildExe(gpa, io, "pub const x = 1;\n", "pub fn main() void { _ = @import(\"device\").y; }\n", opts);
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
    // escaped module name takes a hashed stem (`tree.fileStem`).
    const t = try stage(arena, io, "D2", "R2", .{ .work_dir = work, .contract = "c.zig", .name = "res+" });
    try std.testing.expect(!std.mem.eql(u8, s.root, t.root));
    try std.testing.expectEqualStrings("RUNNER", try tmp.dir.readFileAlloc(io, "res.tb.zig", arena, .limited(64)));
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

test "writeTree writes an un-split device alone, and rewrites only what changed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);
    var tree: Tree = .{ .work_dir = work, .name = "testdev" };

    // shim.zig + device.zig, then nothing.
    try std.testing.expectEqual(@as(u32, 2), try writeTree(gpa, io, tree, .{ .text = "abcdef" }));
    try std.testing.expectEqual(@as(u32, 0), try writeTree(gpa, io, tree, .{ .text = "abcdef" }));

    // A text that is a prefix of the file on disk is still a change.
    try std.testing.expectEqual(@as(u32, 1), try writeTree(gpa, io, tree, .{ .text = "abc" }));
    const dev = try tmp.dir.readFileAlloc(io, "device.zig", gpa, .limited(64));
    defer gpa.free(dev);
    try std.testing.expectEqualStrings("abc", dev);

    // Linking an engine changes the shim alone.
    tree.engine = .prebuilt;
    try std.testing.expectEqual(@as(u32, 1), try writeTree(gpa, io, tree, .{ .text = "abc" }));
    const shim_text = try tmp.dir.readFileAlloc(io, "shim.zig", gpa, .limited(4096));
    defer gpa.free(shim_text);
    try std.testing.expect(std.mem.find(u8, shim_text, "vera_prebuilt_engine") != null);

    // No split, so no helpers file and no unit directory.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "h.zig", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "u", .{}));
}

test "writeTree keeps a unit's doc comment and an existing `pub`, and prunes only stale .zig files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);
    const tree: Tree = .{ .work_dir = work, .name = "testdev" };

    // unit_a: a doc comment before `fn` (lo < fn); unit_b: already `pub`.
    const doc = "/// a\n";
    const fn_a = "fn unit_a(y: f64) f64 {\n    return y;\n}\n";
    const pub_b = "pub fn unit_b(y: f64) f64 {\n    return y;\n}\n";
    const lo_b = split_prologue.len + doc.len + fn_a.len;
    const out: Output = .{
        .text = split_prologue ++ doc ++ fn_a ++ pub_b ++ split_tail,
        .names = &.{ "unit_a", "unit_b" },
        .unit_lo = &.{ split_prologue.len, lo_b },
        .unit_fn = &.{ split_prologue.len + doc.len, lo_b },
        .unit_hi = &.{ lo_b, lo_b + pub_b.len },
        .prelude = split_prelude,
    };
    try std.testing.expectEqual(@as(u32, 5), try writeTree(gpa, io, tree, out));

    const a = try tmp.dir.readFileAlloc(io, "u/unit_a.zig", gpa, .limited(4096));
    defer gpa.free(a);
    try std.testing.expectEqualStrings(split_prelude ++ doc ++ "pub " ++ fn_a, a);
    const b = try tmp.dir.readFileAlloc(io, "u/unit_b.zig", gpa, .limited(4096));
    defer gpa.free(b);
    try std.testing.expectEqualStrings(split_prelude ++ pub_b, b);

    // A stale unit goes; a file that is not `.zig`, and a directory, stay.
    try tmp.dir.writeFile(io, .{ .sub_path = "u/old.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "u/notes.txt", .data = "" });
    try tmp.dir.createDirPath(io, "u/dir.zig");
    try std.testing.expectEqual(@as(u32, 1), try writeTree(gpa, io, tree, out));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "u/old.zig", .{}));
    _ = try tmp.dir.statFile(io, "u/notes.txt", .{});
    _ = try tmp.dir.statFile(io, "u/dir.zig", .{});
}

test fileStem {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A short plain name is itself, not a copy.
    const plain: []const u8 = "nmos_1";
    try std.testing.expect((try fileStem(a, plain)).ptr == plain.ptr);
    const max: [128]u8 = @splat('a');
    try std.testing.expectEqualStrings(&max, try fileStem(a, &max));

    // One byte longer: its first 64 bytes, `-`, 16 hex digits.
    const over: [129]u8 = @splat('a');
    const s = try fileStem(a, &over);
    try std.testing.expectEqual(@as(usize, 64 + 1 + 16), s.len);
    try std.testing.expectEqualStrings(over[0..64], s[0..64]);
    try std.testing.expectEqual(@as(u8, '-'), s[64]);
    for (s[65..]) |c| try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));

    // Not plain: the plain prefix, so `a.b` and `a,b` share `a-` and differ
    // only in the hash; a name with no plain prefix starts at the `-`.
    const dot = try fileStem(a, "a.b");
    const comma = try fileStem(a, "a,b");
    try std.testing.expectEqual(@as(usize, 1 + 1 + 16), dot.len);
    try std.testing.expect(std.mem.startsWith(u8, dot, "a-"));
    try std.testing.expect(!std.mem.eql(u8, dot, comma));
    try std.testing.expectEqualStrings(dot, try fileStem(a, "a.b"));
    try std.testing.expectEqual(@as(usize, 17), (try fileStem(a, ".x")).len);

    // A hashed stem has a `-`; a kept one cannot.
    try std.testing.expect(std.mem.findScalar(u8, try fileStem(a, plain), '-') == null);
    try std.testing.expect(std.mem.findScalar(u8, dot, '-') != null);
}
