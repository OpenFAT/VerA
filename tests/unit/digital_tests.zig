//! The emitter's tests: Verilog source -> `program`/`device`/`emitDevice`
//! text, checked for the rows, calls and refusals a construct must produce.
//! The oracle is the clause each test names; that the text runs as
//! `vera --run` does is the corpus's job (`zig build suite -- ieee1364 --native`).
//! Clauses: IEEE 1364-2005 §5.2.1, §7.3, §9.7.1, §9.7.5, §10.3, §11.4.2, §15.
const std = @import("std");
const testing = std.testing;
const sim = @import("sim");
const diag = @import("diag");
const Front = @import("frontend");
const digital = @import("digital");

/// `source` elaborated, its transcript discarded, and emitted as
/// `vera --emit-exe` would under `schedule` and `logic`. In `arena`.
fn emitted(arena: std.mem.Allocator, source: []const u8, schedule: digital.Schedule, logic: digital.Logic) !digital.Program {
    return emittedAs(arena, source, "<digital>", schedule, logic);
}

fn emittedAs(arena: std.mem.Allocator, source: []const u8, file_name: []const u8, schedule: digital.Schedule, logic: digital.Logic) !digital.Program {
    var bag = diag.Bag.init(arena);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var r = try sim.digital.elaborate(arena, source, .{}, &bag, &sink.writer);
    return digital.program(arena, &r, .{ .source = source, .file_name = file_name, .include_dirs = &.{}, .language = Front.keyword.default_keyword_set }, schedule, logic);
}

/// The native `.auto` root of `source`; fails when it falls back.
fn native(arena: std.mem.Allocator, source: []const u8, schedule: digital.Schedule) ![]const u8 {
    const p = try emitted(arena, source, schedule, .auto);
    try testing.expectEqual(@as(?[]const u8, null), p.fallback);
    return p.text;
}

fn has(text: []const u8, part: []const u8) !void {
    if (std.mem.find(u8, text, part) == null) {
        std.debug.print("missing: {s}\n", .{part});
        return error.TestExpectedEqual;
    }
}

fn lacks(text: []const u8, part: []const u8) !void {
    if (std.mem.find(u8, text, part) != null) {
        std.debug.print("unexpected: {s}\n", .{part});
        return error.TestExpectedEqual;
    }
}

/// `source`'s top module through `digital.device`: its root, or why not.
fn device(arena: std.mem.Allocator, source: []const u8) !digital.Device {
    var bag = diag.Bag.init(arena);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var r = try sim.digital.elaborate(arena, source, .{}, &bag, &sink.writer);
    return digital.device(arena, &r, "<digital>", .static);
}

test "program: a native design gets an rt main, no interpreter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try emitted(arena.allocator(), "module m; reg a; initial begin a = 1'b0; #1 a = 1'b1; $display(\"%b\", a); end endmodule", .static, .auto);
    try testing.expectEqual(@as(?[]const u8, null), p.fallback);
    try has(p.text, "pub fn main(");
    try lacks(p.text, "rt.interpret(");
}

test "program: a construct that is not native names itself and embeds the interpreter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // §9.5 over a real: a `logic.T` holds no real.
    const real_case = try emitted(a, "module m; real r; initial begin r = 1.0; case (r) 1.0: $display(\"one\"); endcase end endmodule", .static, .auto);
    try testing.expectEqualStrings("a real value", real_case.fallback.?);
    try has(real_case.text, "rt.interpret(");
    // §15: `rt` evaluates no timing check.
    const tchk_source =
        \\module ff(input clk, input d); specify $setup(d, posedge clk, 1); endspecify endmodule
        \\module m; reg clk, d; ff u(clk, d); initial begin clk = 0; d = 0; #1 clk = 1; end endmodule
    ;
    const tchk = try emitted(a, tchk_source, .static, .auto);
    try testing.expectEqualStrings("IEEE 1364-2005 §15 timing checks", tchk.fallback.?);
}

test "program: an interpreted executable keeps the -D macros it was built with" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "module m; real r; initial begin r = `R; case (r) 1.0: $display(\"one\"); endcase end endmodule";
    var bag = diag.Bag.init(a);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var r = try sim.digital.elaborate(a, source, .{ .defines = &.{"R=1.0"} }, &bag, &sink.writer);
    const p = try digital.program(a, &r, .{ .source = source, .file_name = "<digital>", .include_dirs = &.{}, .defines = &.{"R=1.0"}, .language = Front.keyword.default_keyword_set }, .static, .auto);
    try testing.expectEqualStrings("a real value", p.fallback.?);
    try has(p.text, ".defines = &.{ \"R=1.0\", }");
}

test "program: a file name is one comment line and one string literal, natively or not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = "dir\nwith \"quotes\".v";
    for ([_][]const u8{
        "module m; initial $display(\"hi\"); endmodule",
        "module m; real r; initial case (r) 1.0: $display(\"one\"); endcase endmodule",
    }) |source| {
        const p = try emittedAs(a, source, name, .static, .auto);
        // A raw newline in a `//` comment would start a line of Zig.
        try lacks(p.text, "\nwith");
    }
}

test "program: --two-state refuses an x that carries meaning; auto keeps it 4-state and says why" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "module m; reg a; initial #1 if (a === 1'bx) $display(\"x\"); endmodule";
    const why = "`===` or `!==` against an x or z, which asks whether a value is unknown";
    const two = try emitted(a, source, .static, .two);
    try testing.expectEqualStrings(why, two.fallback.?);
    const auto = try emitted(a, source, .static, .auto);
    try testing.expectEqual(@as(?[]const u8, null), auto.fallback);
    try testing.expectEqualStrings(why, auto.four.?.why);
}

test "program: §10.3 a disable from inside a fork, whose other arms may be suspended, runs on the interpreter" {
    // `rt.State.disable` resumes the block's end when it ended a sibling, and
    // the disabling arm continues there too: the interpreter resumes it once.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\`timescale 1ns/1ns
        \\module m; initial begin fork : f #1 $display("a"); #2 disable f; join $display("after"); end endmodule
    ;
    const p = try emitted(arena.allocator(), source, .static, .auto);
    try testing.expectEqualStrings("a §10.3 disable from inside a block other processes may still be inside", p.fallback.?);
}

test "program: §9.7.1 a constant delay folds to ticks; an x one is 0 ticks, but --two-state computes it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "`timescale 1ns/100ps\nmodule m; reg a; initial begin #1.5 a = 1; #(1'bx) a = 0; end endmodule";
    const four = try native(a, source, .static);
    try has(four, "try s.run(1, 15);");
    try has(four, "try s.run(3, 0);");
    const two = try emitted(a, source, .static, .two);
    try has(two.text, "try s.run(3, try s.ticks(");
}

test "program: a plain logic gate is a node; a three-state one resolves in rt.net" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try emitted(arena.allocator(), "module m; wire y, t; reg a, b, e; and g(y, a, b); bufif1 h(t, a, e); initial begin a = 0; b = 1; e = 1; end endmodule", .static, .auto);
    try has(p.text, "return L.bitwise(.@\"and\", L.bitwise(.@\"and\", L.k(1, 0), w0, 1), w1, 1);");
    try has(p.text, "try s.gate(0, .g_bufif1, &b);");
    try testing.expect(std.mem.startsWith(u8, p.four.?.why, "a §7.9 net resolved"));
}

test "plan.build: a plain driver nothing waits on is a settle node under static only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comb = "module m; reg a, b; wire w; assign w = a & b; initial begin a = 0; b = 1; #1 a = 1; end endmodule";
    try has(try native(a, comb, .static), "fn settle(");
    try lacks(try native(a, comb, .fifo), "fn settle(");
    // One whose output a general process's event control waits on stays
    // queued: a settle event would change it before a process started in
    // between ran. (`initial @(w)` stops after one pass, so it is general,
    // not a triggered process the watcher table wakes.)
    const waited = "module m; reg a; wire w; assign w = a; initial begin a = 0; #1 a = 1; end initial @(w) $display(\"%b\", w); endmodule";
    try lacks(try native(a, waited, .static), "fn settle(");
}

test "plan.build: §11.4.2 drivers on a cycle, and downstream of one, stay event-driven" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try native(arena.allocator(), "module m; wire a, b, c; assign a = b; assign b = a; assign c = a; endmodule", .static);
    try has(text, "    .nodes = 0,\n");
    try lacks(text, "fn settle(");
}

test "plan.build: §5.2.1 a constant part-select dirties its node on the bits it names only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // v[70:60] spans words 0 and 1 of a 128-bit slot; v[200:190] names no
    // bit, so no change of v dirties z's node.
    const text = try native(arena.allocator(), "module m; reg [127:0] v; wire [10:0] y, z; assign y = v[70:60]; assign z = v[200:190]; initial begin v = 0; #1 v[65] = 1; end endmodule", .static);
    try has(text, ".comb = &.{ .{ .node = 1, .word = 0, .mask = 0xf000000000000000 }, .{ .node = 1, .word = 1, .mask = 0x7f }, },");
}

test "plan.build: §9.7.5 an @* node reads its select's bit; an explicit list re-runs on any change of a term" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `@(a)` omits b: only a is an input, read whole; `@*` reads bit 3 of w.
    const text = try native(arena.allocator(), "module m; reg a, b, y, q; reg [127:0] w; always @(a) y = a & b; always @* q = w[3]; initial begin a = 0; b = 0; w = 0; #1 a = 1; end endmodule", .static);
    try has(text, ".comb = &.{ .{ .node = 1, .word = 0, .mask = 0xffffffffffffffff }, .{ .node = 0, .word = 4, .mask = 0x8 }, },");
}

test "plan.stepLocal: a slot written whole before every read is dead at a step boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // o (slot 0, one word) is written whole before each read in its one
    // activation, so its value at a step boundary is never read: dead.
    try has(try native(a, "module m; reg [7:0] o; initial begin #1 o = 8'd3; o = o + 1; end endmodule", .static), "    .dead = &.{ .{ 0, 1 }, },\n");
    // The always reads o before writing it in every activation after its
    // delay: live, and nothing is dead.
    try has(try native(a, "module m; reg [7:0] o; initial o = 8'd0; always #1 o = o + 1; endmodule", .static), "    .dead = &.{ },\n");
    // A delay starts a new activation, which knows nothing written: the
    // read after it keeps o live.
    try has(try native(a, "module m; reg [7:0] o; initial begin o = 8'd3; #1 o = o + 1; end endmodule", .static), "    .dead = &.{ },\n");
}

test "device: a procedural continuous assignment is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try device(arena.allocator(), "module m(output reg q); initial assign q = 1'b1; endmodule");
    try testing.expectEqualStrings("a §9.3 procedural continuous assignment (assign or force)", got.refused);
}

test "device: one pin per port bit, a vector's from its left index to its right" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zig = (try device(a, "module m(input [3:0] a, output [0:1] y, output z); assign y = a[1:0]; assign z = ^a; endmodule")).zig;
    try has(zig, "pub const U = enum(u8) { @\"a[3]\", @\"a[2]\", @\"a[1]\", @\"a[0]\", @\"y[0]\", @\"y[1]\", z, };");
    try has(zig, "pub const num_ports: usize = 7;");
    // `y[0]` is the left of [0:1], bit 1 of the slot.
    try has(zig, ".{ .out = true, .slot = 1, .off = 1, .bit = 1 },\n        .{ .out = true, .slot = 1, .off = 1, .bit = 0 },");
    // No port: an exhaustive `enum(u8)` needs a member.
    try has((try device(a, "module m; endmodule")).zig, "pub const U = enum(u8) { _, };");
}

test "device: an inout, real or integer port is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("an inout port: the analog side would drive a §7.9 resolved net", (try device(a, "module m(inout w); endmodule")).refused);
    try testing.expectEqualStrings("a real port", (try device(a, "module m(output r); real r; endmodule")).refused);
    try testing.expectEqualStrings("an integer or time port", (try device(a, "module m(output i); integer i; endmodule")).refused);
}

test "emitDevice: no `timescale is W1155; a refusal is E1103 and DigitalFailed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bag = diag.Bag.init(a);
    _ = try digital.emitDevice(a, "module m(input x, output y); assign y = x; endmodule", .{}, .static, &bag);
    try testing.expectEqual(@as(usize, 1), bag.count());
    try testing.expectEqual(diag.Code.W1155, bag.at(0).code);
    var timed = diag.Bag.init(a);
    const d = try digital.emitDevice(a, "`timescale 1ns/1ps\nmodule n(input x, output y); assign y = x; endmodule", .{}, .static, &timed);
    try testing.expectEqualStrings("n", d.name);
    try testing.expectEqual(@as(usize, 0), timed.count());
    var refused = diag.Bag.init(a);
    try testing.expectError(error.DigitalFailed, digital.emitDevice(a, "module m(inout w); endmodule", .{}, .static, &refused));
    try testing.expectEqual(diag.Code.E1103, refused.at(0).code);
}

/// An arena that takes every allocation from `parent` one by one, so a
/// `FailingAllocator` parent fails each of the emitter's allocations in
/// turn (`std.heap.ArenaAllocator` would fail only its few chunk grows).
const EachAlloc = struct {
    parent: std.mem.Allocator,
    live: std.ArrayList([]u8) = .empty,

    fn allocator(self: *EachAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *EachAlloc = @ptrCast(@alignCast(ctx));
        self.live.ensureUnusedCapacity(testing.allocator, 1) catch return null;
        // Every row is taken and freed 16-aligned, which covers each request.
        std.debug.assert(al.compare(.lte, .@"16"));
        const p = self.parent.rawAlloc(len, .@"16", ra) orelse return null;
        self.live.appendAssumeCapacity(p[0..len]);
        return p;
    }

    fn free(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, ra: usize) void {
        const self: *EachAlloc = @ptrCast(@alignCast(ctx));
        for (self.live.items, 0..) |b, i| if (b.ptr == buf.ptr) {
            self.parent.rawFree(b, .@"16", ra);
            _ = self.live.swapRemove(i);
            return;
        };
        unreachable; // a free of what this allocator never gave
    }

    fn deinit(self: *EachAlloc) void {
        for (self.live.items) |b| self.parent.rawFree(b, .@"16", @returnAddress());
        self.live.deinit(testing.allocator);
    }
};

/// `program` of one design, each emitter allocation from `gpa`;
/// elaboration has an arena of its own.
fn programUnder(gpa: std.mem.Allocator, source: []const u8) !void {
    var el = std.heap.ArenaAllocator.init(testing.allocator);
    defer el.deinit();
    var bag = diag.Bag.init(el.allocator());
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var r = try sim.digital.elaborate(el.allocator(), source, .{}, &bag, &sink.writer);
    var each: EachAlloc = .{ .parent = gpa };
    defer each.deinit();
    const p = try digital.program(each.allocator(), &r, .{ .source = source, .file_name = "<digital>", .include_dirs = &.{}, .language = Front.keyword.default_keyword_set }, .static, .auto);
    try testing.expectEqual(@as(?[]const u8, null), p.fallback);
}

test "program: every allocation failure is OutOfMemory, never a fallback" {
    // Nodes, a triggered process, a task, a monitor, a resolved net, a
    // constant select and a case: most of the emitter's paths allocate.
    const source =
        \\module m;
        \\  reg [7:0] a, b; reg c; wire [7:0] s; wire t; reg e; reg [127:0] w;
        \\  assign s = a + b; bufif1 g(t, c, e);
        \\  task bump; input [7:0] x; begin a = x + 1; end endtask
        \\  always @(posedge c) case (a[1:0]) 2'd0: bump(a); default: b = b + 1; endcase
        \\  initial begin $monitor("%d %b", s, t); a = 0; b = 0; c = 0; e = 1; w = 128'hffff_0000_ffff_0000_ffff_0000_ffff_0000 + w; #1 c = 1; #1 c = 0; end
        \\endmodule
    ;
    try testing.checkAllAllocationFailures(testing.allocator, programUnder, .{source});
}
