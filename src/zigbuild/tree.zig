//! The device tree on disk: generated device text (`Output`) in, the files a
//! library build compiles out (`<work_dir>/{shim.zig, device.zig, h.zig,
//! u/<unit>.zig ...}`), each written only when its bytes changed, so `zig`'s
//! per-file ZIR cache (keyed on inode, size and mtime) skips every unchanged
//! unit. Also the file-name stem of a module name. Cites §2.8 and §2.8.1 (the
//! identifiers a stem must take) and no other clause.
//!
//! Contents:
//! - `pub const Output = struct`
//! - `pub const Tree = struct { work_dir, name, engine }`
//! - `pub const TreeError`
//! - `pub const units_max: u32`
//! - `pub fn writeTree(gpa: Allocator, io: Io, tree: Tree, device: Output) TreeError!u32`
//! - `pub fn writeIfChanged(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8) WriteError!bool`
//! - `pub const WriteError`
//! - `pub fn fileStem(arena: Allocator, name: []const u8) Allocator.Error![]const u8`
//! - `pub fn splitOutput(names: []const []const u8) Output` (test support)

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const shim = @import("shim.zig");

/// The generated device, plus the per-unit columns that let `writeTree` write
/// it as one file per unit declaration. `text` stays the single contiguous
/// emission `--emit-zig` writes verbatim; the split is a view over it.
/// Codegen produces it (`codegen.generate`), and it outlives every build
/// that reads it.
///
/// Invariant (asserted by `writeTree`): the four unit columns have one row
/// per unit, and the ranges tile `text` in order, `unit_lo[i] ==
/// unit_hi[i-1]`, so `text[0..unit_lo[0]]` is the prologue and
/// `text[unit_hi[n-1]..]` the dispatcher tail. With no units every column is
/// empty and `prelude` and `helpers` are unused.
pub const Output = struct {
    /// The whole device, under 4 GiB (the offsets are `u32`).
    text: []const u8,
    /// One per emitted unit declaration, in emission order: both the
    /// declaration name and the file stem, so the file set changes exactly
    /// when `ir/names.zig`'s keys do.
    names: []const []const u8 = &.{},
    /// Offset in `text` where each unit's declaration starts.
    unit_lo: []const u32 = &.{},
    /// Offset of each declaration's keyword: `writeTree` splices `pub ` in
    /// here, because `text`, the stand-alone device, may publish only names
    /// `contract.rejectStrayPubDecls` allows.
    unit_fn: []const u32 = &.{},
    /// Offset in `text` just past each unit's declaration.
    unit_hi: []const u32 = &.{},
    /// The file-scope prologue every `u/<unit>.zig` needs: a unit file is a
    /// separate Zig file, and nothing `device.zig` declares is in its scope.
    prelude: []const u8 = "",
    /// `h.zig`: the §4.3/§4.5 helper kernels, public, for the unit files to
    /// alias. `device.zig` keeps a private copy inline.
    helpers: []const u8 = "",
    /// How many chunks `setup` was emitted as (`setup_chunks.n`), at most
    /// `shim.setup_chunks_max`; 0 when it is one function. A split build
    /// compiles each in its own object.
    setup_chunks: u32 = 0,
};

/// Where `writeTree` writes and what its shim declares. Strings are borrowed.
pub const Tree = struct {
    /// Created if absent.
    work_dir: []const u8,
    /// The device name the shim exports the device under.
    name: []const u8,
    /// Whether the library links `sim`'s prebuilt engine object.
    engine: shim.Engine = .none,
};

/// Every way `writeIfChanged` fails: the file could not be written. A read
/// failure is not one: the file is then written.
pub const WriteError = Allocator.Error || Io.Dir.WriteFileError;

/// Every way `writeTree` fails, the file system's errors as std names them.
/// Files written before the failure stay written; a rerun writes the rest.
pub const TreeError = WriteError || Io.Dir.CreateDirPathError || Io.Dir.OpenError ||
    Io.Dir.Iterator.Error || Io.Dir.DeleteFileError || error{
    /// `u/` holds more than `unit_dir_entries_max` entries, so it is not
    /// the directory VerA writes.
    UnitDirTooLarge,
};

/// Most units one device may be written as; codegen emits far fewer (a large
/// compact model has a few hundred).
pub const units_max: u32 = 1 << 20;

/// The directory of unit files under the work directory.
const unit_dir = "u";

/// Most entries `pruneUnits` reads in `u/` before it refuses the directory.
const unit_dir_entries_max: u32 = 2 * units_max;

comptime {
    assert(unit_dir_entries_max > units_max);
}

/// The pieces of `splitOutput`'s device.
const split_prologue =
    \\const contract = @import("contract");
    \\pub const k2: f64 = 2.0;
    \\
;
const split_unit_a =
    \\fn unit_a(y: f64) f64 {
    \\    return y * k2;
    \\}
    \\
;
const split_unit_b =
    \\fn unit_b(y: f64) f64 {
    \\    return y + k2;
    \\}
    \\
;
const split_tail =
    \\pub fn eval(x: f64) callconv(.c) f64 {
    \\    return unit_a(x) + unit_b(x);
    \\}
    \\
;
const split_prelude = "const dev = @import(\"../device.zig\");\nconst k2 = dev.k2;\n";

/// Writes the device tree under `tree.work_dir` and returns how many files
/// changed on disk; an unchanged device writes 0. A device with units gets
/// `h.zig` and one `u/<unit>.zig` per unit, which `device.zig` imports by its
/// stable name, and loses every `u/*.zig` no longer emitted; one without is
/// written as `device.zig` alone. Fails as `TreeError` says.
/// Asserts that `device` keeps `Output`'s invariant.
pub fn writeTree(gpa: Allocator, io: Io, tree: Tree, device: Output) TreeError!u32 {
    assert(tree.work_dir.len > 0);
    assert(device.text.len <= std.math.maxInt(u32));
    const cwd: Io.Dir = .cwd();
    try cwd.createDirPath(io, tree.work_dir);
    var dir = try cwd.openDir(io, tree.work_dir, .{});
    defer dir.close(io);

    var writes: u32 = 0;
    const shim_text = try shim.device(gpa, tree.name, tree.engine);
    defer gpa.free(shim_text);
    writes += @intFromBool(try writeIfChanged(gpa, io, dir, "shim.zig", shim_text));

    if (device.names.len == 0) {
        assert(device.unit_lo.len == 0);
        assert(device.unit_fn.len == 0);
        assert(device.unit_hi.len == 0);
        writes += @intFromBool(try writeIfChanged(gpa, io, dir, "device.zig", device.text));
        assert(writes <= 2);
        return writes;
    }
    writes += try writeUnits(gpa, io, dir, device);
    assert(writes <= device.names.len + 3 + unit_dir_entries_max);
    return writes;
}

/// Writes `data` to `sub_path` in `dir` only when it differs from the file
/// there, and returns whether it wrote. Rewriting identical bytes would bump
/// the mtime and make `zig` run AstGen again. Asserts that `sub_path` is not
/// empty.
pub fn writeIfChanged(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8) WriteError!bool {
    assert(sub_path.len > 0);
    if (dir.readFileAlloc(io, sub_path, gpa, .limited(data.len + 1))) |old| {
        defer gpa.free(old);
        if (std.mem.eql(u8, old, data)) return false;
    } else |err| switch (err) {
        error.OutOfMemory => |e| return e,
        // Absent, unreadable, or longer than `data`: write it.
        else => {},
    }
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    return true;
}

/// Returns `name` as a file-name stem: `name` itself (borrowed) when it is at
/// most 128 bytes of `[A-Za-z0-9_]`, else its plain prefix (at most 64
/// bytes), a `-`, and 16 hex digits of its Wyhash, allocated in `arena`. §2.8
/// identifiers run to at least 1024 characters and §2.8.1 escaped ones hold
/// any printable byte, neither of which a file system takes as a name. A
/// hashed stem always holds the `-` no plain name does, so the two forms never
/// collide. Asserts that `name` is not empty: an empty stem names the
/// directory.
pub fn fileStem(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    assert(name.len > 0);
    const plain_len = plainPrefix(name);
    if (plain_len == name.len and name.len <= 128) return name;
    const stem = try arena.print("{s}-{x:0>16}", .{ name[0..@min(plain_len, 64)], std.hash.Wyhash.hash(0, name) });
    assert(std.mem.findScalar(u8, stem, '-') != null);
    return stem;
}

/// Test support: the two-unit device in the shape `codegen.generate`
/// produces (prologue, two tiling unit ranges, dispatcher tail), its columns
/// derived from the pieces' lengths. Asserts that `names` has two entries.
pub fn splitOutput(names: []const []const u8) Output {
    assert(names.len == 2);
    return .{
        .text = split_prologue ++ split_unit_a ++ split_unit_b ++ split_tail,
        .names = names,
        .unit_lo = &.{ split_prologue.len, split_prologue.len + split_unit_a.len },
        .unit_fn = &.{ split_prologue.len, split_prologue.len + split_unit_a.len },
        .unit_hi = &.{ split_prologue.len + split_unit_a.len, split_prologue.len + split_unit_a.len + split_unit_b.len },
        .prelude = split_prelude,
        .helpers = "pub const k3: f64 = 3.0;\n",
    };
}

// ---- private ----

/// Writes `h.zig`, every unit file, `device.zig` (prologue, one import per
/// unit, dispatcher tail), then prunes stale units; returns the files changed.
fn writeUnits(gpa: Allocator, io: Io, dir: Io.Dir, device: Output) TreeError!u32 {
    const n = device.names.len;
    assert(n <= units_max);
    assert(device.unit_lo.len == n);
    assert(device.unit_fn.len == n);
    assert(device.unit_hi.len == n);
    var writes: u32 = @intFromBool(try writeIfChanged(gpa, io, dir, "h.zig", device.helpers));

    try dir.createDirPath(io, unit_dir);
    var udir = try dir.openDir(io, unit_dir, .{ .iterate = true });
    defer udir.close(io);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (device.names, device.unit_lo, device.unit_fn, device.unit_hi, 0..) |name, lo, fn_at, hi, i| {
        assert(name.len > 0);
        assert(lo <= fn_at);
        assert(fn_at < hi);
        assert(hi <= device.text.len);
        if (i > 0) assert(lo == device.unit_hi[i - 1]);
        body.clearRetainingCapacity();
        try body.appendSlice(gpa, device.prelude);
        try body.appendSlice(gpa, device.text[lo..fn_at]);
        if (!std.mem.startsWith(u8, device.text[fn_at..], "pub ")) try body.appendSlice(gpa, "pub ");
        try body.appendSlice(gpa, device.text[fn_at..hi]);
        const file = try gpa.print("{s}.zig", .{name});
        defer gpa.free(file);
        writes += @intFromBool(try writeIfChanged(gpa, io, udir, file, body.items));
    }

    // The ranges tile, so prologue, imports and tail are the whole file.
    body.clearRetainingCapacity();
    try body.appendSlice(gpa, device.text[0..device.unit_lo[0]]);
    for (device.names) |name| {
        try body.print(gpa, "const {0s} = @import(\"{1s}/{0s}.zig\").{0s};\n", .{ name, unit_dir });
    }
    try body.appendSlice(gpa, "\n");
    try body.appendSlice(gpa, device.text[device.unit_hi[n - 1]..]);
    writes += @intFromBool(try writeIfChanged(gpa, io, dir, "device.zig", body.items));

    writes += try pruneUnits(gpa, io, udir, device.names);
    return writes;
}

/// Deletes each `u/*.zig` whose stem is not in `names` and returns the count:
/// a stale file would keep feeding `zig` a declaration nothing imports.
/// Collects first and deletes after, because changing a directory while
/// iterating it is unspecified on every file system this runs on.
// ponytail: O(files × units) membership scan. A device has ~100 units and the
// directory ~100 entries; a StringHashMap of `names` once one has thousands.
fn pruneUnits(gpa: Allocator, io: Io, udir: Io.Dir, names: []const []const u8) TreeError!u32 {
    var stale: std.ArrayList([]const u8) = .empty;
    defer {
        for (stale.items) |s| gpa.free(s);
        stale.deinit(gpa);
    }
    var it = udir.iterate();
    var entries: u32 = 0;
    while (try it.next(io)) |entry| : (entries += 1) {
        if (entries == unit_dir_entries_max) return error.UnitDirTooLarge;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const stem = entry.name[0 .. entry.name.len - ".zig".len];
        const live = for (names) |n| {
            if (std.mem.eql(u8, n, stem)) break true;
        } else false;
        if (live) continue;
        // Room first: a copy made before a failed append would leak.
        try stale.ensureUnusedCapacity(gpa, 1);
        stale.appendAssumeCapacity(try gpa.dupe(u8, entry.name));
    }
    assert(stale.items.len <= entries);
    for (stale.items) |s| try udir.deleteFile(io, s);
    return @intCast(stale.items.len);
}

fn plainPrefix(name: []const u8) usize {
    for (name, 0..) |c, i| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return i;
    }
    return name.len;
}

/// One `writeTree` of `out` with a stale unit file planted, for
/// `checkAllAllocationFailures`.
fn writeTreeOnce(gpa: Allocator, io: Io, dir: Io.Dir, tree: Tree, out: Output) !void {
    try dir.writeFile(io, .{ .sub_path = "u/old.zig", .data = "" });
    _ = try writeTree(gpa, io, tree, out);
}

// The oracle for the tree is the files read back: each unit file is the
// prelude plus exactly its slice of the emission (the slices written out by
// hand above), and the write counts are the files a reviewer expects to change.

test "writeTree splits per unit, and a no-op regeneration writes nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);
    const tree: Tree = .{ .work_dir = work, .name = "testdev" };

    const both = [_][]const u8{ "unit_a", "unit_b" };
    // shim + h.zig + 2 units + device.zig
    try std.testing.expectEqual(@as(u32, 5), try writeTree(gpa, io, tree, splitOutput(&both)));
    // Regenerating an unchanged device touches nothing on disk.
    try std.testing.expectEqual(@as(u32, 0), try writeTree(gpa, io, tree, splitOutput(&both)));

    const a = try tmp.dir.readFileAlloc(io, "u/unit_a.zig", gpa, .limited(4096));
    defer gpa.free(a);
    try std.testing.expectEqualStrings(split_prelude ++ "pub " ++ split_unit_a, a);

    // device.zig is prologue ++ imports ++ tail; the unit bodies are elsewhere.
    const dev = try tmp.dir.readFileAlloc(io, "device.zig", gpa, .limited(4096));
    defer gpa.free(dev);
    try std.testing.expect(std.mem.startsWith(u8, dev, split_prologue));
    try std.testing.expect(std.mem.endsWith(u8, dev, split_tail));
    try std.testing.expect(std.mem.find(u8, dev, "const unit_a = @import(\"u/unit_a.zig\").unit_a;\n") != null);
    try std.testing.expect(std.mem.find(u8, dev, "return y * k2;") == null);

    // A vanished unit takes its file with it: device.zig plus the delete.
    // `u/unit_a.zig` is unchanged, so it is not rewritten.
    const shrunk: Output = .{
        .text = split_prologue ++ split_unit_a ++ split_tail,
        .names = &.{"unit_a"},
        .unit_lo = &.{split_prologue.len},
        .unit_fn = &.{split_prologue.len},
        .unit_hi = &.{split_prologue.len + split_unit_a.len},
        .prelude = split_prelude,
        .helpers = "pub const k3: f64 = 3.0;\n",
    };
    try std.testing.expectEqual(@as(u32, 2), try writeTree(gpa, io, tree, shrunk));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "u/unit_b.zig", .{}));
}

test "writeTree frees everything and reports OutOfMemory at every allocation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.testing.allocator.dupe(u8, ".zig-cache/tmp/" ++ tmp.sub_path);
    defer std.testing.allocator.free(work);
    const tree: Tree = .{ .work_dir = work, .name = "testdev" };
    const out = splitOutput(&.{ "unit_a", "unit_b" });
    // A first write, so every later run reads the same files back.
    _ = try writeTree(std.testing.allocator, io, tree, out);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, writeTreeOnce, .{ io, tmp.dir, tree, out });
}
