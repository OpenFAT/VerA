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

const Smith = std.testing.Smith;

/// A compile's diagnostics must justify its verdict: a refusal has an error,
/// every entry has a catalogue title, and the bag renders.
fn checkDiagnostics(bag: *vera.diag.Bag, refused: bool) !void {
    if (refused) try std.testing.expect(bag.failed());
    for (0..bag.count()) |i| try std.testing.expect(vera.diag.info(bag.at(i).code).title.len != 0);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try vera.diag.render(bag, &sink.writer, .{ .explain_hint = false, .summary = false });
}

/// Compiles `src` to MIR (`.lint`) and holds the result to the oracle.
fn lint(src: []const u8) !void {
    const gpa = std.testing.allocator;
    var bag: vera.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var res = vera.compileSourceOpts(gpa, src, .lint, .{ .diags = &bag }) catch |err| switch (err) {
        error.CompileFailed => return checkDiagnostics(&bag, true),
        error.NoModule => return,
        else => |e| return e, // anything else is a finding
    };
    defer res.deinit();
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
/// --emit-exe` reads it), so it refuses with `tb.Error` and never panics.
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
    _ = vera.tb.parse(arena.allocator(), w.buffered()) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {}, // every other `tb.Error` is a named refusal
    };
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

test "fuzz: `//!` directive lines refuse by name and never panic" {
    try std.testing.fuzz({}, directivesOne, .{});
}
