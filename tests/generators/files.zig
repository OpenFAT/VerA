//! Every location carries a 16-bit file id, so a compilation holds
//! `diag.files_max` (65535) files, and each `include registers its file
//! again: one header included 65536 times is past the table. An include
//! tree is input, so that is E0154 (`lib/diag/code.zig`), never a crash;
//! the oracle is that code in the bag of both front ends.

const std = @import("std");
const vera = @import("vera");
const digital = @import("sim").digital;

const Allocator = std.mem.Allocator;

// ---- private ----

/// `n` `include lines of `h.vh`, then `tail`.
fn includes(arena: Allocator, n: usize, tail: []const u8) ![]const u8 {
    var src: std.ArrayList(u8) = .empty;
    for (0..n) |_| try src.appendSlice(arena, "`include \"h.vh\"\n");
    try src.appendSlice(arena, tail);
    return src.items;
}

fn hasCode(bag: *const vera.diag.Bag, code: vera.diag.Code) bool {
    for (0..bag.count()) |i| if (bag.at(i).code == code) return true;
    return false;
}

test "E0154: an include tree past 65535 files is a coded refusal in both front ends, not a crash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "h.vh", .data = "" });
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const past = vera.diag.files_max; // includes: with the source, one file past the table

    var bag: vera.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var o: vera.Outcome = .{};
    defer o.deinit(gpa);
    const source = try includes(arena, past, "module m; endmodule\n");
    try vera.compile(gpa, io, arena, source, .{ .options = .{ .file_name = "m.va", .include_dirs = &.{dir} } }, &bag, &o);
    try std.testing.expect(o.status != 0);
    try std.testing.expect(hasCode(&bag, .E0154));

    var dbag: vera.diag.Bag = .init(arena);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const design = try includes(arena, past, "module t; endmodule\n");
    try std.testing.expectError(error.DigitalFailed, digital.elaborate(arena, design, .{ .file_name = "t.v", .include_dirs = &.{dir}, .io = io }, &dbag, &sink.writer));
    try std.testing.expect(hasCode(&dbag, .E0154));

    // One file fewer is inside the table.
    var ok: vera.diag.Bag = .init(arena);
    _ = try digital.elaborate(arena, try includes(arena, past - 1, "module t; endmodule\n"), .{ .file_name = "t.v", .include_dirs = &.{dir}, .io = io }, &ok, &sink.writer);
    try std.testing.expect(!hasCode(&ok, .E0154));
}
