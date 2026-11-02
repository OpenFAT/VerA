//! Width is what no parse nesting measures: a 5000-statement chain, a
//! 5000-arm `case` or a 5000-term sum is flat source, so a pass that walks
//! it one call per element runs on whatever stack its caller has, and an
//! embedder's thread may have 1 MiB. Three analog lowering walks and
//! device codegen's `renderSelLazy` overflowed exactly so (case_5000,
//! chainNext). Each shape goes through every pass VerA has for its
//! language on a 1 MiB thread: a `.va` through `--lint`, `--emit-zig`,
//! the `--emit-so` tree and `--emit-verilog`; the `.v` analogue through
//! `--elab`, `--run` and `--emit-rtlil`. N-deep nesting is the comparison
//! row: depth is measured, so `lib/base/deep_stack.zig` runs it on a stack
//! sized for it, "not bounded by the calling thread's stack".
//!
//! The oracle is the stack: a recursion per element overflows it and the
//! row's child dies on the guard page (a signal, BAD). A pass that returns
//! must have succeeded, and an emitter's text must hold the last
//! element's constant, so a pass that stopped early is caught too.
//!
//! Contents:
//! - `pub const known`
//! - `pub fn rows(arena: Allocator, exe: []const u8, dir: []const u8) ![]const table.Row`

const std = @import("std");
const vera = @import("vera");
const zigbuild = @import("zigbuild");
const digital = @import("sim").digital;
const native = @import("digital");
const table = @import("table.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Rows that fail on a real bug, with the bug. Empty is the goal.
pub const known: []const table.Known = &.{};

/// 2500 arms already overflowed 1 MiB in codegen, 5000 in analog lowering.
const n = 5000;
const stack_bytes = 1 << 20;
const Shape = enum { chain, case_arms, sum, elsif, nest };
const Pass = enum { lint, emit_zig, emit_so_tree, emit_verilog, elab, run, emit_rtlil };
const analog_passes = [_]Pass{ .lint, .emit_zig, .emit_so_tree, .emit_verilog };
const digital_passes = [_]Pass{ .elab, .run, .emit_rtlil };

/// One row, run by `go` on the 1 MiB thread: `why` is empty when it held.
const Row = struct {
    shape: Shape,
    pass: Pass,
    dir: []const u8,
    io: Io,
    why: []const u8 = "",

    fn go(r: *Row) void {
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        r.why = r.pass_(arena_state.allocator()) catch |e| @errorName(e);
        // `why` must outlive the arena.
        r.why = std.heap.page_allocator.dupe(u8, r.why) catch "OutOfMemory";
    }

    fn pass_(r: *Row, arena: Allocator) ![]const u8 {
        const gpa = std.heap.page_allocator;
        const io = r.io;
        var last_buf: [16]u8 = undefined;
        switch (r.pass) {
            .lint, .emit_zig, .emit_so_tree, .emit_verilog => {
                const source = try analog(arena, r.shape);
                var req: vera.Request = .{ .options = .{ .file_name = "m.va" } };
                switch (r.pass) {
                    .lint => {},
                    .emit_zig, .emit_so_tree => req.zig = true,
                    .emit_verilog => req.verilog = .{},
                    else => unreachable,
                }
                var bag: vera.diag.Bag = .init(gpa);
                defer bag.deinit(gpa);
                var o: vera.Outcome = .{};
                defer o.deinit(gpa);
                try vera.compile(gpa, io, arena, source, req, &bag, &o);
                if (o.status != 0 or bag.failed()) return arena.print("refused (status {d}): {s}", .{ o.status, o.err });
                if (r.pass == .emit_so_tree) {
                    const dir = try std.fs.path.join(arena, &.{ r.dir, @tagName(r.shape) });
                    if (try zigbuild.writeTree(gpa, io, .{ .work_dir = dir, .name = "m" }, o.device.?.output) == 0) return "the tree has no files";
                    return "";
                }
                // `--emit-verilog` models the ports, not the analog body.
                if (r.pass == .lint or r.pass == .emit_verilog) return "";
                const last = try std.fmt.bufPrint(&last_buf, "{d}.5", .{n - 1});
                if (std.mem.find(u8, o.text, last) == null) return arena.print("the text does not hold the last element's {s}", .{last});
                return "";
            },
            .elab, .run, .emit_rtlil => {
                const source = try design(arena, r.shape);
                const opts: digital.Options = .{ .file_name = "t.v", .io = io };
                var bag: vera.diag.Bag = .init(arena);
                var sink: Io.Writer.Discarding = .init(&.{});
                switch (r.pass) {
                    .elab => _ = try digital.elaborate(arena, source, opts, &bag, &sink.writer),
                    .run => try digital.run(arena, source, opts, &bag, &sink.writer),
                    .emit_rtlil => {
                        const text = native.rtlil.emit(arena, source, opts, &bag) catch |e| switch (e) {
                            error.Refused => return arena.print("refused: {t} {s}", .{ bag.at(0).code, bag.at(0).message }),
                            else => |x| return x,
                        };
                        // RTLIL writes a constant in decimal or as 32 binary digits.
                        const last = try std.fmt.bufPrint(&last_buf, "{d}", .{n - 1});
                        var bits_buf: [40]u8 = undefined;
                        const bits = try std.fmt.bufPrint(&bits_buf, "32'{b:0>32}", .{n - 1});
                        if (std.mem.find(u8, text, last) == null and std.mem.find(u8, text, bits) == null)
                            return arena.print("the text does not hold the last element's {s}", .{last});
                    },
                    else => unreachable,
                }
                if (bag.failed()) return "refused: diagnostics";
                return "";
            },
        }
    }
};

/// Every shape through every pass of its language.
pub fn rows(arena: Allocator, exe: []const u8, dir: []const u8) ![]const table.Row {
    var out: std.ArrayList(table.Row) = .empty;
    for (std.enums.values(Shape)) |s| for (analog_passes ++ digital_passes) |p| {
        var nb: [64]u8 = undefined;
        try out.append(arena, .{
            .name = try arena.dupe(u8, rowName(&nb, s, p)),
            .argv = try arena.dupe([]const u8, &.{ exe, dir, "wide", @tagName(s), @tagName(p) }),
        });
    };
    return out.items;
}

/// One row on a 1 MiB thread: "" when it held, else why not.
pub fn child(io: Io, dir: []const u8, shape: []const u8, pass: []const u8) ![]const u8 {
    const s = std.meta.stringToEnum(Shape, shape) orelse return error.UnknownShape;
    const p = std.meta.stringToEnum(Pass, pass) orelse return error.UnknownPass;
    var row: Row = .{ .shape = s, .pass = p, .dir = dir, .io = io };
    const t = try std.Thread.spawn(.{ .stack_size = stack_bytes }, Row.go, .{&row});
    t.join();
    return row.why;
}

// ---- private ----

/// `chain.va --emit-zig`: what a row is called on the command line and in
/// `known`.
fn rowName(buf: []u8, s: Shape, p: Pass) []const u8 {
    const ext = if (@backingInt(p) < @backingInt(Pass.elab)) "va" else "v";
    return std.fmt.bufPrint(buf, "{t}.{s} --{s}", .{ s, ext, flagOf(p) }) catch unreachable; // 64 bytes hold every name
}

fn flagOf(p: Pass) []const u8 {
    return switch (p) {
        .lint => "lint",
        .emit_zig => "emit-zig",
        .emit_so_tree => "emit-so-tree",
        .emit_verilog => "emit-verilog",
        .elab => "elab",
        .run => "run",
        .emit_rtlil => "emit-rtlil",
    };
}

/// A `.va` of shape `s`, N wide (N deep for `nest`); its last element's
/// constant is `(n - 1).5`.
fn analog(arena: Allocator, s: Shape) ![]u8 {
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena, "module m(p, n);\n  inout p, n;\n  electrical p, n;\n  real y;\n  integer k;\n  analog begin\n    y = V(p, n);\n    k = V(p, n);\n");
    try body(arena, &src, s, ".5");
    try src.appendSlice(arena, "    I(p, n) <+ y * V(p, n);\n  end\nendmodule\n");
    return src.items;
}

/// The `.v` analogue: the same shape in a combinational `always`.
fn design(arena: Allocator, s: Shape) ![]u8 {
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena, "module t(input [31:0] a, input [31:0] k, output reg [31:0] y);\n  always @(*) begin\n    y = a;\n");
    try body(arena, &src, s, "");
    try src.appendSlice(arena, "  end\nendmodule\n");
    return src.items;
}

/// The shape's statements over `y`, `k` and a term `t` (`V(p, n)` or `a`),
/// each element's constant `i` then `frac`.
fn body(arena: Allocator, src: *std.ArrayList(u8), s: Shape, frac: []const u8) !void {
    const t = if (frac.len != 0) "V(p, n)" else "a";
    switch (s) {
        .chain => for (0..n) |i| try src.print(arena, "    y = y + {d}{s};\n", .{ i, frac }),
        .case_arms => {
            try src.appendSlice(arena, "    case (k)\n");
            for (0..n) |i| try src.print(arena, "      {d}: y = {d}{s};\n", .{ i, i, frac });
            try src.appendSlice(arena, "    endcase\n");
        },
        .sum => {
            try src.appendSlice(arena, "    y = y");
            for (0..n) |i| try src.print(arena, " + {d}{s} * {s}", .{ i, frac, t });
            try src.appendSlice(arena, ";\n");
        },
        .elsif => for (0..n) |i| try src.print(arena, "    {s}if (k == {d}) y = {d}{s};\n", .{ if (i == 0) "" else "else ", i, i, frac }),
        .nest => {
            for (0..n) |_| try src.appendSlice(arena, "begin ");
            try src.print(arena, "y = y + {d}{s};", .{ n - 1, frac });
            for (0..n) |_| try src.appendSlice(arena, " end");
            try src.appendSlice(arena, "\n");
        },
    }
}

test "the shapes hold the last element's constant; the row names" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (std.enums.values(Shape)) |s| {
        const a = try analog(arena, s);
        const d = try design(arena, s);
        try std.testing.expect(std.mem.find(u8, a, "4999.5") != null);
        try std.testing.expect(std.mem.find(u8, d, "4999") != null);
    }
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("chain.va --emit-zig", rowName(&buf, .chain, .emit_zig));
    try std.testing.expectEqualStrings("sum.v --emit-rtlil", rowName(&buf, .sum, .emit_rtlil));
}
