//! The artifact cache: a library build's declared inputs in (the compiler,
//! every option on its command line, the device text, and the contents of
//! every file each support module can import), a 64-bit key out; and the
//! copy of a finished library into and out of `Options.artifact_cache` under
//! that key. A key hashes contents and paths relative to each module's
//! directory, never an absolute path, so two checkouts of the same sources
//! share entries. Cites no LRM clause: the inputs are Zig's.
//!
//! Contents:
//! - `pub const KeyError`
//! - `pub const tree_files_max: u32`, `pub const tree_bytes_max: u64`
//! - `pub fn key(gpa: Allocator, scratch: Allocator, io: Io, o: Options, device: Output, split: bool) KeyError!?u64`
//! - `pub fn fetch(io: Io, src: []const u8, dst: []const u8) Io.Dir.CopyFileError!Fetched`
//! - `pub const Fetched = enum { hit, miss }`
//! - `pub fn store(io: Io, library: []const u8, dst: []const u8) Stored`
//! - `pub const Stored = enum { stored, skipped }`

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Wyhash = std.hash.Wyhash;
const assert = std.debug.assert;
const argv = @import("argv.zig");
const Options = argv.Options;
const Output = @import("tree.zig").Output;

/// Every way `key` fails: a module directory or one of its files could not
/// be opened, listed or read. Nothing is written.
pub const KeyError = Allocator.Error || Io.Dir.OpenError || Io.Dir.Iterator.Error ||
    Io.Dir.ReadFileAllocError;

/// Whether `fetch` found the library in the cache.
pub const Fetched = enum { hit, miss };

/// Whether `store` put the library in the cache. A cache that cannot be
/// written is skipped: the build it would serve already succeeded.
pub const Stored = enum { stored, skipped };

/// Most files one module directory may hold for its build to be keyed;
/// VerA's own `lib/` holds about a hundred.
pub const tree_files_max: u32 = 1 << 14;

/// Most bytes one module directory's files may hold for its build to be
/// keyed; VerA's own `lib/` holds about 4 MB.
pub const tree_bytes_max: u64 = 256 << 20;

/// The key's format; a change to what `key` hashes moves it, so entries an
/// older VerA wrote are never read as this one's.
const key_seed: u64 = 0x05d1_ca_c4e + 1;

comptime {
    assert(tree_bytes_max > tree_files_max);
}

/// Returns the cache key of a library build: the compiler VerA was built
/// with and the one it spawns, every option that reaches the compiler's
/// command line, every byte of `device`, whether the build `split`s, and
/// for each support module its name, its root's file name and the contents
/// and relative path of every file under its root's directory (Zig refuses
/// an import outside it). Hidden directories (`.zig-cache`, `.git`) and
/// `zig-out` are not read: build output, not source. Two runs over the same
/// inputs return the same key, wherever the modules sit. Returns null when a
/// module directory holds more than `tree_files_max` files or
/// `tree_bytes_max` bytes: such a build is not cached. File contents are read
/// into `gpa` and freed; paths live in `scratch`. Fails as `KeyError` says.
/// Asserts that `o.modules` is not empty.
// ponytail: a module directory that holds its own work directory changes on
// every build, so it always misses: a rebuild, never a wrong library.
pub fn key(gpa: Allocator, scratch: Allocator, io: Io, o: Options, device: Output, split: bool) KeyError!?u64 {
    assert(o.modules.len > 0);
    assert(o.name.len > 0);
    var h: Wyhash = .init(key_seed);
    hashBytes(&h, builtin.zig_version_string);
    // The spawned compiler's path: a Nix store path names its build.
    hashBytes(&h, o.zig_exe);
    hashBytes(&h, @tagName(o.optimize));
    hashBytes(&h, @tagName(o.backend.forHost()));
    hashBytes(&h, o.target orelse "");
    hashBytes(&h, o.name);
    h.update(&.{ @intFromBool(o.debug_info), @intFromBool(split), @intFromBool(o.cold_self_hosted) });

    hashBytes(&h, device.text);
    for (device.names) |n| hashBytes(&h, n);
    for ([_][]const u32{ device.unit_lo, device.unit_fn, device.unit_hi }) |offsets| {
        hashBytes(&h, std.mem.sliceAsBytes(offsets));
    }
    hashBytes(&h, device.prelude);
    hashBytes(&h, device.helpers);
    h.update(std.mem.asBytes(&device.setup_chunks));

    for (o.modules, 0..) |m, i| {
        hashBytes(&h, m.name);
        for (m.deps) |d| hashBytes(&h, d);
        hashBytes(&h, std.fs.path.basename(m.root));
        const dir = std.fs.path.dirname(m.root) orelse ".";
        // Modules that share a directory (`contract` and `osdi_dyn` in
        // `lib/`) read it once: a later one hashes the earlier one's index.
        const first = for (o.modules[0..i], 0..) |e, j| {
            if (std.mem.eql(u8, std.fs.path.dirname(e.root) orelse ".", dir)) break j;
        } else i;
        h.update(std.mem.asBytes(&@as(u32, @intCast(first))));
        if (first == i and !try hashTree(gpa, scratch, io, &h, dir)) return null;
    }
    return h.final();
}

/// Copies the cached library `src` to `dst` and returns `.hit`, or `.miss`
/// when the cache has no such entry. Fails when the copy itself fails.
pub fn fetch(io: Io, src: []const u8, dst: []const u8) Io.Dir.CopyFileError!Fetched {
    assert(src.len > 0);
    assert(dst.len > 0);
    const cwd: Io.Dir = .cwd();
    cwd.copyFile(src, cwd, dst, io, .{}) catch |err| switch (err) {
        error.FileNotFound => return .miss,
        else => |e| return e,
    };
    return .hit;
}

/// Puts `library` in the cache as `dst`, through a temporary name renamed
/// into place, so a concurrent build reads a whole library or none. Returns
/// `.skipped` when any step fails, leaving at most the temporary file.
pub fn store(io: Io, library: []const u8, dst: []const u8) Stored {
    assert(library.len > 0);
    assert(dst.len > 0);
    const cwd: Io.Dir = .cwd();
    // SAFETY: `bufPrint` writes every byte of the slice it returns.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&buf, "{s}.{x}.tmp", .{ dst, Wyhash.hash(0, library) }) catch return .skipped;
    if (std.fs.path.dirname(dst)) |d| cwd.createDirPath(io, d) catch return .skipped;
    cwd.copyFile(library, cwd, tmp, io, .{}) catch return .skipped;
    cwd.rename(tmp, cwd, dst, io) catch return .skipped;
    return .stored;
}

// ---- private ----

/// Hashes `s` with its length first, so adjacent fields cannot run together.
fn hashBytes(h: *Wyhash, s: []const u8) void {
    h.update(std.mem.asBytes(&s.len));
    h.update(s);
}

/// Hashes every file under `dir_path` in path order, each as its relative
/// path then its contents, and returns whether the tree was within the
/// bounds. The order is fixed by the sort: a directory lists in any order.
fn hashTree(gpa: Allocator, scratch: Allocator, io: Io, h: *Wyhash, dir_path: []const u8) KeyError!bool {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    var entries: u32 = 0;
    while (try walker.next(io)) |entry| : (entries += 1) {
        // Directories count too, so a tree of empty directories ends.
        if (entries == 2 * tree_files_max) return false;
        switch (entry.kind) {
            .directory => if (!skipped(entry.basename)) try walker.enter(io, entry),
            .file, .sym_link => {
                if (paths.items.len == tree_files_max) return false;
                try paths.append(scratch, try scratch.dupe(u8, entry.path));
            },
            else => {},
        }
    }
    assert(paths.items.len <= tree_files_max);
    std.mem.sort([]const u8, paths.items, {}, lessThan);

    var bytes_total: u64 = 0;
    for (paths.items) |p| {
        const remaining: usize = @intCast(tree_bytes_max - bytes_total);
        const bytes = dir.readFileAlloc(io, p, gpa, .limited(remaining)) catch |err| switch (err) {
            error.StreamTooLong => return false,
            else => |e| return e,
        };
        defer gpa.free(bytes);
        bytes_total += bytes.len;
        hashBytes(h, p);
        hashBytes(h, bytes);
    }
    assert(bytes_total <= tree_bytes_max);
    return true;
}

/// Whether the walk leaves a directory out: hidden ones and `zig-out`.
fn skipped(name: []const u8) bool {
    return name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "zig-out");
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The key of a minimal build over `modules`, with `scratch` an arena freed
/// by the caller.
fn keyOf(scratch: Allocator, modules: []const argv.Module) !?u64 {
    const o: Options = .{ .work_dir = "w", .name = "d", .optimize = .debug, .backend = .llvm, .modules = modules };
    return key(std.testing.allocator, scratch, std.testing.io, o, .{ .text = "pub fn eval() void {}\n" }, false);
}

/// Writes a two-file module tree, its root importing a sibling, under
/// `sub` of `dir`, creating the files in `order`.
fn writeModuleTree(io: Io, dir: Io.Dir, sub: []const u8, order: enum { root_first, sibling_first }) !void {
    var buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, "{s}/c.zig", .{sub});
    try dir.createDirPath(io, sub);
    const sibling = "pub const k: f64 = 2.0;\n";
    var sbuf: [256]u8 = undefined;
    const sib = try std.fmt.bufPrint(&sbuf, "{s}/inner/k.zig", .{sub});
    var dbuf: [256]u8 = undefined;
    try dir.createDirPath(io, try std.fmt.bufPrint(&dbuf, "{s}/inner", .{sub}));
    switch (order) {
        .root_first => {
            try dir.writeFile(io, .{ .sub_path = root, .data = "pub const k = @import(\"inner/k.zig\").k;\n" });
            try dir.writeFile(io, .{ .sub_path = sib, .data = sibling });
        },
        .sibling_first => {
            try dir.writeFile(io, .{ .sub_path = sib, .data = sibling });
            try dir.writeFile(io, .{ .sub_path = root, .data = "pub const k = @import(\"inner/k.zig\").k;\n" });
        },
    }
}

// The oracle is metamorphic: the key must move when an imported file's bytes
// move, and must not move under a change that cannot reach the compiler (a
// second run, a relocated tree, another creation order, a cache directory).
// The end-to-end oracle, a library loaded and called after a sibling edit, is
// library.zig's artifact_cache test.

test "key: an edit to a file the module root imports changes the key; no edit keeps it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeModuleTree(io, tmp.dir, "a", .root_first);
    const root = try arena.allocator().print(".zig-cache/tmp/{s}/a/c.zig", .{tmp.sub_path});
    const mods = [_]argv.Module{.{ .name = "contract", .root = root }};

    const first = (try keyOf(arena.allocator(), &mods)).?;
    try std.testing.expectEqual(first, (try keyOf(arena.allocator(), &mods)).?);

    try tmp.dir.writeFile(io, .{ .sub_path = "a/inner/k.zig", .data = "pub const k: f64 = 3.0;\n" });
    const edited = (try keyOf(arena.allocator(), &mods)).?;
    try std.testing.expect(first != edited);

    // Build output beside the sources is not an input.
    try tmp.dir.createDirPath(io, "a/.zig-cache/o");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/.zig-cache/o/x.zig", .data = "junk" });
    try std.testing.expectEqual(edited, (try keyOf(arena.allocator(), &mods)).?);

    // A new file the root could import is an input.
    try tmp.dir.writeFile(io, .{ .sub_path = "a/new.zig", .data = "" });
    try std.testing.expect(edited != (try keyOf(arena.allocator(), &mods)).?);
}

test "key: a relocated tree, written in another order, keys the same" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeModuleTree(io, tmp.dir, "one", .root_first);
    try writeModuleTree(io, tmp.dir, "two/deeper", .sibling_first);
    const a = try arena.allocator().print(".zig-cache/tmp/{s}/one/c.zig", .{tmp.sub_path});
    const b = try arena.allocator().print(".zig-cache/tmp/{s}/two/deeper/c.zig", .{tmp.sub_path});
    try std.testing.expectEqual(
        (try keyOf(arena.allocator(), &.{.{ .name = "contract", .root = a }})).?,
        (try keyOf(arena.allocator(), &.{.{ .name = "contract", .root = b }})).?,
    );
}

test "key: a module tree past the file bound is not keyed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "big");
    var name: [32]u8 = undefined;
    for (0..tree_files_max + 1) |i| {
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "big/{d}.zig", .{i}), .data = "" });
    }
    const root = try arena.allocator().print(".zig-cache/tmp/{s}/big/0.zig", .{tmp.sub_path});
    try std.testing.expectEqual(@as(?u64, null), try keyOf(arena.allocator(), &.{.{ .name = "contract", .root = root }}));
}
