//! The fixture walk: a fixture root and its language directories -> one
//! `Fixture` row per file that carries a `//!` directive (`collect`), and
//! VerA's own expected-failure list (`xfail_list`, `listedXfail`), which
//! stands in for the `//! xfail` lines the suite does not carry.
//! `Fixtures.zig` re-exports all four for the runners.
//!
//! Contents:
//! - `pub const xfail_list`
//! - `pub fn listedXfail(arena: std.mem.Allocator, io: Io, root: []const u8, path: []const u8) !?[]const u8`
//! - `pub fn collect(arena: std.mem.Allocator, io: Io, root: []const u8, dirs: []const []const u8, filter: ?[]const u8) ![]const Fixture`
//! - `pub fn hasDirective(source: []const u8) bool`

const std = @import("std");
const Devices = @import("Devices.zig");
const digital = @import("Digital.zig");
const Fixtures = @import("Fixtures.zig");
const options = @import("suite_options");

const Io = std.Io;
const Fixture = Fixtures.Fixture;

/// VerA's own expected failures. The suite carries no `//! xfail` lines (a
/// tool's known failures are its `tools/<tool>.xfail`), so this list is VerA's:
/// one path a line, relative to the suite root (`tests/verilog/16_sdf/x.v`),
/// the reason after `#`; a line starting `#` is a comment. A fixture listed
/// here is judged exactly as if it carried `//! xfail <reason>`.
pub const xfail_list = options.repo_root ++ "/tests/suite.xfail";

/// The reason `xfail_list` gives the fixture at `path` under `root` (the
/// suite's `tests/`, so the key is `path` relative to `root`'s parent): ""
/// for a bare line, null when it is not listed. Read per call: the file is a
/// few lines, and a run's workers then share nothing.
pub fn listedXfail(arena: std.mem.Allocator, io: Io, root: []const u8, path: []const u8) !?[]const u8 {
    const suite_root = std.fs.path.dirname(root) orelse return null;
    if (!std.mem.startsWith(u8, path, suite_root)) return null;
    const text = Io.Dir.cwd().readFileAlloc(io, xfail_list, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return xfailIn(text, std.mem.trimStart(u8, path[suite_root.len..], "/"));
}

/// Every fixture under `dirs` of `root` (`ams_dirs`; `&.{""}` is the whole
/// root), sorted by path so the run is deterministic (`Dir.walk` order is
/// explicitly undefined) and a failing run is reproducible and diffable. A
/// test in two language directories is two fixtures. `filter` is a plain
/// substring over the whole path: `zig build suite -- ch04` runs one
/// group. The rows and their strings live in `arena`; a missing directory
/// contributes nothing.
pub fn collect(arena: std.mem.Allocator, io: Io, root: []const u8, dirs: []const []const u8, filter: ?[]const u8) ![]const Fixture {
    // `fixtureExt` reads each `.va` and golden-less `.v` whole to look for a directive.
    // Those reads are dead once it answers, so they go to a scratch arena
    // reset per file instead of living in `arena` for the whole run.
    var scratch: std.heap.ArenaAllocator = .init(arena);
    var list: std.ArrayList(Fixture) = .empty;
    for (dirs) |sub| {
        var dir = Io.Dir.cwd().openDir(io, try std.fs.path.join(arena, &.{ root, sub }), .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            // IEEE 1364's `.v` is the `devices` modes' own; only its `.va` is here.
            if (std.mem.eql(u8, sub, Devices.ieee1364_dir) and !std.mem.endsWith(u8, entry.path, ".va")) continue;
            _ = scratch.reset(.retain_capacity);
            const ext = fixtureExt(scratch.allocator(), io, dir, entry.path) orelse continue;
            const rel = try std.fs.path.join(arena, &.{ sub, entry.path });
            const path = try std.fs.path.join(arena, &.{ root, rel });
            if (filter) |f| if (std.mem.find(u8, path, f) == null) continue;
            const slug = try arena.dupe(u8, rel[0 .. rel.len - ext.len]);
            std.mem.replaceScalar(u8, slug, '/', '_');
            std.mem.replaceScalar(u8, slug, '\\', '_');
            try list.append(arena, .{ .path = path, .root = root, .slug = slug });
        }
    }
    std.mem.sort(Fixture, list.items, {}, struct {
        fn lt(_: void, a: Fixture, b: Fixture) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return list.items;
}

/// Does this source carry a `//!` directive? `tb.Spec.parse`'s own line rule, and it
/// must stay that rule: this decides whether a file is collected and `tb.Spec.parse`
/// decides whether it asserts anything, so a disagreement collects a fixture
/// that then reports nothing.
pub fn hasDirective(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, raw, " \t\r"), "//!")) return true;
    }
    return false;
}

// ---- private ----

/// `listedXfail`'s lookup of `rel` in the list's `text`.
fn xfailIn(text: []const u8, rel: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const hash = std.mem.findScalar(u8, line, '#') orelse line.len;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..hash], " \t"), rel)) continue;
        return std.mem.trim(u8, line[@min(hash + 1, line.len)..], " \t");
    }
    return null;
}

/// Is this path a fixture for the accept/reject walk, and if so what extension
/// does its stem end at? `null` means "not this walk's business".
///
/// `.va` is a fixture when it carries a directive: a `.va` with none is a
/// design a host test loads (a `//! device` line of a `*_host.zig`, the VPI walk's
/// `vpi_design.va`), the same rule as item 3 below. `.v` is the awkward one,
/// because three different things share that extension in
/// `verilog-ams/digital/` (IEEE 1364's `verilog/` is not walked for `.v`):
///
///   1. Files with a `<stem>.expected.txt` beside them, or a `//! reject`
///      line (`Digital.negative`), belong to `zig build suite -- devices`
///      (`Devices.digitalCases`), not here.
///   2. Other files with a directive are judged here: `//! expect vcd` rows
///      by `judgeVcd`, the rest by the usual algebra.
///   3. Files with no directive (VPI support designs such as `design.v`)
///      are not fixtures.
///
/// The whole file is scanned with `tb.Spec.parse`'s line rule (see `hasDirective`).
fn fixtureExt(arena: std.mem.Allocator, io: Io, dir: Io.Dir, rel: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, rel, ".va")) {
        const source = dir.readFileAlloc(io, rel, arena, .limited(1 << 20)) catch return null;
        return if (hasDirective(source)) ".va" else null;
    }
    if (!std.mem.endsWith(u8, rel, ".v")) return null;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const stem = rel[0 .. rel.len - ".v".len];
    const golden = std.mem.print(&buf, "{s}.expected.txt", .{stem}) catch return null;
    if (dir.access(io, golden, .{})) |_| return null else |_| {}

    const source = dir.readFileAlloc(io, rel, arena, .limited(1 << 20)) catch return null;
    // A digital negative belongs to the devices' `--run` runner.
    if (digital.negative(source)) return null;
    return if (hasDirective(source)) ".v" else null;
}

test "the xfail list: a path, its reason after `#`, comments skipped" {
    const text = "# VerA's\ntests/verilog/16_sdf/a.v # SDF is refused.\n  tests/verilog/b.v\n";
    try std.testing.expectEqualStrings("SDF is refused.", xfailIn(text, "tests/verilog/16_sdf/a.v").?);
    try std.testing.expectEqualStrings("", xfailIn(text, "tests/verilog/b.v").?);
    try std.testing.expect(xfailIn(text, "tests/verilog/16_sdf") == null);
    try std.testing.expect(xfailIn(text, "# VerA's") == null);
}

test "a directive is found after the hand-derivation, not just in a header" {
    // Directives follow the header's LRM quote and derivation, often kilobytes
    // into the file, so the whole file must be scanned.
    var prose: [4096]u8 = @splat('x');
    const late = try std.testing.allocator.print(
        "// {s}\n//! reject E0205\n",
        .{prose[0..]},
    );
    defer std.testing.allocator.free(late);
    try std.testing.expect(hasDirective(late));

    try std.testing.expect(hasDirective("//! reject E0205\n"));
    try std.testing.expect(hasDirective("  \t //! lrm 9.4.1\r\n"));

    // A design a test loads is not a fixture: no directive, no collection.
    try std.testing.expect(!hasDirective("module m; endmodule\n"));
    try std.testing.expect(!hasDirective(""));

    // `//!` has to START the trimmed line. A plain substring search would take
    // this string literal for a directive and collect a file that asserts
    // nothing.
    try std.testing.expect(!hasDirective("initial $display(\"//! reject\");\n"));
}

test "digital opt-in is excluded from analog fixture collection" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const marked = "//! reject no arguments\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "negative.v", .data = marked });
    try tmp.dir.writeFile(io, .{ .sub_path = "dump.v", .data = "//! expect vcd a.vcd == a.golden.vcd\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "analog.va", .data = marked });
    try tmp.dir.writeFile(io, .{ .sub_path = "positive.v", .data = "//! lrm 9.10\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "positive.expected.txt", .data = "ok\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "host_design.va", .data = "module m; endmodule\n" });
    try std.testing.expect(fixtureExt(arena.allocator(), io, tmp.dir, "negative.v") == null);
    try std.testing.expectEqualStrings(".v", fixtureExt(arena.allocator(), io, tmp.dir, "dump.v").?);
    try std.testing.expectEqualStrings(".va", fixtureExt(arena.allocator(), io, tmp.dir, "analog.va").?);
    try std.testing.expect(fixtureExt(arena.allocator(), io, tmp.dir, "positive.v") == null);
    // A `.va` a host test loads carries no directive and is not collected.
    try std.testing.expect(fixtureExt(arena.allocator(), io, tmp.dir, "host_design.va") == null);
}
