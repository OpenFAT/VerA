//! `digital.rtlil` over the designs `tests/rtlil/` holds: the RTLIL text a
//! module, a process, a cell and a refusal come out as. Yosys's own reading of
//! the same text is `zig build test-external`.

const std = @import("std");
const digital = @import("digital");
const diag = @import("diag");

const counter = @embedFile("../rtlil/counter.v");
const null_ports = @embedFile("../rtlil/null_ports.v");
const fold_1364 = @embedFile("../rtlil/fold_1364.v");

// ---- private ----

fn emit(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    var bag: diag.Bag = .init(arena);
    return digital.rtlil.emit(arena, src, .{}, &bag) catch |e| {
        for (0..bag.count()) |i| std.debug.print("{t}: {s}\n", .{ bag.at(i).code, bag.at(i).message });
        return e;
    };
}

/// Expects `src` refused with one diagnostic: `code`, `message`, at the
/// first occurrence of `at` in `src` (the token the refusal names).
fn expectRefused(src: []const u8, err: anyerror, code: diag.Code, message: []const u8, at: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    try std.testing.expectError(err, digital.rtlil.emit(arena, src, .{}, &bag));
    try std.testing.expectEqual(@as(usize, 1), bag.count());
    try std.testing.expectEqual(code, bag.at(0).code);
    try std.testing.expectEqualStrings(message, bag.at(0).message);
    try std.testing.expectEqual(@as(u32, @intCast(std.mem.find(u8, src, at).?)), bag.at(0).span.start);
}

fn expectHas(text: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, text, needle) == null) {
        std.debug.print("missing `{s}` in:\n{s}\n", .{ needle, text });
        return error.TestExpectedEqual;
    }
}

/// `open` `n` times, then `mid`, then `close` `n` times: a source nested
/// `n` levels deep.
fn nested(arena: std.mem.Allocator, head: []const u8, open: []const u8, mid: []const u8, close: []const u8, tail: []const u8, n: usize) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, head);
    for (0..n) |_| try s.appendSlice(arena, open);
    try s.appendSlice(arena, mid);
    for (0..n) |_| try s.appendSlice(arena, close);
    try s.appendSlice(arena, tail);
    return s.items;
}

test "vera -D reaches --emit-rtlil: `ifdef picks the inverter (1364 §19.4)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = "module m(input a, output y); `ifdef INV assign y = ~a; `else assign y = a; `endif endmodule";
    var bag: diag.Bag = .init(arena);
    try expectHas(try digital.rtlil.emit(arena, src, .{ .defines = &.{"INV"} }, &bag), "$not");
    try std.testing.expect(std.mem.find(u8, try digital.rtlil.emit(arena, src, .{}, &bag), "$not") == null);
}

test "the counter: ports in order, a process per always block, edge and level syncs, cells, a named instance, gates" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try emit(arena_state.allocator(), counter);
    for ([_][]const u8{
        "module \\counter",
        "wire width 1 input 1 \\clk",
        "wire width 4 input 4 \\d",
        "wire width 4 output 5 \\q",
        "process $proc$0",
        "assign $0\\q \\q",
        "sync posedge \\clk",
        "sync negedge \\rst_n",
        "update \\q $0\\q",
        "cell $logic_not",
        "cell $add",
        "cell $reduce_and",
        "connect \\tc",
        "module \\top",
        "cell \\counter \\u",
        "connect \\rst_n \\rst_n",
        "switch \\q [1:0]",
        "case 2'00",
        "case 2'01",
        "assign $1\\s \\q [3:2]",
        "sync always",
        "connect \\sel \\s",
        "connect \\n [0]",
        "cell $tribuf",
    }) |needle| try expectHas(text, needle);
}

test "a refusal is one coded diagnostic at the construct, and nothing is emitted" {
    // Oracle: the construct's own code (lib/diag E1200 to E1278, one per
    // refusal) at its token, found in the source by hand.
    try expectRefused("module m(input a, output reg y);\n  integer i;\n  always @* for (i = 0; i < 2; i = i + 1) y = a;\nendmodule\n", error.Refused, .E1263, "", "for");
    try expectRefused("module m; real r; endmodule\n", error.Refused, .E1218, "", "r;");
    try expectRefused("module m(input a, output y); assign y = m.a; endmodule\n", error.Refused, .E1227, "", "m.a");
    try expectRefused("module m; wire [3:0] w = 5; wire x = w[6]; endmodule\n", error.Refused, .E1243, "", "[6]");
}

test "inputs the rewrite asserted on are refused: a parameter twice, {}, a declared width or a concatenation past the fold limit, an undeclared reg in an always block" {
    // Oracle: `vera --run` of the same designs (E1100, its words) for the
    // first two, §5.4.1 widths by hand against rtlil_fold.max_width
    // (2^20) for the next three, and §4.5 for the last. Each panicked on
    // rewrite/integrate (an assert or an overflow).
    try expectRefused("module m; parameter P = 1; parameter P = 2; endmodule\n", error.DigitalFailed, .E1100, "duplicate digital variable", "P = 2");
    try expectRefused("module m(o); output o; assign o = {}; endmodule\n", error.DigitalFailed, .E1100, "a concatenation requires a positive-width operand; zero-only and empty concatenations are invalid", "{}");
    try expectRefused("module m; parameter [1048576:0] P = 0; endmodule\n", error.Refused, .E1275, "1048576 bits", "P = 0");
    try expectRefused("module m; reg [1048576:0] r; initial r = 0; endmodule\n", error.Refused, .E1275, "1048576 bits", "r = 0");
    try expectRefused("module m(o); output o; wire [2147483646:0] a; assign o = {a, a, a}; endmodule\n", error.Refused, .E1278, "1048576 bits", "{a, a, a}");
    try expectRefused("module m(input c);\n  always @(posedge c) q = 1;\nendmodule\n", error.Refused, .E1224, "`q`", "q = 1");
}

test "null ports keep their header positions with no wire, and connect nothing (A.1.3, §12.1.2)" {
    // Oracle: the positions by hand from `leaf(a, , , y)`: `a` is port 1,
    // `y` port 4; the `1'b0` in position 3 reaches no wire. Development
    // panicked on the null name (interner `id != .none`).
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try emit(arena_state.allocator(), null_ports);
    try expectHas(text, "module \\leaf\n  wire width 1 input 1 \\a\n  wire width 1 output 4 \\y\n  connect \\y \\a\nend\n");
    try expectHas(text, "  cell \\leaf \\by_order\n    connect \\a \\i\n    connect \\y \\o\n  end\n");
    try expectHas(text, "  cell \\leaf \\by_name\n    connect \\a \\i\n    connect \\y \\p\n  end\n");
}

test "a connection to no port, or a second declaration of a name, is E1100 in vera --run's words (§12.1.2, §12.3.6, §4.10)" {
    // Oracle: `vera --run` of the same designs (sim.digital's elab.zig),
    // and tests/conformance's null_port_extra_connection_rejected.v
    // (`//! reject E1100`). Development panicked on the first.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][2][]const u8{
        .{ "module leaf(a, , , y); input a; output y; assign y = a; endmodule\nmodule top; wire y; leaf u(1'b1, , , y, 1'b0); endmodule\n", "more port connections than the module has ports" },
        .{ "module leaf(input a, output y); assign y = a; endmodule\nmodule top; wire y; leaf u(.a(1'b1), .q(y)); endmodule\n", "the instantiated module has no such port" },
        // §4.10, tests/conformance's parameter_redeclares_net_rejected.v.
        // Development emitted `wire width 32 signed \w`, the parameter.
        .{ "module m;\n  wire w;\n  parameter w = 1;\nendmodule\n", "duplicate digital variable" },
        .{ "module m;\n  wire w;\n  reg w;\nendmodule\n", "duplicate digital variable" },
    }) |c| {
        var bag: diag.Bag = .init(arena);
        try std.testing.expectError(error.DigitalFailed, digital.rtlil.emit(arena, c[0], .{}, &bag));
        try std.testing.expectEqual(@as(usize, 1), bag.count());
        try std.testing.expectEqual(diag.Code.E1100, bag.at(0).code);
        try std.testing.expectEqualStrings(c[1], bag.at(0).message);
    }
}

test "ranges and parameters fold by IEEE 1364's widths, not a 32-bit integer's (§5.4.1, §12.2)" {
    // Oracle: the hand derivation in tests/rtlil/fold_1364.v, which Yosys
    // 0.68's own `read_verilog` agrees with. Development emitted `w`, `u`
    // and `s` 2 bits wide and `big_o` from a 32-bit `WIDE`.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try emit(arena_state.allocator(), fold_1364);
    for ([_][]const u8{
        "  wire width 4 \\w\n",
        "  wire width 16 \\u\n",
        "  wire width 7 offset 1 \\s\n",
        "  wire width 8 offset -2 upto \\asc\n",
        "  wire width 8 offset -3 \\desc\n",
        "  connect \\big_o 64'0000000000000000000000000000000100000000000000000000000000000100\n",
    }) |needle| try expectHas(text, needle);
}

test "a range whose bounds do not fit RTLIL's 32-bit offset is refused by its folded bounds" {
    // Oracle: §5.4.1 by hand. `HI - 7` is 64 bits signed: 2^63 - 8;
    // `LO + 7` is -2^63 + 7. Development overflowed in `dim`.
    try expectRefused("module m;\n  localparam signed [63:0] HI = 64'sh7fffffffffffffff;\n  reg [HI:HI-7] v;\nendmodule\n", error.Refused, .E1221, "`[9223372036854775807:9223372036854775800]`", "v;");
    try expectRefused("module m;\n  localparam signed [63:0] LO = 64'sh8000000000000000;\n  reg [LO+7:LO] v;\nendmodule\n", error.Refused, .E1221, "`[-9223372036854775801:-9223372036854775808]`", "v;");
    try expectRefused("module m;\n  wire [2147483647:-2147483648] v;\nendmodule\n", error.Refused, .E1222, "`[2147483647:-2147483648]`", "v;");
}

test "a header port that selects part of its net is refused, not emitted at the net's width (A.1.3)" {
    // Oracle: A.1.3's `port_reference ::= port_identifier [ [
    // constant_range_expression ] ]`: `a[0]` is a one-bit port. Development
    // emitted `wire width 2 input 1 \a`, the whole net.
    try expectRefused("module m(a[0], y);\n  input [1:0] a;\n  output y;\n  assign y = a[0];\nendmodule\n", error.Refused, .E1213, "`a[...]`", "a[0], y");
}

test "10^4 levels of parentheses, else-if arms, begin blocks and lvalue braces emit, counted level for level" {
    // Oracle: the source, counted. `(a + (a + ... a))` n deep is n
    // `$add` cells (§5.1, one cell per operator); an else-if chain of n
    // arms is n `switch` rules plus none for the final else (§9.4); n
    // `begin`/`end` around one assignment emit what the bare assignment
    // does (§9.8.1: a sequential block is its statements); and n braces
    // around `{y, z}` are n + 1 sigspec braces (A.8.5). The rewrite
    // recursed on the caller's stack and aborted at each.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n = 10_000;
    const chain = try emit(arena, try nested(arena, "module m(input a, output [31:0] y);\n  assign y = ", "(a + ", "a", ")", ";\nendmodule\n", n));
    try std.testing.expectEqual(@as(usize, n), std.mem.count(u8, chain, "cell $add "));
    const arms = try emit(arena, try nested(arena, "module m(input c, input a, output reg y);\n  always @(posedge c)\n", "    if (a) y = 1; else\n", "    y = 0;\n", "", "endmodule\n", n));
    try std.testing.expectEqual(@as(usize, n), std.mem.count(u8, arms, "switch "));
    // An arm is five lines of bounded length, so the text is linear in n.
    // Development indented each arm two levels past its parent: 977 MB here.
    try std.testing.expect(arms.len < 512 * n);
    const deep = try emit(arena, try nested(arena, "module m(input c, input a, output reg y);\n  always @(posedge c) ", "begin ", "y = a;", " end", "\nendmodule\n", n));
    const flat = try emit(arena, "module m(input c, input a, output reg y);\n  always @(posedge c) y = a;\nendmodule\n");
    try std.testing.expectEqualStrings(flat, deep);
    const braces = try emit(arena, try nested(arena, "module m(input a, output y, output z);\n  assign ", "{", "y, z", "}", " = {a, a};\nendmodule\n", n));
    const line = braces[std.mem.find(u8, braces, "  connect {").?..];
    try std.testing.expectEqual(@as(usize, n + 1), std.mem.count(u8, line[0..std.mem.findScalar(u8, line, '\n').?], "{"));
}

test "escaped names are RTLIL ids of the same name: `\\a ` keeps its backslash, a `.` stays a `.`, `\\$4 ` is `$4` (§3.7.1)" {
    // Oracle: §3.7.1, the leading `\` and the closing white space are no
    // part of the name, so `\\a ` is the name `\a`, not `a`. Yosys 0.68's
    // `read_rtlil; write_verilog` of this text gives back the source's
    // ports `\\a`, `a`, `\s.gr` and `\$4`. The rewrite wrote `\\a ` as
    // `\a`, colliding with `a`, and `\s.gr ` as `\s gr`.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try emit(arena_state.allocator(), "module t(\\\\a , a, \\s.gr , \\$4 , y);\n  input \\\\a , a, \\s.gr , \\$4 ;\n  output y;\n  assign y = \\\\a & ~a & \\s.gr & \\$4 ;\nendmodule\n");
    try expectHas(text, "  wire width 1 input 1 \\\\a\n  wire width 1 input 2 \\a\n  wire width 1 input 3 \\s.gr\n  wire width 1 input 4 \\$4\n");
}
