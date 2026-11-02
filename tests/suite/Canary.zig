//! The canary in `zig build test`: the judge judged. `tests/canary/`
//! holds fixtures that are wrong on purpose (VerA's own, outside the suite's
//! `tests/`), and its `EXPECT.tsv` says what the harness must answer for each
//! -> exit 0 only when every answer is the expected one.
//!
//! A suite that cannot say FAIL proves nothing by saying PASS: each row here
//! is a way a fixture can look green while asserting nothing, and the run
//! fails the day the harness stops catching it.
//!
//! EXPECT.tsv: `<file>\t<normal|perturb>\t<pass | substring of the FAIL text>`.
//! `perturb` runs the row as `benchmark -- --perturb` would.

const Fixtures = @import("Fixtures.zig");
const Analog = @import("Analog.zig");
const std = @import("std");
const options = @import("suite_options");
const harness = Fixtures;
const torture = Analog;

const Io = std.Io;

const Row = struct { file: []const u8, perturb: bool, want: []const u8 };

/// Judges every canary and compares each verdict and its text with its row.
pub fn run(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    const root = options.repo_root ++ "/tests/canary";
    const table = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ root, "EXPECT.tsv" }), arena, .limited(1 << 16));
    const rows = try parse(arena, table);

    var cfg: harness.Config = .init();
    cfg.root = root;
    cfg.strict = true;
    var ctx: torture.Ctx = .{ .cfg = &cfg };
    defer ctx.deinit(gpa);
    const compiler = torture.compiler(&ctx);

    const fixtures = try harness.collect(arena, io, root, &.{""}, null);
    var bad: usize = 0;
    for (fixtures) |f| {
        const name = std.fs.path.basename(f.path);
        const row = for (rows) |r| {
            if (std.mem.eql(u8, r.file, name)) break r;
        } else {
            try w.print("CANARY {s}: no EXPECT.tsv row\n", .{name});
            bad += 1;
            continue;
        };
        harness.perturb = if (row.perturb) 1e-3 else null;
        defer harness.perturb = null;
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const v = try harness.judge(gpa, io, arena, compiler, f, true, &aw.writer);
        const text = aw.written();
        const ok = if (std.mem.eql(u8, row.want, "pass"))
            v == .pass
        else
            v == .fail and std.mem.find(u8, text, row.want) != null;
        if (ok) {
            try w.print("canary {s}: {t} as expected\n", .{ name, v });
        } else {
            try w.print("CANARY {s}: wanted {s}, the harness said {t}:\n{s}\n", .{ name, row.want, v, text });
            bad += 1;
        }
    }
    for (rows) |r| {
        for (fixtures) |f| {
            if (std.mem.eql(u8, std.fs.path.basename(f.path), r.file)) break;
        } else {
            try w.print("CANARY {s}: EXPECT.tsv row with no fixture\n", .{r.file});
            bad += 1;
        }
    }
    try w.print("\ncanary: {d}/{d} answered as expected\n", .{ fixtures.len - @min(bad, fixtures.len), fixtures.len });
    return if (bad == 0 and fixtures.len != 0) 0 else 1;
}

fn parse(arena: std.mem.Allocator, table: []const u8) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |raw| {
        // The submodule has no `eol=lf`, so a Windows checkout ends each row in CRLF.
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const file = cols.next() orelse return error.BadExpectRow;
        const mode = cols.next() orelse return error.BadExpectRow;
        const want = cols.next() orelse return error.BadExpectRow;
        const perturb = if (std.mem.eql(u8, mode, "perturb")) true else if (std.mem.eql(u8, mode, "normal")) false else return error.BadExpectRow;
        try rows.append(arena, .{ .file = file, .perturb = perturb, .want = want });
    }
    return rows.items;
}

test "EXPECT.tsv rows: three columns, a known mode" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try parse(arena_state.allocator(), "# comment\na.va\tnormal\tpass\nb.va\tperturb\tLOOSE b\n");
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expect(rows[1].perturb);
    try std.testing.expectEqualStrings("LOOSE b", rows[1].want);
    // A CRLF checkout (Windows) reads the same want, with no `\r` left on it.
    const crlf = try parse(arena_state.allocator(), "a.va\tnormal\tpass\r\nb.va\tperturb\tLOOSE b\r\n");
    try std.testing.expectEqualStrings("LOOSE b", crlf[1].want);
    try std.testing.expectError(error.BadExpectRow, parse(arena_state.allocator(), "a.va\tsideways\tpass\n"));
    try std.testing.expectError(error.BadExpectRow, parse(arena_state.allocator(), "a.va\tnormal\n"));
}
