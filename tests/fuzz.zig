//! In-process fuzz targets: bytes or generated tokens in,
//! a property checked on what the front end does with them.
//!
//! Under `zig build test` each runs through zrunner's `fuzz` (the corpus plus
//! seeded random inputs, deterministic). `zig build fuzz --fuzz[=N]` runs the
//! same tests coverage-guided on the stock runner.
//!
//! The oracle is the same for every target: no panic, no leak (the fuzz harness
//! checks `std.testing.allocator` per input), only the errors the API
//! declares, and a refusal always carries a diagnostic that names a clause or
//! says it is an engine limit, and renders. Zig 0.17's fuzzer has no
//! comparison feedback, so `tokens` builds sources from the language's own
//! vocabulary instead of hoping bytes spell `endmodule`.

const std = @import("std");
const vera = @import("vera");
const exe = @import("exe");
const sim = @import("sim");

const Smith = std.testing.Smith;

/// A compile's diagnostics must justify its verdict: a refusal has an error,
/// every entry has a catalogue title, and the bag renders.
fn checkDiagnostics(bag: *vera.diag.Bag, refused: bool) !void {
    if (refused) try std.testing.expect(bag.failed());
    for (0..bag.count()) |i| try std.testing.expect(vera.diag.info(bag.at(i).code).title.len != 0);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try vera.diag.render(bag, &sink.writer, .{ .explain_hint = false, .summary = false });
}

/// Analyses `src` to MIR (what `--lint` runs) and holds the result to the oracle.
fn lint(src: []const u8) !void {
    const gpa = std.testing.allocator;
    var bag: vera.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var res = vera.analyze(gpa, src, .{}, &bag) catch |err| switch (err) {
        error.CompileFailed => return checkDiagnostics(&bag, true),
        error.NoModule => return,
        else => |e| return e, // anything else is a finding
    };
    defer res.deinit(gpa);
    try checkDiagnostics(&bag, false);
}

fn bytesOne(_: void, s: *Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    try lint(buf[0..s.slice(&buf)]);
}

/// The vocabulary `tokensOne` draws from: keywords, operators and literals of
/// both languages, so a sequence reaches the parser's and lowering's arms.
const vocabulary = [_][]const u8{
    "module",      "endmodule", "analog",     "begin",    "end",                "if",           "else",     "case",
    "endcase",     "default",   "for",        "while",    "repeat",             "inout",        "input",    "output",
    "electrical",  "parameter", "localparam", "real",     "integer",            "genvar",       "branch",   "function",
    "endfunction", "initial",   "always",     "assign",   "wire",               "reg",          "generate", "endgenerate",
    "V",           "I",         "ddt",        "idt",      "exp",                "ln",           "sqrt",     "abs",
    "pow",         "limexp",    "cross",      "timer",    "@",                  "posedge",      "negedge",  "from",
    "exclude",     "inf",       "$strobe",    "$display", "$abstime",           "$temperature", "$limit",   "white_noise",
    "(",           ")",         ";",          ",",        "<+",                 "=",            "<=",       "==",
    "+",           "-",         "*",          "/",        "%",                  "**",           "?",        ":",
    "[",           "]",         "{",          "}",        "#",                  "&&",           "||",       "!",
    "~",           "&",         "|",          "^",        "<<",                 ">>",           "<",        ">",
    "0",           "1",         "1.5",        "1e-3",     "1k",                 "4'b10x1",      "8'hff",    "\"s\"",
    "a",           "b",         "p",          "n",        "x",                  "m",            "`define",  "`include",
    "`ifdef",      "`endif",    "`M",         "\n",       "(* desc = \"d\" *)",
};

/// A module header the generated body sits in, so most sequences get past
/// "no module" to the stages that do the work.
fn tokensOne(_: void, s: *Smith) anyerror!void {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll("module m(p, n); inout p, n; electrical p, n; real x; integer a;\n") catch return;
    if (s.boolWeighted(1, 3)) w.writeAll("analog begin\n") catch return;
    var n: usize = 0;
    while (n < 400 and !s.eos()) : (n += 1) {
        w.writeAll(vocabulary[s.index(vocabulary.len)]) catch break;
        w.writeByte(' ') catch break;
    }
    w.writeAll("\nend\nendmodule\n") catch {};
    try lint(w.buffered());
}

/// `//!` directive lines: the fixture grammar is an input too (`vera
/// --emit-exe` reads it), so it refuses with `exe.ParseError` and never panics.
fn directivesOne(_: void, s: *Smith) anyerror!void {
    const words = [_][]const u8{
        "param",  "bias",     "sweep",  "wave",        "psweep",    "temp", "time",      "solve", "analysis", "exit",
        "checks", "plusargs", "reject", "reject-only", "neighbour", "warn", "nowarn",    "noise", "acstim",   "acdyn",
        "qsite",  "seed",     "abstol", "limit",       "spice",     "lrm",  "inherited", "xfail", "print",    "fd-exempt",
    };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var tail: [256]u8 = undefined;
    while (!s.eos()) {
        w.writeAll("//! ") catch break;
        w.writeAll(words[s.index(words.len)]) catch break;
        w.writeByte(' ') catch break;
        w.writeAll(tail[0..s.slice(&tail)]) catch break;
        w.writeByte('\n') catch break;
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = exe.Spec.parse(arena.allocator(), w.buffered(), null) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {}, // every other `exe.ParseError` is a named refusal
    };
}

/// A structural 1364 design, elaborated and run by the digital engine. Its
/// first top module has continuous assignments and gates whose `delay3`
/// values are constants, variables, nets or expressions of them (G7: a
/// variable first value left the later ones untyped, `unreachable` at run
/// time). A second top module, elaborated after it, connects an instance
/// array through whole nets, selects and concatenations as wide as the port
/// or the port times the element count (G7: `arrayConn` typed one against
/// the first module's slots, out of bounds). Same oracle as `lint`: no
/// panic, and a refusal is diagnosed.
fn digitalOne(_: void, s: *Smith) anyerror!void {
    const delays = [_][]const u8{ "d", "w0", "r0", "d + 1", "r0[1:0]", "w1[0]", "1", "2.5", "1:2:3", "0" };
    const values = [_][]const u8{ "r0", "r1", "~r0", "r0 & r1", "w0", "{r0, r1}", "1'bz", "8'hx5", "w1 ^ r1" };
    const lhs = [_][]const u8{ "w0", "w1", "w2", "w1[0]", "{w0, w1}" };
    // Each `cw` or `2 * cw` bits wide, for a port of `cw` bits on two
    // elements; `pick` spells `{h}` and `{l}`. The outputs are nets.
    const ins = [_][]const u8{ "a", "q", "{a, b}", "{ra, b}", "q[{h}:0]", "ra", "{b[{l}:0], a[{l}:0]}" };
    const outs = [_][]const u8{ "o", "{a, b}", "q", "{b, o[{l}:0], a[{l}:0]}" };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const cws = [_]u32{ 2, 4, 8 };
    const cw = cws[choose(s, cws.len)];
    const own = [_][]const u8{ "1", "i", "i[0] + 1" };
    w.print("module c(i, o); input [{d}:0] i; output [{d}:0] o; assign #({s}) o = i; endmodule\n", .{ cw - 1, cw - 1, own[choose(s, own.len)] }) catch return;
    w.writeAll("module m; reg [3:0] r0; reg [3:0] r1; integer d; wire [3:0] w0; wire [3:0] w1; wire [7:0] w2;\n") catch return;
    var n: usize = 0;
    while (n == 0 or (n < 6 and !s.eos())) : (n += 1) switch (choose(s, 3)) {
        0 => w.print("assign #({s}) {s} = {s};\n", .{ delays[choose(s, delays.len)], lhs[choose(s, lhs.len)], values[choose(s, values.len)] }) catch return,
        1 => w.print("assign #({s}, {s}) {s} = {s};\n", .{ delays[choose(s, delays.len)], delays[choose(s, delays.len)], lhs[choose(s, lhs.len)], values[choose(s, values.len)] }) catch return,
        else => w.print("buf #({s}, {s}, {s}) g{d}(w1[0], r0[0]);\n", .{ delays[choose(s, delays.len)], delays[choose(s, delays.len)], delays[choose(s, delays.len)], n }) catch return,
    };
    w.writeAll("initial begin d = 2; r0 = 0; r1 = 1; #3 r0 = 4'b1x0z; d = 0; #2 r1 = r0 + 1; #4 $display(\"%b %b %b\", w0, w1, w2); end\nendmodule\n") catch return;
    // A second top module: its slots come after every one of `m`'s.
    w.print("module n; wire [{d}:0] a, b; reg [{d}:0] ra; wire [{d}:0] q, o;\nassign a = ra + 1; assign b = ~ra;\nc u[1:0](.i(", .{ cw - 1, cw - 1, 2 * cw - 1 }) catch return;
    pick(&w, ins[choose(s, ins.len)], cw);
    w.writeAll("), .o(") catch return;
    pick(&w, outs[choose(s, outs.len)], cw);
    w.writeAll("));\ninitial begin ra = 1; #20 $display(\"%b %b\", q, o); end\nendmodule\n") catch return;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var bag: vera.diag.Bag = .init(arena.allocator());
    var out: std.Io.Writer.Discarding = .init(&.{});
    sim.digital.run(arena.allocator(), w.buffered(), .{ .event_budget = 10_000 }, &bag, &out.writer) catch |err| switch (err) {
        error.DigitalFailed => return checkDiagnostics(&bag, true),
        else => |e| return e,
    };
}

/// One of `len` choices, from one input byte. Not `Smith.index` or
/// `value`: on a plain run's random input they read a whole u64 and keep it
/// only when it lies in range, which it almost never does, so every choice
/// falls back to the first.
fn choose(s: *Smith, len: usize) usize {
    var b: [1]u8 = undefined;
    s.bytes(&b);
    return b[0] % len;
}

/// `t` with `{h}` spelled `2 * cw - 1` and `{l}` spelled `cw / 2 - 1`.
fn pick(w: *std.Io.Writer, t: []const u8, cw: u32) void {
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] == '{' and i + 2 < t.len and t[i + 2] == '}' and (t[i + 1] == 'h' or t[i + 1] == 'l')) {
            w.print("{d}", .{if (t[i + 1] == 'h') 2 * cw - 1 else cw / 2 - 1}) catch return;
            i += 2;
        } else w.writeByte(t[i]) catch return;
    }
}

/// Real fixtures, so the replay starts from inputs that reach every stage.
const corpus = [_][]const u8{
    @embedFile("conformance/tests/verilog-a/ch05_analog_behavior/resistor.va"),
    @embedFile("conformance/tests/verilog-a/ch05_analog_behavior/timer_negative_time_tol_rejected.va"),
    @embedFile("conformance/tests/verilog-a/ch04_expressions/arithmetic_operators.va"),
    @embedFile("conformance/tests/verilog-a/ch10_directives/compact_modeling_macro_implies_its_extensions.va"),
    @embedFile("conformance/tests/verilog/09_behavioral_modeling/assignment_force_release.v"),
    // #48: an attribute instance as the last token, inside an unclosed generate block.
    @embedFile("conformance/tests/verilog-a/ch06_hierarchy/generate_block_attribute_then_end_of_file_rejected.va"),
};

test "fuzz: .lint over raw bytes never panics, and every refusal is diagnosed" {
    try std.testing.fuzz({}, bytesOne, .{ .corpus = &corpus });
}

test "fuzz: .lint over generated token sequences never panics, and every refusal is diagnosed" {
    try std.testing.fuzz({}, tokensOne, .{});
}

test "fuzz: generated structural designs with variable delays and instance arrays run or refuse by name" {
    try std.testing.fuzz({}, digitalOne, .{});
}

test "fuzz: `//!` directive lines refuse by name and never panic" {
    try std.testing.fuzz({}, directivesOne, .{});
}
