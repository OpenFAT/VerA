//! Corner cases of the interpreter files no single sibling's tests reach:
//! §4.8.2 conversions at the i32/i64 edges, §17 byte-packing at word
//! boundaries, a run's arena under repeated timing-check conditions, and
//! allocation failure through the system tasks. No LRM clause of its own:
//! each test cites the clause it checks.
//!
//! Contents:
//! - `pub fn Still.setInputs(_: *Still, _: *root.Run, _: u64) !void`
//! - `pub fn Still.snapshot(_: *Still, _: *root.Run) !void`
//! - `pub fn Still.latch(_: *Still) !void`
//! - `pub fn Still.solveAt(s: *Still, _: f64, _: f64, _: bool, _: bool) !void`
//! - `pub fn Still.probe(_: *Still, _: ?f64, _: []const u8, _: ?[]const u8) !f64`
//! - `pub fn Still.finish(s: *Still) !void`

const std = @import("std");
const diag = @import("diag");
const root = @import("sim").digital;
const system = root.system;
const filled = root.for_emitter.net.filled;
const expectRun = root.expectRun;
const mixed = @import("sim").mixed;

/// `sim.mixed.run`'s analog side at its smallest: a solver whose node never
/// moves, counting its solves and finished points.
const Still = struct {
    solves: u32 = 0,
    finished: u32 = 0,
    pub fn setInputs(_: *Still, _: *root.Run, _: u64) !void {}
    pub fn snapshot(_: *Still, _: *root.Run) !void {}
    pub fn latch(_: *Still) !void {}
    pub fn solveAt(s: *Still, _: f64, _: f64, _: bool, _: bool) !void {
        s.solves += 1;
    }
    pub fn probe(_: *Still, _: ?f64, _: []const u8, _: ?[]const u8) !f64 {
        return 0;
    }
    pub fn finish(s: *Still) !void {
        s.finished += 1;
    }
};

// ---- private ----

fn runSystemTasks(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try root.run(arena.allocator(),
        \\module m; reg [8*10:1] s; integer n, a, st, j, i; real r;
        \\initial begin
        \\  $sformat(s, "%0d-%h", 12, 8'hab); n = $sscanf("7 2.5", "%d %f", a, r);
        \\  $q_initialize(1, 1, 2, st); $q_add(1, 3, 4, st); $q_remove(1, j, i, st);
        \\  $display("%s %0d %0d %g %0d %0d %0d", s, n, a, r, st, j, i);
        \\end endmodule
    , .{}, &bag, &output.writer);
    // s is 10 characters: %s shows its five leading zero bytes as spaces (VD-129).
    try std.testing.expectEqualStrings("     12-ab 2 7 2.5 0 3 4\n", output.written());
}

/// Test support: runs `source` (beside it, `d.sdf` holding `sdf`) to its
/// end, and expects its transcript `expected` and, when given, a warning
/// naming `warning`.
fn expectAnnotated(source: []const u8, sdf: []const u8, expected: []const u8, warning: ?[]const u8) !void {
    std.debug.assert(std.mem.find(u8, source, "$sdf_annotate(\"d.sdf\"") != null);
    std.debug.assert(sdf.len != 0);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "d.sdf", .data = sdf });
    const file_name = try a.print(".zig-cache/tmp/{s}/test.v", .{tmp.sub_path});
    var bag = diag.Bag.init(a);
    var output = std.Io.Writer.Allocating.init(a);
    try root.run(a, source, .{ .io = std.testing.io, .file_name = file_name }, &bag, &output.writer);
    var messages = std.Io.Writer.Allocating.init(a);
    try diag.render(&bag, &messages.writer, .{});
    if (warning) |w| try std.testing.expect(std.mem.find(u8, messages.written(), w) != null);
    try std.testing.expectEqualStrings(expected, output.written());
}

test "vera -D defines a .v design's macros: a bare NAME is 1, NAME=TEXT is TEXT (1364 §19.3.1, §19.4)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bag = diag.Bag.init(a);
    var out = std.Io.Writer.Allocating.init(a);
    try root.run(a,
        \\module m; initial begin
        \\`ifdef FAST $display("fast %0d", `FAST); `else $display("slow"); `endif
        \\$display("%0d", `W); end endmodule
    , .{ .defines = &.{ "FAST", "W=4" } }, &bag, &out.writer);
    try std.testing.expectEqualStrings("fast 1\n4\n", out.written());
}

test "vera --param sets a top-level parameter: integer, real, string, and a misspelling refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\module m; parameter N = 1; parameter S = "hi"; parameter R = 1.5; parameter T = 0;
        \\initial $display("%0d %s %0.2f %s", N, S, R, T); endmodule
    ;
    var bag = diag.Bag.init(a);
    var out = std.Io.Writer.Allocating.init(a);
    try root.run(a, src, .{
        .params = &.{
            .{ .name = "N", .value = 5, .text = "5" },
            .{ .name = "S", .value = 12, .text = "12" }, // a string default keeps the text
            .{ .name = "R", .value = 2.25, .text = "2.25" },
            .{ .name = "T", .value = std.math.nan(f64), .text = "yo" },
        },
    }, &bag, &out.writer);
    try std.testing.expectEqualStrings("5 12 2.25 yo\n", out.written());
    try std.testing.expectError(error.DigitalFailed, root.run(a, src, .{ .params = &.{.{ .name = "Q", .value = 1, .text = "1" }} }, &bag, &out.writer));
}

test "§17.8 $rtoi takes -2^31 exactly and keeps the low 32 bits of one past it (VD-130)" {
    // Oracle: iverilog's itor_rtoi gold; an infinity is x.
    try expectRun(
        \\module m; integer i, j, k, n;
        \\initial begin i = $rtoi(-2147483648.0); j = $rtoi(-2147483648.9); k = $rtoi(-2147483649.0); n = $rtoi(1.0/0.0);
        \\$display("%0d %0d %b %0d", i, j, k, n); end endmodule
    , "-2147483648 -2147483648 01111111111111111111111111111111 x\n");
}

test "§4.8.2 a real rounds into a 64-bit integer down to -2^63, and NaN is x" {
    try expectRun(
        \\module m; reg signed [63:0] a, b; real n;
        \\initial begin a = -9223372036854775808.0; n = 0.0 / 0.0; b = n;
        \\$display("%0d %b", a, b[0]); end endmodule
    , "-9223372036854775808 x\n");
}

test "§17.1.1.7 text reads bytes across a word boundary, top byte partial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 76 bits: a partial top byte 0x5 (bits 72..75), then 9 bytes, the
    // eighth of which (bits 56..63) ends word 0.
    const v = try filled(a, 76, false, .zero);
    v.values()[0] = 0x4847_4645_4443_4241;
    v.values()[1] = 0x549;
    try std.testing.expectEqualStrings("\x05IHGFEDCBA", (try system.text(a, v)).?);
}

test "§17.2.3 a string longer than a word packs into the value and reads back" {
    try expectRun(
        \\module m; reg [8*12:1] s;
        \\initial begin $sformat(s, "%s", "abcdefghijkl"); $display("%s|%h", s, s[72:65]); end endmodule
    , "abcdefghijkl|64\n");
}

test "§17.2.4.4 readWord spans words big-endian and drops bits above the width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const File = struct {
        var data: []const u8 = "";
        var pos: usize = 0;
        fn getc(_: *anyopaque, _: i64) i64 {
            if (pos == data.len) return -1;
            pos += 1;
            return data[pos - 1];
        }
        fn none(_: *anyopaque, _: i64) i64 {
            return 0;
        }
    };
    const io: @import("contract").FileIo = .{ .ctx = &File.pos, .open = undefined, .close = File.none, .put = undefined, .getc = File.getc, .ungetc = undefined, .tell = File.none, .seek = undefined, .eof = File.none };
    // 70 bits = 9 bytes, 0xff first: only its low 6 bits survive.
    File.data = "\xff\x01\x02\x03\x04\x05\x06\x07\x08";
    File.pos = 0;
    const w = try system.readWord(a, io, 1, 70);
    try std.testing.expectEqual(@as(i64, 9), w.n);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), w.value.?.values()[0]);
    try std.testing.expectEqual(@as(u64, 0x3f), w.value.?.values()[1]);
    try std.testing.expectEqual(@as(u64, 0), w.value.?.unknowns()[1]);
}

test "§15.6 a conditioned timing check judged every tick stops growing the run arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try root.elaborate(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module c(clk, en); input clk, en; reg n;
        \\specify $period(posedge clk &&& en, 1, n); endspecify endmodule
        \\module t; reg clk, en; c u(clk, en);
        \\initial begin clk = 0; en = 1; end always #1 clk = ~clk; endmodule
    , .{}, &bag, &output.writer);
    var at_warm: usize = 0;
    for (1..2001) |k| {
        _ = try r.runUntil(k);
        if (k == 200) at_warm = arena.queryCapacity();
    }
    try std.testing.expectEqual(at_warm, arena.queryCapacity());
}

test "§5.2.1 an indexed part-select descending from a base below the vector" {
    // v[1 -: 4] of [7:0] selects bits 1 down to -2: 1 and 0 exist, -1 and
    // -2 do not (x), and a write there lands only in bits 1 and 0.
    try expectRun(
        \\module m; reg [7:0] v;
        \\initial begin v = 8'b0000_0010; $display("%b", v[1 -: 4]); v[1 -: 4] = 4'b0111; $display("%b", v); end endmodule
    , "10xx\n00000001\n");
}

test "allocation failure anywhere in $sformat, $sscanf, the queues and $display cleans up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runSystemTasks, .{});
}

test "§12.7 one expression read from two instances resolves per scope through the slot memo" {
    // `v` in `c` is one ExprId seen from two scopes; a memo keyed on the
    // expression alone would print 1 twice.
    try expectRun(
        \\module c; parameter P = 0; reg [3:0] v; initial begin v = P; #1 $display("%0d %0d", v, t.b.v); end endmodule
        \\module t; c #(1) a(); c #(2) b(); endmodule
    , "1 2\n2 2\n");
}

// ---- pass 3: input the rewrite asserted on, refused instead ----

test "A.5.1 a UDP with no input port is refused, declared or instantiated" {
    // Oracle: A.5.1's udp_port_list, `output_port_identifier ,
    // input_port_identifier { , input_port_identifier }`, in both header
    // forms. The parser refuses it (E0207) before elaboration, so no
    // one-port UDP reaches `checkUdp`, which asserts it.
    try root.expectRejected("primitive p(q); output q; table endtable endprimitive module t; wire w; p g(w); endmodule", "error[E0207]");
    try root.expectRejected("primitive p(q); output q; table endtable endprimitive module t; endmodule", "error[E0207]");
    try root.expectRejected("primitive p(output q); table endtable endprimitive module t; endmodule", "error[E0207]");
    try root.expectRejected("primitive p(output reg q = 0); table endtable endprimitive module t; endmodule", "error[E0207]");
}

test "§12.4.1 a loop generate's genvar declared again as a variable, net or parameter is refused" {
    // Oracle: §12.4.1, "the genvar shall be declared" and is "an integer"
    // local to the generate scope; a second declaration of the name in the
    // module is §12.7's duplicate.
    const loop = " generate for (i = 0; i < 2; i = i + 1) begin : g end endgenerate endmodule";
    try root.expectRejected("module m; genvar i; integer i;" ++ loop, "also declared as something else");
    try root.expectRejected("module m; genvar i; wire i;" ++ loop, "also declared as something else");
    try root.expectRejected("module m; genvar i; parameter [63:0] i = 0;" ++ loop, "also declared as something else");
    // Two loops over one genvar in one scope share its slot.
    try expectRun("module m; genvar i;" ++
        " generate for (i = 0; i < 2; i = i + 1) begin : a end endgenerate" ++
        " generate for (i = 0; i < 3; i = i + 1) begin : b end endgenerate" ++
        " initial $display(\"ok\"); endmodule", "ok\n");
}

test "--param with an empty NAME is refused as no top-level parameter, not a crash" {
    // Oracle: the --param contract, "no top-level module declares a
    // parameter" for any NAME the top does not declare; argv may hold
    // `--param =5`, whose NAME is empty.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var out = std.Io.Writer.Allocating.init(arena.allocator());
    const opts: root.Options = .{ .params = &.{.{ .name = "", .value = 5 }} };
    try std.testing.expectError(error.DigitalFailed, root.run(arena.allocator(), "module m; parameter p = 1; endmodule", opts, &bag, &out.writer));
    var messages = std.Io.Writer.Allocating.init(arena.allocator());
    try diag.render(&bag, &messages.writer, .{});
    try std.testing.expect(std.mem.find(u8, messages.written(), "no top-level module declares a parameter ``") != null);
}

test "§12.1.2 an instance array whose bounds are maxInt(i64) elaborates its one instance" {
    // Oracle: §12.1.2, one instance per index from the lower bound to the
    // upper, here the single index 2^63 - 1.
    try expectRun("module c; initial $display(\"%m\"); endmodule module t; c u[64'sd9223372036854775807:64'sd9223372036854775807] (); endmodule", "t.u[9223372036854775807]\n");
}

test "§7.6 a pass switch whose two terminals are one net leaves that net its drivers' value" {
    // Oracle: §7.6, a bidirectional switch only passes a signal between its
    // terminals; with both on one net it carries nothing new, so the net
    // resolves its drivers alone (§7.9). Port aliasing reaches the same
    // switch through §12.3.10's collapsed ports.
    try expectRun("module t; wire a; assign a = 1'b1; tran (a, a); initial #1 $display(\"%b\", a); endmodule", "1\n");
    try expectRun("module t; wire a; reg c; assign a = 1'b0; rtranif1 (a, a, c); initial begin c = 1; #1 $display(\"%b\", a); end endmodule", "0\n");
    try expectRun("module m(inout p, inout q); tran (p, q); endmodule module t; wire n; assign n = 1'b1; m u(n, n); initial #1 $display(\"%b\", n); endmodule", "1\n");
}

test "§17.1.1 a null argument a specifier would consume is refused, a trailing one warns, never a crash" {
    // Oracle: §9.4.1, a null argument prints one space where it stands as an
    // argument of its own; a specifier needs an expression to convert. Every
    // conversion family consumes through `operand`, so each is listed.
    for ([_][]const u8{ "%d", "%b", "%h", "%o", "%t", "%v", "%c", "%s", "%u", "%z", "%e", "%f", "%g" }) |spec| {
        var buf: [128]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "module m; reg x; initial $display(\"{s}\", , x); endmodule", .{spec});
        try root.expectRejected(src, "not a null argument");
    }
    try root.expectRejected("module m; reg [8*8:1] s; reg x; initial $sformat(s, \"%d\", ); endmodule", "not a null argument");
    // A null argument past a variable format's end: W1153, and the run goes on.
    try expectRun("module m; reg [8*8:1] s; integer x; initial begin x = 7; $sformat(s, \"%d\", x, ); $display(\"done\"); end endmodule", "done\n");
    try expectRun("module m; reg [8*8:1] s, f; integer x; initial begin f = \"%d\"; x = 7; $sformat(s, f, x, ); $display(\"done\"); end endmodule", "done\n");
}

test "§15.5.1 negative limits at the ends of i64 are solved, not overflowed" {
    // Oracle: §15.5.1, a set of limits no delayed signals can meet has its
    // most negative limit changed to 0 (W1162) and the run goes on. The
    // limits are i64's ends, where `d - S + eps` leaves i64.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var out = std.Io.Writer.Allocating.init(arena.allocator());
    const src =
        \\module t(input c, input d);
        \\specify $setuphold(posedge c, d, -64'sd9223372036854775807, -64'sd9223372036854775807); endspecify
        \\initial $display("ok");
        \\endmodule
    ;
    try root.run(arena.allocator(), src, .{ .negative_timing = true }, &bag, &out.writer);
    try std.testing.expectEqualStrings("ok\n", out.written());
}

test "§16.2 a CELL whose INSTANCE names a list, not a path, is reported, not applied" {
    // OVI SDF 3.0 gives INSTANCE a path; `(INSTANCE (u))` is no path, and
    // the file's text decides that, so it warns (W1105) and the run goes on.
    try expectAnnotated(
        \\module c(input b); endmodule
        \\module t; reg a = 0; c u(.b(a));
        \\initial begin $sdf_annotate("d.sdf"); $display("ran"); end
        \\endmodule
    , "(DELAYFILE (CELL (CELLTYPE \"c\") (INSTANCE (u))))", "ran\n", "names no instance");
}

test "§16.2.4 INTERCONNECT delays that sum past 2^64 ticks saturate, never overflow" {
    // Two loads of 1e13 ns at 1 fs are 2e19 ticks together, past u64: the
    // file's numbers are input, so the sum saturates (a delay that never
    // ends) instead of overflowing.
    try expectAnnotated(
        \\`timescale 1fs/1fs
        \\module c(input b, output y); assign y = b; endmodule
        \\module t; reg a = 0; wire y; c u(.b(a), .y(y));
        \\initial begin $sdf_annotate("d.sdf"); $display("ran"); end
        \\endmodule
    ,
        \\(DELAYFILE (CELL (CELLTYPE "t") (INSTANCE)
        \\  (DELAY (INCREMENT (INTERCONNECT a u.b (10000000000000)) (INTERCONNECT a u.b (10000000000000))))))
    , "ran\n", null);
}

test "vcd.callText: a `)` before any `(` ends the call, never underflows its depth" {
    // Oracle: callText's contract, the call through its closing
    // parenthesis, and no panic: a comment's `)`, or a `$dumpports;` with
    // no argument list followed by a closing one, underflowed the count.
    const callText = root.for_emitter.vcd.callText;
    try std.testing.expectEqualStrings("$dumpfile /* ", callText("$dumpfile /* ) */ (\"x.vcd\");", 0));
    try std.testing.expectEqualStrings("$dumpports; end ", callText("$dumpports; end ) (a)", 0));
}

test "sim.mixed.run refuses a timeline it cannot walk: empty, negative, NaN, running back, infinite, past 2^64 ticks" {
    // Oracle: VAMS §8.4 time starts at the DC point and only runs forward,
    // and a digital time is a u64 tick count (`Options.tick` 1 ns here, so
    // 1e20 s is 1e29 ticks). Equal times are a point solved once.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad = [_][]const f64{ &.{ 2e-9, 1e-9 }, &.{ 0, 3e-9, 2e-9, 4e-9 }, &.{}, &.{-1e-9}, &.{ 0, std.math.nan(f64) }, &.{ 0, std.math.inf(f64) }, &.{ 0, 1e20 } };
    for (bad) |times| {
        var bag = diag.Bag.init(arena.allocator());
        var out = std.Io.Writer.Allocating.init(arena.allocator());
        var dig = try root.elaborate(arena.allocator(), "`timescale 1ns/1ns\nmodule m; reg v; endmodule", .{}, &bag, &out.writer);
        var still: Still = .{};
        try std.testing.expectError(error.BadTimeline, mixed.run(Still, &still, &dig, .{ .times = times, .tick = 1e-9 }));
        try std.testing.expectEqual(@as(u32, 0), still.solves);
    }
    var bag = diag.Bag.init(arena.allocator());
    var out = std.Io.Writer.Allocating.init(arena.allocator());
    var dig = try root.elaborate(arena.allocator(), "`timescale 1ns/1ns\nmodule m; reg v; endmodule", .{}, &bag, &out.writer);
    var still: Still = .{};
    try mixed.run(Still, &still, &dig, .{ .times = &.{ 0, 1e-9, 1e-9 }, .tick = 1e-9 });
    try std.testing.expectEqual(@as(u32, 2), still.finished);
}

test "§12.2.1 a defparam segment is the escaped name the parser read, whatever `[`, `]`, `.` or `$` it holds" {
    // Oracle: IEEE 1364-2005 §3.7.1, an escaped identifier is the whole
    // printable run up to white space, so `\a[5] ` is one name and not
    // `a` indexed 5, and `\$4.n ` one name, not two segments; §12.2.1,
    // the defparam sets the parameter that name holds. Each design is its
    // plain twin with one name escaped, and prints the defparam's 7.
    const m = "module m; parameter p = 1; initial #1 $display(\"%0d\", p); endmodule ";
    try expectRun(m ++ "module top; m \\a[5] (); defparam \\a[5] .p = 7; endmodule", "7\n");
    try expectRun(m ++ "module top; m \\[3] (); defparam \\[3] .p = 7; endmodule", "7\n");
    try expectRun(m ++ "module top; m \\a]b (); defparam \\a]b .p = 7; endmodule", "7\n");
    try expectRun(m ++ "module top; m \\x.y[2] (); defparam \\x.y[2] .p = 7; endmodule", "7\n");
    // A name of the instance array `u` beside an escaped one.
    try expectRun(m ++ "module top; m u[1:0] (); defparam u[1].p = 7; endmodule", "1\n7\n");
    // The parameter's own name: `$` first, a `.` inside.
    try expectRun(
        \\module m; parameter \$4.n  = 1; initial #1 $display("%0d", \$4.n ); endmodule
        \\module top; m u (); defparam u.\$4.n  = 7; endmodule
    , "7\n");
    try expectRun(
        \\module m; parameter \a.n  = 1; initial #1 $display("%0d", \a.n ); endmodule
        \\module top; m \b[0] (); defparam \b[0] .\a.n  = 7; endmodule
    , "7\n");
}

test "§12.2.1 a defparam through a name that itself starts with `\\` names it, beside the `$`-led one" {
    // Oracle: IEEE 1364-2005 §3.7.1, `\\$x ` is the name `\$x` and
    // `\$x ` the different name `$x`; `\\a ` is `\a`, not `a`. A defparam
    // through each sets the parameter of the instance that name holds,
    // and the twin beside it keeps its own (each instance prints its `p`,
    // in source order): whatever the frontend interns, the path's
    // segments must be the names the tokens are.
    const m = "module m; parameter p = 1; initial #1 $display(\"%0d\", p); endmodule ";
    try expectRun(m ++ "module top; m \\\\$x (); m \\$x (); defparam \\\\$x .p = 7; endmodule", "7\n1\n");
    try expectRun(m ++ "module top; m \\\\a (); m a (); defparam \\\\a .p = 7; endmodule", "7\n1\n");
    try expectRun(m ++ "module top; m \\\\a (); m a (); defparam a.p = 7; endmodule", "1\n7\n");
    // The parameter's own name holds the `\\`.
    try expectRun(
        \\module m; parameter \\$q  = 1; initial #1 $display("%0d", \\$q ); endmodule
        \\module top; m u (); defparam u.\\$q  = 7; endmodule
    , "7\n");
}

test "an expression nested past a host thread's stack is refused at run time (E1100), never a crash" {
    // Oracle: deep_stack's contract: a walk on a thread `runGuarded` did
    // not start (a contract device's host, a VPI application, this
    // test's) is given 4 MiB and refused by name past it ("nesting here
    // exhausts the ... stack"), never a segfault. `elaborate` runs on its
    // own reservation; `runUntil` evaluates on the caller's stack. An
    // integer chain (`evalContext`) and a real one (`evalReal`). Each
    // length must also elaborate on the smallest reservation
    // `runGuarded` takes on a CI machine (256 MiB, Windows': measured, a
    // chain elaborates there up to 30,000 terms and not at 40,000), and
    // overflow an 8 MiB stack without the check (measured, Debug: the
    // integer chain by 10,000, the real one by 15,000; 10,000 real terms
    // fit). The 4 MiB refusal itself comes before 1,000 levels of either.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "reg [7:0] v, x; initial begin v = 1; x = v", "real v, x; initial begin v = 1.0; x = v" }) |head| {
        var src: std.ArrayList(u8) = .empty;
        try src.print(a, "module m; {s}", .{head});
        for (0..20_000) |_| try src.appendSlice(a, " + v");
        try src.appendSlice(a, "; $display(\"done\"); end endmodule");
        var bag = diag.Bag.init(a);
        var out = std.Io.Writer.Allocating.init(a);
        var r = try root.elaborate(a, src.items, .{}, &bag, &out.writer);
        try std.testing.expectError(error.DigitalFailed, r.runUntil(std.math.maxInt(root.Tick)));
        var messages = std.Io.Writer.Allocating.init(a);
        try diag.render(&bag, &messages.writer, .{});
        try std.testing.expect(std.mem.find(u8, messages.written(), "E1100") != null);
        try std.testing.expect(std.mem.find(u8, messages.written(), "exhausts the") != null);
        try std.testing.expectEqualStrings("", out.written());
    }
}
