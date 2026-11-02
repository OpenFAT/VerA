//! The `vpi` mode: every `.c` fixture under `vpi_dirs`, compiled (not linked or
//! run) against src/vpi/vpi_user.h, so the ABI the LRM describes is checked by
//! a C compiler. The fixtures that run are `build.zig`'s `vpi_runs`.
//!
//!   zig build suite -- vpi           # all of them
//!   zig build suite -- vpi p03    # the ones whose name contains p03

const Fixtures = @import("Fixtures.zig");
const Child = @import("Child.zig");
const std = @import("std");
const options = @import("suite_options");
const Io = std.Io;
const Args = std.process.Args.Iterator;

const harness = Fixtures;
const child = Child;

/// Directories under the fixture root holding `.c` fixtures. Some groups
/// share a header beside them (`p02_check.h`, `p03_vpi_analog.h`,
/// `b_check.h`), so the fixture's own directory goes on the include path as
/// well as `src/vpi`.
const vpi_dirs = [_][]const u8{ "verilog-ams/ch11_vpi", "verilog-ams/ch12_vpi_routines", "verilog/pli" };

/// The `vpi` mode: compiles each `.c` fixture matching the filter in `args`
/// and prints one FAIL line per refusal and a census to stderr. Exit 1 on any
/// FAIL or when nothing matched.
pub fn run(init: std.process.Init, args: *Args) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var filter: ?[]const u8 = null;
    while (args.next()) |a| filter = a;

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    // One object path, reused: the loop is sequential and nothing reads it.
    const work = options.work_root ++ "/vpi-fixtures";
    Io.Dir.cwd().createDirPath(io, work) catch {};
    const obj = try std.fs.path.join(arena_state.allocator(), &.{ work, "fixture.o" });
    const vpi_include = options.vpi_include;

    var ran: usize = 0;
    var failed: usize = 0;
    for (vpi_dirs) |sub| {
        const dir_path = try std.fs.path.join(gpa, &.{ options.fixture_root, sub });
        defer gpa.free(dir_path);
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        // Sorted, so a failing run is reproducible and its name list diffs.
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
            try names.append(gpa, try arena_state.allocator().dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, harness.strLess);

        for (names.items) |name| {
            if (filter) |f| if (std.mem.find(u8, name, f) == null) continue;
            ran += 1;
            const pa = arena_state.allocator();
            const src = try std.fs.path.join(pa, &.{ dir_path, name });
            // `-c -o`, not `-fsyntax-only`: `zig cc` passes its own `-c`, which
            // `-fsyntax-only` leaves unused, and `-Werror` fails every fixture on
            // that warning. The flags are `vpi_app.c`'s, so no fixture passes
            // here that the acceptance test's flags would refuse.
            const r = child.capture(pa, io, &.{
                options.zig_exe, "cc",     "-std=c99", "-Wall", "-Werror",
                "-c",            "-o",     obj,        "-I",    vpi_include,
                "-I",            dir_path, src,
            }) catch |e| {
                try w.print("FAIL {s}: could not run the C compiler: {s}\n", .{ name, @errorName(e) });
                failed += 1;
                continue;
            };
            if (r.exit == 0) continue;
            failed += 1;
            // One line of the compiler's words; the full log would bury the census.
            const first = std.mem.trim(u8, firstErrorLine(r.stderr), " \t\r");
            try w.print("FAIL {s}: {s}\n", .{ name, first });
        }
    }

    if (ran == 0) {
        try w.print("vpi: nothing matched `{s}`\n", .{filter orelse ""});
        return 1;
    }
    try w.print("vpi: {d}/{d} fixtures compile against src/vpi/vpi_user.h\n", .{ ran - failed, ran });
    return if (failed == 0) 0 else 1;
}

// ---- private ----

/// The compiler's first `error:` line, or its first line if it never said one.
fn firstErrorLine(stderr: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |l| if (std.mem.find(u8, l, "error:") != null) return l;
    var again = std.mem.splitScalar(u8, stderr, '\n');
    return again.next() orelse "";
}

test "the first error line is the compiler's, not the last line of a log" {
    const log =
        \\p02_01.c:77:24: note: expanded from here
        \\p02_01.c:77:24: error: unknown type name 'p_cb_data'
        \\p02_01.c:93:14: error: use of undeclared identifier 'vpiBinStrVal'
        \\1 error generated.
    ;
    try std.testing.expectEqualStrings(
        "p02_01.c:77:24: error: unknown type name 'p_cb_data'",
        firstErrorLine(log),
    );
    // A compiler that failed without the word `error:` still has to report
    // something, or a FAIL row would be a bare name.
    try std.testing.expectEqualStrings("cc: killed", firstErrorLine("cc: killed\n"));
    try std.testing.expectEqualStrings("", firstErrorLine(""));
}
