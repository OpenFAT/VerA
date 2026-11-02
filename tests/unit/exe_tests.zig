//! Tests for directive parsing and runner generation: fixture text in,
//! verdicts on the parsed `tb.Spec` and the rendered runner out.
//! LRM: §2.6, §3.4.1, §4.2.1.1, §4.6.3, §4.6.4, §4.6.4.6, §5.2.1, §5.4.2, §5.6,
//! §5.8, §5.10.2, §6.5.2, §7.3.1, §9.15.
//!
//! The plan, as bug class, then oracle, then where:
//!   - a malformed line checks nothing: the grammar `parse.zig` and
//!     `operands.zig` document; parse.zig's per-keyword test and the
//!     refusals here.
//!   - a number reads differently from the model's own literal: §2.6's table
//!     and Zig's literals; operands.zig's `test number`.
//!   - a rendered testbench does not build: AstGen, the compiler's own front
//!     half, over generated directive sets ("every directive set ...").
//!   - a value reaches the testbench changed: Zig's literal reader;
//!     parts.zig's `test fmtF64`.
//!   - a sweep expands in the wrong order: the product written out by hand;
//!     points.zig's test and "sweep expansion ..." here.
//!   - the build command is wrong: argv derived by hand; src/zigbuild/exe.zig's tests.
//! The emitted solver and gates execute only in the fixture suite (`zig
//! build benchmark`), which builds and runs a testbench per fixture.

const std = @import("std");
const tb = @import("exe");
const Analysis = tb.Analysis;

const testing = std.testing;

/// `Spec.parse` with no diagnostics.
fn parse(arena: std.mem.Allocator, src: []const u8) tb.ParseError!tb.Spec {
    return tb.Spec.parse(arena, src, null);
}

/// `writeRunner` of `s.bench` under `facts`, into `arena`; a writer
/// failure is the arena's out of memory.
fn runnerWith(arena: std.mem.Allocator, title: []const u8, s: tb.Spec, facts: tb.Facts) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    tb.writeRunner(&aw.writer, arena, title, &s.bench, facts) catch |e| return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        else => |x| x,
    };
    return aw.written();
}

/// `runnerWith` and no compile facts.
fn runner(arena: std.mem.Allocator, title: []const u8, s: tb.Spec) ![]const u8 {
    return runnerWith(arena, title, s, .{});
}

/// `writeVpiLib` of `s.bench` under `facts`, into `arena`.
fn vpiLibWith(arena: std.mem.Allocator, title: []const u8, s: tb.Spec, facts: tb.Facts) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    tb.writeVpiLib(&aw.writer, title, &s.bench, facts) catch return error.OutOfMemory;
    return aw.written();
}

/// `vpiLibWith` and no compile facts.
fn vpiLib(arena: std.mem.Allocator, title: []const u8, s: tb.Spec) ![]const u8 {
    return vpiLibWith(arena, title, s, .{});
}

/// Every point of `bench` as its column values, through `pointCount` and `Row`.
fn expand(arena: std.mem.Allocator, bench: tb.Bench) ![]const []const f64 {
    const count = try tb.pointCount(&bench);
    const rows = try arena.alloc([]const f64, count);
    for (rows, 0..) |*row, n| {
        var it: tb.Row = .init(&bench, count, @intCast(n));
        var cells: std.ArrayList(f64) = .empty;
        while (it.next()) |v| try cells.append(arena, v);
        row.* = cells.items;
    }
    return rows;
}

/// Asserts that `src` parses and passes AstGen: every check a testbench
/// build makes before it resolves `device` and `contract` (unused or
/// never-mutated locals, undeclared names, shadowing). Prints `src` on
/// failure, since a generator chose it.
pub fn expectAstGen(src: []const u8) !void {
    const gpa = testing.allocator;
    const z = try gpa.dupeSentinel(u8, src, 0);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .{ .mode = .zig });
    defer tree.deinit(gpa);
    var zir = try std.zig.AstGen.generate(gpa, tree);
    defer zir.deinit(gpa);
    if (tree.errors.len == 0 and !zir.hasCompileErrors()) return;
    std.debug.print("{s}\n", .{src});
    return error.TestUnexpectedResult;
}

/// A mixed-signal plan with every naming hazard `writeMixed` escapes: a
/// quote and a backslash in the source, an `x`/`z` input, a three-word `reg`,
/// a `Z` (the escape marker) in a name, an event and an inserted module.
const sample_mixed: tb.Mixed = .{
    .source = "module m(a); \"quoted\" \\ endmodule\n",
    .top = "m",
    .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-12 } }},
    .inputs = &.{ "clk", "bus", "Zq" },
    .xz = &.{"clk"},
    .wide = &.{"bus"},
    .words = &.{3},
    .snaps = &.{"go"},
    .events = &.{.{ .name = "go", .edge = .posedge, .param = "go__ev" }},
    .inserts = &.{.{ .path = "m.i", .inst = "i", .port = "p", .module = "cm", .name = "cm0", .upper_port = "a", .lower_port = "d" }},
};

test "directives: defaults when the source has none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "module m; endmodule\n");
    try testing.expectEqual(@as(usize, 0), d.bench.sweeps.len);
    try testing.expectEqual(@as(usize, 0), d.bench.params.len);
    try testing.expectEqual(@as(f64, 300.15), d.bench.temperature_k);
    try testing.expectEqual(Analysis.dc, d.bench.analysis);
    try testing.expect((d.bench.print == .residual));
    try testing.expect(!d.bench.solve_free);
}

test "§5.6 `//! solve` unties the unknowns nothing else names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Default netlist: every unknown tied to the reference, so `//! bias V(p)`
    // on a two-terminal device is the potential across it.
    const tied = try runner(arena, "065_tied", try parse(arena, "//! bias V(p) = 0.5\n"));
    try testing.expect(std.mem.find(u8, tied, "var forced: [n_u]?f64 = @splat(0.0);") != null);
    try testing.expect(std.mem.find(u8, tied, "set(&x, &forced, \"p\", 0.5);") != null);

    // With `solve`, only what a directive names stays pinned.
    const d = try parse(arena, "//! bias V(ctrl) = 1.5\n//! solve\n");
    try testing.expect(d.bench.solve_free);
    const free = try runner(arena, "066_free", d);
    try testing.expect(std.mem.find(u8, free, "var forced: [n_u]?f64 = @splat(null);") != null);
    try testing.expect(std.mem.find(u8, free, "set(&x, &forced, \"ctrl\", 1.5);") != null);
    // The solve runs before the model prints (§5.6: semantics at a solution).
    const solve_at = std.mem.find(u8, free, "solve(&x, &forced").?;
    try testing.expect(solve_at < std.mem.find(u8, free, "point(0, &x").?);

    // It takes no operand.
    try testing.expectError(error.BadSyntax, parse(arena, "//! solve V(p)\n"));
}

test "directives: every form, including the §2.6 suffixes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        \\//! param is = 1e-14, n = 1.05
        \\//! bias V(c) = 0
        \\//! sweep V(a) = 0, 0.3, 0.6
        \\//! temp 350
        \\//! time 0, 1n
        \\//! analysis tran
        \\//! print none
        \\module m(a, c); endmodule
    );
    try testing.expectEqual(@as(usize, 2), d.bench.params.len);
    try testing.expectEqualStrings("is", d.bench.params[0].name);
    try testing.expectEqual(@as(f64, 1e-14), d.bench.params[0].value);
    try testing.expectEqualStrings("c", d.bench.bias[0].name);
    try testing.expectEqualStrings("a", d.bench.sweeps[0].name);
    try testing.expectEqual(@as(usize, 3), d.bench.sweeps[0].values.len);
    try testing.expectEqual(@as(f64, 0.6), d.bench.sweeps[0].values[2]);
    try testing.expectEqual(@as(f64, 350), d.bench.temperature_k);
    try testing.expectEqual(@as(f64, 1e-9), d.bench.times_s[1]);
    try testing.expectEqual(Analysis.tran, d.bench.analysis);
    try testing.expect(!(d.bench.print == .residual));
}

test "§5.10.3.1 an unwritten analysis is tran under a time grid, dc without one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(Analysis.tran, (try parse(a, "//! time 0, 1n\n")).bench.analysis);
    try testing.expectEqual(Analysis.dc, (try parse(a, "//! time 0\n")).bench.analysis);
    try testing.expectEqual(Analysis.dc, (try parse(a, "//! time 0, 1n\n//! analysis dc\n")).bench.analysis);
}

test "§5.4.2 `I(...)` names the flow unknown, not the node potential" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        \\//! bias V(a) = 1.0
        \\//! bias I(b) = 0.125
        \\//! sweep I(<c>) = 0, 1
        \\//! sweep I(a,b) = 0.25
        \\//! bias V(d[1]) = 2.0
        \\module m(a, b, c); endmodule
    );
    // `V(a)` is the node; the `I` forms are flow unknowns, sanitized as codegen
    // spells them.
    try testing.expectEqualStrings("a", d.bench.bias[0].name);
    try testing.expectEqualStrings("flowZ28bZ2cgndZ29", d.bench.bias[1].name);
    try testing.expectEqualStrings("flowZ28Z3ccZ3eZ29", d.bench.sweeps[0].name);
    // §5.4.2's two-terminal branch flow and a §6.5.2 vector element `b[i]`
    // must land on the members `emitTopology` prints (codegen's "the `U` block
    // is the SPELLING contract" test pins the other end).
    try testing.expectEqualStrings("flowZ28aZ2cbZ29", d.bench.sweeps[1].name);
    try testing.expectEqualStrings("dZ5b1Z5d", d.bench.bias[2].name);
    // `parseBindings` splits on top-level commas, so `I(a,b)` works in `bias`
    // as it does in `sweep`.
    const d2 = try parse(arena_state.allocator(), "//! bias I(a,b) = 0.25, V(z) = 3\n");
    try testing.expectEqualStrings("flowZ28aZ2cbZ29", d2.bench.bias[0].name);
    try testing.expectEqual(@as(f64, 0.25), d2.bench.bias[0].value);
    try testing.expectEqualStrings("z", d2.bench.bias[1].name);
    // A binding with no `=` is still an error.
    try testing.expectError(error.BadSyntax, parse(arena_state.allocator(), "//! bias I(a,b)\n"));
}

test "directives: a typo is an error, not a silently skipped test" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.UnknownDirective, parse(arena_state.allocator(), "//! sweeep V(a) = 1\n"));
    try testing.expectError(error.BadSyntax, parse(arena_state.allocator(), "//! sweep V(a)\n"));
    try testing.expectError(error.BadNumber, parse(arena_state.allocator(), "//! temp warm\n"));
}

test "directives: an lrm cite is a section, and an xfail points either way" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena, "//! lrm 4.5.11\n//! lrm A.8.3\n//! reject E0130\n//! xfail VerA accepts it\n");
    try testing.expectEqual(@as(usize, 2), d.harness.lrm.len);
    try testing.expectEqualStrings("4.5.11", d.harness.lrm[0]);
    try testing.expectEqualStrings("A.8.3", d.harness.lrm[1]);
    try testing.expectEqualStrings("VerA accepts it", d.harness.xfail.?);

    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm §5.8\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm 5.\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm Z.1\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm\n"));

    // An IEEE 1364 clause never reaches `lrm`, and `lrm` refuses one.
    const inh = try parse(arena, "//! inherited IEEE 1364-2005 18.1 ($dumpfile)\n//! inherited IEEE 1364-2005 8.1.4,8.2\n");
    try testing.expectEqual(@as(usize, 0), inh.harness.lrm.len);
    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm inherited IEEE 1364-2005 18.1\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! inherited 18.1\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! inherited IEEE 1364-2005 §18\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! inherited IEEE 1364-2005\n"));

    // On a run fixture too: VerA cannot yet build a legal example.
    const run = try parse(arena, "//! xfail no array formals in analog functions\n");
    try testing.expectEqual(@as(usize, 0), run.harness.reject.len);
    try testing.expectEqualStrings("no array formals in analog functions", run.harness.xfail.?);
    // A reason is required.
    try testing.expectError(error.BadSyntax, parse(arena, "//! xfail\n"));
}

test "directives: a sentence cite names one normative sentence of a clause" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena, "//! lrm 5.6.1.3:2\n//! lrm A.6.4:12\n//! inherited IEEE 1364-2005 9.2.2:1\n");
    try testing.expectEqualStrings("5.6.1.3:2", d.harness.lrm[0]);
    try testing.expectEqualStrings("A.6.4:12", d.harness.lrm[1]);
    // Sentences count from 1, and the ordinal is a number.
    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm 5.6.1.3:0\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm 5.6.1.3:\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm 5.6.1.3:2a\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm :2\n"));
}

test "directives: reject-only refuses alone, and a neighbour belongs to a refusal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena, "//! reject-only E0310\n//! neighbour legal_twin.va\n");
    try testing.expect(d.harness.reject_only);
    try testing.expectEqualStrings("E0310", d.harness.reject[0]);
    try testing.expectEqualStrings("legal_twin.va", d.harness.neighbours[0]);
    // A plain reject is not exclusive.
    try testing.expect(!(try parse(arena, "//! reject E0310\n")).harness.reject_only);
    // `reject-only` is still a reject: no check count, no warnings.
    try testing.expectError(error.BadSyntax, parse(arena, "//! reject-only E0310\n//! checks 1\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! reject-only\n"));
    // A neighbour on a positive fixture has nothing to be the neighbour of.
    try testing.expectError(error.BadSyntax, parse(arena, "//! neighbour legal_twin.va\n"));
    // One path per line, no spaces.
    try testing.expectError(error.BadSyntax, parse(arena, "//! reject E1\n//! neighbour a.va b.va\n"));
}

test "directives: reject-run is a refusal the run makes, with a failing status" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena, "//! reject-run E0816\n//! neighbour legal.va\n//! checks 1\n");
    try testing.expectEqualStrings("E0816", d.harness.reject_run[0]);
    try testing.expectEqual(@as(usize, 0), d.harness.reject.len);
    // The run compiles and may assert before it is refused.
    try testing.expectEqual(@as(?u32, 1), d.harness.expected_checks);
    // The status every run-time `error[...]` exits with, unless named.
    try testing.expectEqual(1, d.harness.expected_exit);
    try testing.expectEqual(3, (try parse(arena, "//! exit 3\n//! reject-run E0601\n")).harness.expected_exit);
    // A refusal that exits 0 is not one.
    try testing.expectError(error.BadSyntax, parse(arena, "//! reject-run E0601\n//! exit 0\n"));
    // Refused by the compiler or by the run, never both; and never unnamed.
    try testing.expectError(error.BadSyntax, parse(arena, "//! reject-run E0601\n//! reject E0601\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! reject-run\n"));
}

test "§4.6.4.6 `//! noise` states a correlation coefficient with another row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena, "//! noise thermal(a,b)#0 corr=1:-1 corr=2:0\n");
    const w = d.bench.noise.?[0];
    try testing.expectEqual(@as(usize, 2), w.corrs.len);
    try testing.expectEqual(@as(u16, 1), w.corrs[0].with);
    try testing.expectEqual(@as(f64, -1), w.corrs[0].rho);
    try testing.expectEqual(@as(f64, 0), w.corrs[1].rho);
    // A coefficient may depend on the bias, so it is read at a point.
    try testing.expect(w.needsPoint());
    for ([_][]const u8{ "corr=1", "corr=:1", "corr=x:1", "corr=1:", "corr=-1:1" }) |bad| {
        // BadSyntax or BadNumber: either way the line asserts nothing silently.
        if (parse(arena, try arena.print("//! noise thermal(a,b)#0 {s}\n", .{bad}))) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "§2.9.2 `//! meta` states one published desc/units row, in a fixed spelling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena,
        \\//! meta parameter res units="Ohms" desc="Resistance"
        \\//! meta variable cgs desc="gate-source capacitance"
        \\//! meta net d   desc="drain terminal"
        \\
    );
    try testing.expect((d.bench.meta != null));
    // `desc` before `units`, one space apart, whatever order the line used.
    try testing.expectEqualStrings("parameter res desc=\"Resistance\" units=\"Ohms\"", d.bench.meta.?[0]);
    try testing.expectEqualStrings("variable cgs desc=\"gate-source capacitance\"", d.bench.meta.?[1]);
    try testing.expectEqualStrings("net d desc=\"drain terminal\"", d.bench.meta.?[2]);
    const none = try parse(arena, "//! meta none\n");
    try testing.expect((none.bench.meta != null) and none.bench.meta.?.len == 0);
    for ([_][]const u8{ "port p desc=\"x\"", "net", "net d desc=x", "net d desc=\"x", "net d note=\"x\"", "net d desc=\"a\" desc=\"b\"" }) |bad| {
        try testing.expectError(error.BadSyntax, parse(arena, try arena.print("//! meta {s}\n", .{bad})));
    }
}

test "renderRunner emits the meta and correlation checks as parseable Zig" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! noise thermal(a,b)#0 corr=1:-1
        \\//! noise thermal(c,d)#0
        \\//! meta parameter r desc="R" units="Ohm"
        \\
    );
    const src = try runner(arena, "corr_meta", d);
    const z = try arena.dupeSentinel(u8, src, 0);
    var ast = try std.zig.Ast.parse(testing.allocator, z, .{ .mode = .zig });
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
    try testing.expect(std.mem.find(u8, src, "noise[0].corr[1] got=") != null);
    try testing.expect(std.mem.find(u8, src, "\"parameter r desc=\\\"R\\\" units=\\\"Ohm\\\"\"") != null);
}

test "§2.6 a scale factor is an exponent, not a multiplier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Bit equality with the same spelling in the model (`token_value.scaleExp`):
    // `200 * 1e-6` is a different double from `200e-6`.
    // In increasing order, as a time grid must be.
    const d = try parse(arena, "//! time 0, 1n, 200u, 2.5m, 1K\n");
    try testing.expectEqual(@as(f64, 0.0), d.bench.times_s[0]);
    try testing.expectEqual(@as(f64, 1e-9), d.bench.times_s[1]);
    try testing.expectEqual(@as(f64, 200e-6), d.bench.times_s[2]);
    try testing.expectEqual(@as(f64, 2.5e-3), d.bench.times_s[3]);
    try testing.expectEqual(@as(f64, 1e3), d.bench.times_s[4]);
    // The product must be computed at run time: comptime float arithmetic is
    // exact, so a literal `200.0 * 1e-6` would already be correctly rounded.
    var two_hundred: f64 = 200;
    _ = &two_hundred;
    const multiplied = two_hundred * 1e-6;
    try testing.expect(d.bench.times_s[2] == 200e-6);
    try testing.expect(multiplied != 200e-6);
    try testing.expect(d.bench.times_s[2] != multiplied);

    // A bare suffix is not a number, and neither is a suffix on nothing.
    try testing.expectError(error.BadNumber, parse(arena, "//! temp u\n"));
    // A plain float still goes straight through.
    const plain = try parse(arena, "//! temp 300.15\n");
    try testing.expectEqual(@as(f64, 300.15), plain.bench.temperature_k);
}

test "§5.4.2 a branch potential is not a solver unknown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `V(a,c)` is a potential difference, derived from two unknowns; refused
    // at parse time rather than failing the testbench build.
    try testing.expectError(error.BadUnknownName, parse(arena, "//! bias V(a,c) = 0.6\n"));
    try testing.expectError(error.BadUnknownName, parse(arena, "//! bias V(a, c) = 0.6\n"));
    try testing.expectError(error.BadUnknownName, parse(arena, "//! sweep V(a,c) = 0, 1\n"));

    // A branch flow is an unknown (§5.4.2), spelled through `naming.sanitize`
    // as codegen spells its `U` member.
    const flow = try parse(arena, "//! bias I(a,c) = 0.25\n");
    try testing.expectEqualStrings("flowZ28aZ2ccZ29", flow.bench.bias[0].name);

    // Whitespace inside the access function is not part of the name.
    const spaced = try parse(arena, "//! bias V( a ) = 0.5\n");
    try testing.expectEqualStrings("a", spaced.bench.bias[0].name);
}

test "§4.6.4 `//! noise` states the exported generator table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena, "//! noise thermal(a,b)#0\n//! noise flicker(d,s)#null\n");
    try testing.expect((d.bench.noise != null));
    try testing.expectEqual(@as(usize, 2), d.bench.noise.?.len);
    try testing.expectEqualStrings("thermal(a,b)#0", d.bench.noise.?[0].topo);
    try testing.expectEqualStrings("flicker(d,s)#null", d.bench.noise.?[1].topo);
    // A line with no `key=value` tail asserts the topology only.
    try testing.expect(d.bench.noise.?[0].name == null);
    try testing.expect(d.bench.noise.?[0].white == null);
    try testing.expect(!d.bench.noise.?[0].needsPoint());

    // `none` asserts an empty table, unlike an absent directive.
    const none = try parse(arena, "//! noise none\n");
    try testing.expect((none.bench.noise != null));
    try testing.expectEqual(@as(usize, 0), none.bench.noise.?.len);

    const silent = try parse(arena, "//! analysis dc\n");
    try testing.expect(!(silent.bench.noise != null));

    // A misspelled kind is caught at parse time.
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise pink(a,b)#0\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal a,b\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a)#0\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(,b)#0\n"));
    // The §4.6.4.6 source id (digits or `null`) is mandatory.
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a,b)\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a,b)#\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a,b)#x\n"));
    // A node name is not checked: the unknowns are not known at parse time.
    const odd = try parse(arena, "//! noise shot(nosuchnode,b)#3\n");
    try testing.expectEqual(@as(usize, 1), odd.bench.noise.?.len);
}

test "§4.6.4 a `//! noise` line states the row's contents as well as its place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena,
        \\//! noise thermal(p,n)#0 name=thermal white=4e-18
        \\//! noise flicker(p,n)#1 name=flicker flicker=1e-20 ef=1.25 rtol=1e-4
        \\//! noise table(p,n)#2 name=tbl interp=log points=1.0:1e-18,1e3:1e-21
        \\
    );
    try testing.expectEqual(@as(usize, 3), d.bench.noise.?.len);

    // The fields are a tail; the topology string is unchanged.
    try testing.expectEqualStrings("thermal(p,n)#0", d.bench.noise.?[0].topo);
    try testing.expectEqualStrings("thermal", d.bench.noise.?[0].name.?);
    try testing.expectEqual(@as(f64, 4e-18), d.bench.noise.?[0].white.?);
    try testing.expectEqual(@as(f64, 1e-12), d.bench.noise.?[0].rtol); // the default
    try testing.expect(d.bench.noise.?[0].needsPoint());

    try testing.expectEqual(@as(f64, 1e-20), d.bench.noise.?[1].flicker.?);
    try testing.expectEqual(@as(f64, 1.25), d.bench.noise.?[1].ef.?);
    try testing.expectEqual(@as(f64, 1e-4), d.bench.noise.?[1].rtol);

    // `interp`/`points` are comptime table data and need no bias.
    try testing.expectEqual(.log, d.bench.noise.?[2].interp.?);
    try testing.expectEqualSlices([2]f64, &.{ .{ 1.0, 1e-18 }, .{ 1e3, 1e-21 } }, d.bench.noise.?[2].points.?);
    try testing.expect(!d.bench.noise.?[2].needsPoint());

    // `psd` is the same pair syntax, densities at frequencies, and also needs
    // no bias: it reads the table, not `noisePsd`.
    const with_psd = try parse(arena, "//! noise table(p,n)#0 psd=4e3:1.7e-17,1.0:9e-18\n");
    try testing.expectEqualSlices([2]f64, &.{ .{ 4e3, 1.7e-17 }, .{ 1.0, 9e-18 } }, with_psd.bench.noise.?[0].psd.?);
    try testing.expect(with_psd.bench.noise.?[0].points == null);
    try testing.expect(!with_psd.bench.noise.?[0].needsPoint());

    // A space inside the parentheses still parses.
    const spaced = try parse(arena, "//! noise thermal(p, n)#0 name=x\n");
    try testing.expectEqualStrings("thermal(p, n)#0", spaced.bench.noise.?[0].topo);

    // An unknown key is refused, since nothing would check it.
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a,b)#0 whte=1\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a,b)#0 name\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise table(a,b)#0 interp=spline\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise table(a,b)#0 points=1.0\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise table(a,b)#0 psd=\n"));
}

test "§9.17.3 `//! seed` and `//! limit` state the published cold start and clamp" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena,
        \\//! seed V(si) = -0.7, V(b) = -1.7
        \\//! seed V(g) = 0
        \\//! limit V(b) = 0 -> V(b) = 0.1, converged = 0
        \\//! limit -> V(b) = 1.5
        \\
    );
    try testing.expect((d.bench.seeds != null));
    try testing.expectEqual(@as(usize, 3), d.bench.seeds.?.len);
    try testing.expectEqualStrings("b", d.bench.seeds.?[1].name);
    try testing.expectEqual(@as(usize, 2), d.bench.limits.len);
    try testing.expectEqual(@as(usize, 1), d.bench.limits[0].old.len);
    try testing.expectEqualStrings("converged", d.bench.limits[0].want[1].name);
    try testing.expectEqual(@as(usize, 0), d.bench.limits[1].old.len);

    const none = try parse(arena, "//! seed none\n");
    try testing.expect((none.bench.seeds != null) and none.bench.seeds.?.len == 0);
    // No `->` names no output, and no output is no assertion.
    try testing.expectError(error.BadSyntax, parse(arena, "//! limit V(b) = 0\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! limit V(b) = 0 ->\n"));
}

test "§4.6.3 `//! acstim` states the exported stimulus table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena,
        \\//! acstim (p,n) name=ac mag=2.0 phase=1.0471975511965976
        \\//! acstim (q, n) mag=1.0 phase=1.5707963267948966 rtol=1e-6
        \\
    );
    try testing.expect((d.bench.acstim != null));
    try testing.expectEqual(@as(usize, 2), d.bench.acstim.?.len);
    try testing.expectEqualStrings("(p,n)", d.bench.acstim.?[0].topo);
    try testing.expectEqualStrings("ac", d.bench.acstim.?[0].name.?);
    try testing.expectEqual(@as(f64, 2.0), d.bench.acstim.?[0].mag.?);
    try testing.expectEqual(@as(f64, 1e-12), d.bench.acstim.?[0].rtol); // the default
    try testing.expectEqual(@as(f64, 1e-6), d.bench.acstim.?[1].rtol);
    try testing.expect(d.bench.acstim.?[0].needsPoint());

    // Canonicalised to the device's spelling.
    try testing.expectEqualStrings("(q,n)", d.bench.acstim.?[1].topo);
    // `name=` is optional; §4.6.3 defaults `analysis_name` to "ac".
    try testing.expect(d.bench.acstim.?[1].name == null);

    // `none` asserts an empty table.
    const none = try parse(arena, "//! acstim none\n");
    try testing.expect((none.bench.acstim != null));
    try testing.expectEqual(@as(usize, 0), none.bench.acstim.?.len);

    // An unknown key is refused.
    try testing.expectError(error.BadSyntax, parse(arena, "//! acstim (a,b) magnitude=1\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! acstim (a,b) mag\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! acstim a,b mag=1\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! acstim (a) mag=1\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! acstim (,b) mag=1\n"));
}

test "`//! acdyn` names a slot, a frequency and the complex term" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena, "//! acdyn (out, in) f=125M re=0.5 im=-0.5 tol=1e-9\n");
    try testing.expectEqual(@as(usize, 1), d.bench.acdyn.len);
    try testing.expectEqualStrings("out", d.bench.acdyn[0].row);
    try testing.expectEqualStrings("in", d.bench.acdyn[0].col);
    try testing.expectEqual(@as(f64, 125e6), d.bench.acdyn[0].f_hz);
    try testing.expectEqual(@as(f64, -0.5), d.bench.acdyn[0].im);
    try testing.expectEqual(@as(f64, 1e-9), d.bench.acdyn[0].tol);
    // f, re and im are each required; an unknown key is refused.
    try testing.expectError(error.BadSyntax, parse(arena, "//! acdyn (out,in) re=1 im=0\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! acdyn (out,in) f=1 im=0\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! acdyn (out,in) f=1 re=1 im=0 phase=0\n"));
}

test "analysis takes an optional §9.15 analysis_name after the kind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const named = try parse(arena, "//! analysis dc mydc\n");
    try testing.expectEqual(.dc, named.bench.analysis);
    try testing.expectEqualStrings("mydc", named.bench.analysis_name);
    try testing.expectEqualStrings("", (try parse(arena, "//! analysis tran\n")).bench.analysis_name);
    try testing.expectError(error.BadSyntax, parse(arena, "//! analysis dc two words\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! analysis nosuch\n"));
}

test "plusargs preserves tokens, duplicate arguments and repeated-line order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena, "//! plusargs +HELLO\t+gain=7 +gain=8\r\n//! plusargs +HELLO +empty= +literal=$HOME;*\n");
    const want = [_][]const u8{ "+HELLO", "+gain=7", "+gain=8", "+HELLO", "+empty=", "+literal=$HOME;*" };
    try testing.expectEqual(want.len, d.harness.plusargs.len);
    for (want, d.harness.plusargs) |expected, actual| try testing.expectEqualStrings(expected, actual);
    // Existing defaults are unaffected; metacharacters above are literal bytes.
    try testing.expectEqual(0, d.harness.expected_exit);
    try testing.expectEqual(null, d.harness.expected_checks);
    try testing.expect((d.bench.print == .residual));
    try testing.expectEqual(0, (try parse(arena, "//! checks 2\n")).harness.plusargs.len);
}

test "plusargs rejects malformed operands rather than dropping them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "", "+", "HELLO", "+ok missingplus", "+s=\"hello\"", "+s='hello'", "+s=\\value", "+s=\x00", "+s=\x7f", "+s=\x80", "+a\r+b" }) |bad| {
        const source = try arena.print("//! plusargs {s}\n", .{bad});
        try testing.expectError(error.BadSyntax, parse(arena, source));
    }
}

test "expected process exit status is explicit and bounded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(0, (try parse(arena, "")).harness.expected_exit);
    try testing.expectEqual(1, (try parse(arena, "//! exit 1\n")).harness.expected_exit);
    try testing.expectEqual(255, (try parse(arena, "//! exit 255\n")).harness.expected_exit);
    try testing.expectError(error.BadNumber, parse(arena, "//! exit 256\n"));
    try testing.expectError(error.BadNumber, parse(arena, "//! exit -1\n"));
}

test "expected runtime check count is positive, unique and not a rejection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(null, (try parse(arena, "")).harness.expected_checks);
    try testing.expectEqual(@as(?u32, 215), (try parse(arena, "//! checks 215\n")).harness.expected_checks);
    for ([_][]const u8{ "", "0", "-1", "+1", "1.0", "1_0", "two" }) |bad| {
        const source = try arena.print("//! checks {s}\n", .{bad});
        try testing.expectError(error.BadNumber, parse(arena, source));
    }
    try testing.expectError(error.BadSyntax, parse(arena, "//! checks 1\n//! checks 2\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! checks 1\n//! reject E0208\n"));
}

test "warn is a named substring on a compiling fixture; nowarn stands alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena, "//! warn W0853\n//! warn not applied at this call\n");
    try testing.expectEqual(@as(usize, 2), d.harness.warn.len);
    try testing.expectEqualStrings("not applied at this call", d.harness.warn[1]);
    try testing.expect((try parse(arena, "//! nowarn\n")).harness.nowarn);
    try testing.expectError(error.BadSyntax, parse(arena, "//! warn\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! nowarn W0853\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! warn W0853\n//! nowarn\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! warn W0853\n//! reject E0208\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! nowarn\n//! reject E0208\n"));
}

test "sweep expansion is the cartesian product, last fastest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! sweep V(a) = 0, 1
        \\//! sweep V(b) = 10, 20, 30
    );
    const pts = try expand(arena, d.bench);
    try testing.expectEqual(@as(usize, 6), pts.len);
    try testing.expectEqualSlices(f64, &.{ 0, 10 }, pts[0]);
    try testing.expectEqualSlices(f64, &.{ 0, 20 }, pts[1]);
    try testing.expectEqualSlices(f64, &.{ 0, 30 }, pts[2]);
    try testing.expectEqualSlices(f64, &.{ 1, 10 }, pts[3]);
    try testing.expectEqualSlices(f64, &.{ 1, 30 }, pts[5]);
}

test "sweep expansion stops at points_max, counting the product" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vals = try arena.alloc(f64, tb.points_max + 1);
    for (vals, 0..) |*v, i| v.* = @floatFromInt(i);
    const at_cap: tb.Bench = .{ .sweeps = &.{.{ .name = "a", .values = vals[0..tb.points_max] }} };
    try testing.expectEqual(tb.points_max, (try expand(arena, at_cap)).len);
    const over: tb.Bench = .{ .sweeps = &.{.{ .name = "a", .values = vals }} };
    try testing.expectError(error.TooManyPoints, expand(arena, over));
    // 64 x 65 is past the cap, though neither column is.
    const product: tb.Bench = .{
        .sweeps = &.{.{ .name = "a", .values = vals[0..64] }},
        .psweeps = &.{.{ .name = "r", .values = vals[0..65] }},
    };
    try testing.expectError(error.TooManyPoints, expand(arena, product));
    // Unknown columns first, then parameter columns, the parameter fastest.
    const both: tb.Bench = .{
        .sweeps = &.{.{ .name = "a", .values = vals[0..2] }},
        .psweeps = &.{.{ .name = "r", .values = vals[5..8] }},
    };
    const pts = try expand(arena, both);
    try testing.expectEqual(@as(usize, 6), pts.len);
    try testing.expectEqualSlices(f64, &.{ 0, 5 }, pts[0]);
    try testing.expectEqualSlices(f64, &.{ 0, 7 }, pts[2]);
    try testing.expectEqualSlices(f64, &.{ 1, 5 }, pts[3]);
    // No sweep is one point with no columns.
    const one = try expand(arena, .{});
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(usize, 0), one[0].len);
}

test "a bench past points_max is refused before a byte is written" {
    // Oracle: the writer's own count of what it was handed.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vals = try arena.alloc(f64, 65);
    for (vals, 0..) |*v, i| v.* = @floatFromInt(i);
    const over: tb.Bench = .{
        .sweeps = &.{.{ .name = "a", .values = vals[0..64] }},
        .psweeps = &.{.{ .name = "r", .values = vals }},
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try testing.expectError(error.TooManyPoints, tb.writeRunner(&aw.writer, arena, "over", &over, .{}));
    try testing.expectError(error.TooManyPoints, tb.writeRunner(&aw.writer, arena, "over", &over, .{ .mixed = sample_mixed }));
    try testing.expectEqual(0, aw.written().len);
}

test "a wave is per-timepoint and holds its last value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! time 0, 1n, 2n, 3n
        \\//! wave V(in) = 0, 1
        \\//! bias V(out) = 0
    );
    try testing.expectEqual(@as(usize, 4), d.bench.times_s.len);
    try testing.expectEqualStrings("in", d.bench.waves[0].name);
    try testing.expectEqual(@as(usize, 2), d.bench.waves[0].values.len);

    const src = try runner(arena, "060_wave", d);
    // Four points, `in` = 1 after the first, and one `stepPost` per point so
    // operator state advances.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, src, "        point("));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, src, "        if (stepPost(&model"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "= newState("));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, src, "set(&x, &forced, \"in\", 1);"));
}

test "each sweep point starts its transient from a fresh State" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! sweep V(a) = 0, 1, 2
        \\//! time 0, 1n
    );
    const src = try runner(arena, "061_reset", d);
    // Three sweep points x two times, one `newState` per sweep point.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "        point("));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, src, "= newState("));
    // Point numbers are global, so no two transcript blocks share a label.
    try testing.expect(std.mem.find(u8, src, "point(5, &x") != null);
    // §4.6.2 a dc sweep is one analysis: its points share one `State`.
    const dc = try runner(arena, "061_dc", try parse(arena, "//! sweep V(a) = 0, 1, 2"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, dc, "= newState("));
}

test "§5.10.2 global events mark the first and last point of each analysis" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A dc sweep is one analysis: events on its first and last step only.
    const swept = try runner(arena, "062_sweep", try parse(arena, "//! sweep V(a) = 0, 1, 2\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, swept, "sim_state.initial_step = true;"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, swept, "sim_state.final_step = true;"));
    try testing.expect(std.mem.find(u8, swept, "sim_state.initial_step = true;\n        sim_state.final_step = false;\n        sim_state.analog_initial = true;\n        var solved0 = solve(&x, &forced, &model, &inst);\n        if (crossRetry(&model, &inst, &x, &state)) |r| solved0 = locate(r, 0, &x, &forced, &model, &inst, &state, 0);\n        point(0,") != null);
    try testing.expect(std.mem.find(u8, swept, "sim_state.initial_step = false;\n        sim_state.final_step = true;\n        sim_state.analog_initial = true;\n        var solved2 = solve(&x, &forced, &model, &inst);\n        if (crossRetry(&model, &inst, &x, &state)) |r| solved2 = locate(r, 2, &x, &forced, &model, &inst, &state, 0);\n        point(2,") != null);
    // §5.2.1 `analog initial` re-runs per sub-task: all three points, while
    // the global event fires at one.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, swept, "sim_state.analog_initial = true;"));

    // With `//! time` each sweep block is its own transient analysis.
    const tran = try runner(arena, "063_tran", try parse(arena, "//! sweep V(a) = 0, 1\n//! time 0, 1n, 2n\n"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "sim_state.initial_step = true;"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "sim_state.final_step = true;"));
    // Two blocks, so two sub-tasks: one analog-initial pass each, at dt = 0.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "sim_state.analog_initial = true;"));

    // The single-point default is the Table 5-1 DCOP column: both events fire.
    const op = try runner(arena, "064_op", .{});
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, op, "sim_state.initial_step = true;"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, op, "sim_state.final_step = true;"));
}

test "renderRunner emits parseable Zig" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! param g = 2m
        \\//! sweep V(p) = 0, 1
        \\//! bias V(n) = 0
    );
    const src = try runner(arena, "001_demo", d);
    const z = try arena.dupeSentinel(u8, src, 0);
    var ast = try std.zig.Ast.parse(testing.allocator, z, .{ .mode = .zig });
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
    // The sweep really did become two straight-line blocks.
    try testing.expect(std.mem.find(u8, src, "point(0, &x") != null);
    try testing.expect(std.mem.find(u8, src, "point(1, &x") != null);
    // §3.4.1/§4.2.1.1: card values go through `cardValue`, which rounds for
    // an `integer` parameter.
    try testing.expect(std.mem.find(u8, src, "model.g = cardValue(@TypeOf(model.g), \"g\", 0.002)") != null);
}

test "every directive set that parses renders to Zig that passes AstGen" {
    // A structured generator: draws from lines that each parse alone, so
    // most sets parse and together they reach every emitter. The compile
    // facts a caller fills in are toggled per draw too. Seeded: a failure
    // replays, and prints the text it rendered.
    const pool = [_][]const u8{
        "//! param g = 2m, is = 1e-14",
        "//! param n = -0",
        "//! bias V(n) = 0",
        "//! bias I(a,b) = 0.25",
        "//! sweep V(p) = 0, 1",
        "//! sweep I(<c>) = 1e23, -1",
        "//! wave V(in) = 0, 1, 0.5",
        "//! psweep r = 1, 2",
        "//! temp 350",
        "//! time 0, 1n, 2n",
        "//! solve",
        "//! analysis tran",
        "//! analysis dc mydc",
        "//! analysis noise",
        "//! noise thermal(a,b)#0 name=th white=4e-18 corr=1:-1",
        "//! noise flicker(c, d)#1 flicker=1e-20 ef=1.25 rtol=1e-4",
        "//! noise table(p,n)#null name=t interp=log points=1:1e-18,1e3:1e-21 psd=10:2e-18",
        "//! noise none",
        "//! acstim (p, n) name=ac mag=2 phase=1.5",
        "//! acstim (q,n)",
        "//! acstim none",
        "//! acdyn (out, in) f=1k re=0.5 im=-0.5 tol=1e-9",
        "//! qsite g+ s- lte",
        "//! qsite none",
        "//! seed V(a) = -0.7, V(b) = 1",
        "//! seed none",
        "//! meta parameter r desc=\"R \\ ohm\" units=\"Ohm\"",
        "//! meta none",
        "//! abstol V(a) = 1e-6, I(a,b) = 1e-12",
        "//! limit V(b) = 0 -> V(b) = 0.1, converged = 0",
        "//! limit -> V(a) = 1.5",
        "//! print none",
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(0x7b0fd1);
    const r = prng.random();
    var rendered: usize = 0;
    for (0..64) |_| {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var src: std.ArrayList(u8) = .empty;
        for (0..1 + r.uintLessThan(usize, 8)) |_| {
            try src.appendSlice(arena, pool[r.uintLessThan(usize, pool.len)]);
            try src.append(arena, '\n');
        }
        const d = parse(arena, src.items) catch continue;
        var facts: tb.Facts = .{
            .op_states = if (r.boolean()) &.{ 0, 3 } else &.{},
            .validate_contract = r.boolean(),
            .certify = r.boolean(),
            .finite_proved = r.boolean(),
        };
        const fixed = runnerWith(arena, "gen \"t\" \\", d, facts) catch |e| switch (e) {
            error.TooManyPoints => continue,
            else => return e,
        };
        try expectAstGen(fixed);
        try expectAstGen(try vpiLibWith(arena, "gen", d, facts));
        facts.mixed = sample_mixed;
        try expectAstGen(try runnerWith(arena, "gen", d, facts));
        rendered += 1;
    }
    // Most draws are compatible lines; a run that renders few has stopped
    // testing anything.
    try testing.expect(rendered >= 16);
}

test "`//! seed none` renders a testbench that passes AstGen" {
    // `want` stays all null, so it must not be a `var` nothing writes.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectAstGen(try runner(arena, "seed_none", try parse(arena, "//! seed none\n")));
}

test "no rendered testbench uses a name Zig 0.17 deprecates" {
    // Deprecated in 0.17 and removed after it. A testbench is compiled by
    // whatever Zig the host has, so one of these breaks every fixture at once.
    const deprecated = [_][]const u8{ "@intFromEnum(", "@enumFromInt(", "std.mem.indexOf", "std.mem.lastIndexOf" };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena, "//! noise thermal(a,b)#0\n//! acstim (a,b)\n//! seed V(a) = 1\n//! abstol V(a) = 1e-6\n");
    const texts = [_][]const u8{
        try runner(arena, "dep", d),
        try runnerWith(arena, "dep", d, .{ .mixed = sample_mixed }),
        try vpiLib(arena, "dep", d),
    };
    for (texts) |src| for (deprecated) |name| {
        if (std.mem.find(u8, src, name)) |at| {
            std.debug.print("`{s}` at byte {d}\n", .{ name, at });
            return error.TestUnexpectedResult;
        }
    };
}

test "a `//! time` grid strictly increases" {
    // `dt` is the step from the previous time (§4.5.3), and `sim.mixed.run`
    // takes the same list ascending: a repeated or backward time is a typo.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "0, 2n, 1n", "0, 1n, 1n", "1n, 0" }) |bad| {
        try testing.expectError(error.BadSyntax, parse(arena, try arena.print("//! time {s}\n", .{bad})));
    }
    try testing.expectEqual(@as(usize, 1), (try parse(arena, "//! time 5n\n")).bench.times_s.len);
    try testing.expectEqual(@as(usize, 3), (try parse(arena, "//! time 0, 1n, 1.5n\n")).bench.times_s.len);
}

test "a time and a temperature are finite" {
    // `std.fmt.parseFloat` reads `NaN` and `infinity` (`nan` and `inf` end in
    // a §2.6 scale letter and fail as numbers). None is a §9.10 `$abstime`
    // or `$temperature`, and a NaN time also slips past the order check.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "//! time NaN\n",
        "//! time infinity\n",
        "//! time 0, infinity\n",
    }) |line| try testing.expectError(error.BadSyntax, parse(arena, line));
    for ([_][]const u8{ "//! temp NaN\n", "//! temp infinity\n", "//! temp -infinity\n" }) |line|
        try testing.expectError(error.BadNumber, parse(arena, line));
}

test "the operand forms of meta, acstim and acdyn refuse what they cannot read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "//! meta net d desc=\"a\" desc=\"b\"\n", // a field twice
        "//! meta net d desc=\"open\n", // no closing quote
        "//! meta net d desc=bare\n", // a value is quoted
        "//! meta net\n", // no name
        "//! meta port d\n", // not a decl kind
        "//! acstim (p,n\n", // no `)`
        "//! acstim (p) mag=1\n", // one terminal
        "//! acstim p,n\n", // no `(`
        "//! acstim (p,n) gain=1\n", // an unknown key
        "//! acdyn (a,b) f=1 re=0\n", // `im` is required
        "//! noise thermal(a,b)\n", // no `#source`
        "//! noise thermal(a,b)#x\n", // a source is digits or null
        "//! noise hum(a,b)#0\n", // not a generator kind
        "//! noise thermal(a,b)#0 points=\n", // an empty knot list
    }) |line| try testing.expectError(error.BadSyntax, parse(arena, line));
}

/// `parse` then `writeRunner` and `writeVpiLib`, in an arena over `gpa`.
fn parseRender(gpa: std.mem.Allocator, src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena, src);
    _ = try runner(arena, "oom", d);
    _ = try vpiLib(arena, "oom", d);
}

test "parse and render report OutOfMemory at every allocation" {
    try testing.checkAllAllocationFailures(testing.allocator, parseRender, .{
        "//! param g = 2m\n//! sweep V(a) = 0, 1\n//! psweep r = 1, 2\n//! time 0, 1n\n//! wave V(b) = 0, 1\n" ++
            "//! noise thermal(a,b)#0 white=1 corr=0:1 points=1:2\n//! acstim (a,b) mag=1\n//! acdyn (a,b) f=1 re=0 im=0\n" ++
            "//! qsite a+ lte\n//! seed V(a) = 1\n//! meta net a desc=\"x\"\n//! abstol V(a) = 1e-6\n//! limit V(a) = 0 -> V(a) = 1\n",
    });
}

test "an exit status is plain decimal digits, as a check count is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "+1", "1_0", "0x1", "1 2" }) |bad| {
        try testing.expectError(error.BadNumber, parse(arena, try arena.print("//! exit {s}\n", .{bad})));
    }
}

test "a binding whose access function names nothing is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "//! bias V() = 1\n",
        "//! bias I(a, ) = 1\n",
        "//! seed V() = 1\n",
        "//! abstol x[] = 1e-6\n",
        "//! limit V() = 0 -> V(a) = 1\n",
    }) |line| try testing.expectError(error.BadSyntax, parse(arena, line));
}

test "§8.2 each psweep point is its own card, derived and set up" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = try runner(arena, "ps", try parse(arena, "//! sweep V(a) = 0, 1\n//! psweep r = 1, 2, 3\n"));
    try expectAstGen(src);
    // 2 x 3 points, the parameter column fastest.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "        var pm = model;\n"));
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "        if (comptime @hasDecl(D, \"derive\")) D.derive(Val, &pm);\n"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "        pm.r = cardValue(@TypeOf(pm.r), \"r\", 3);\n"));
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "solve(&x, &forced, &pm, &inst);"));
}

test "the mixed runner hands each point to sim.mixed and refuses the device-table checks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena, "//! sweep V(a) = 0, 1\n//! time 0, 1n\n//! wave V(in) = 0, 1\n//! noise none\n");
    const src = try runnerWith(arena, "mx", d, .{ .mixed = sample_mixed });
    try expectAstGen(src);
    // A sweep point is an analysis; the time grid is `sim.mixed.run`'s.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "        runMixed(&model, &inst, &x, &forced, &state, &n);\n"));
    try testing.expect(std.mem.find(u8, src, "are not read by the mixed-signal runner") != null);
    try testing.expect(std.mem.find(u8, src, "const mixed_timescales = [_]TimescaleEvent{ .{ .at = 0, .value = .{ .unit = 0.000000001, .precision = 0.000000000001 } }, };\n") != null);
    try testing.expect(std.mem.find(u8, src, "        set(a.x, a.forced, \"in\", pwl(&wave_0, t));\n") != null);
    // §7.3.1 a three-word `reg` is three ports, words 0 to 2.
    try testing.expect(std.mem.find(u8, src, ".word = 2 }") != null);
    try testing.expect(std.mem.find(u8, src, ".word = 3 }") == null);
}

test "the VPI library takes the card, the bias and the waves into its exports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena, "//! param g = 2m\n//! bias V(n) = 0\n//! time 0, 1n\n//! wave V(in) = 0, 1\n");
    const src = try vpiLib(arena, "vpi", d);
    try expectAstGen(src);
    for ([_][]const u8{
        "    g_model.g = cardValue(@TypeOf(g_model.g), \"g\", 0.002);\n",
        "    set(&g_x, &g_forced, \"n\", 0);\n",
        "    set(&g_x, &g_forced, \"in\", pwl(&wave_0, t));\n",
        "const times = [_]f64{ 0, 0.000000001 };\n",
        "const wave_0 = [_]f64{ 0, 1 };\n",
    }) |want| try testing.expect(std.mem.find(u8, src, want) != null);
    // The host owns the time walk: the library declares no operating point.
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, src, "        point("));
}

test "§4.5.2 an operator unknown is never forced, even when every other one is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena, "//! sweep V(a) = 0, 1\n");
    const src = try runnerWith(arena, "ops", d, .{ .op_states = &.{ 2, 5 } });
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "        forced[5] = null;\n"));
    // After the tie-everything default, before the directives' own pins.
    const untie = std.mem.find(u8, src, "forced[2] = null;").?;
    try testing.expect(std.mem.find(u8, src, "var forced: [n_u]?f64 = @splat(0.0);").? < untie);
    try testing.expect(untie < std.mem.find(u8, src, "set(&x, &forced, \"a\", 0);").?);
}

test "the compile facts a caller sets reach the runner's head" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const off = try runner(arena, "f", .{});
    const on = try runnerWith(arena, "f", .{}, .{ .validate_contract = true, .certify = true, .finite_proved = true });
    try testing.expect(std.mem.find(u8, off, "pub const vera_validate_contract = false;\n") != null);
    try testing.expect(std.mem.find(u8, off, "const fd_certify = false;\n") != null);
    try testing.expect(std.mem.find(u8, off, "const finite_proved = false;\n") != null);
    try testing.expect(std.mem.find(u8, on, "pub const vera_validate_contract = true;\n") != null);
    try testing.expect(std.mem.find(u8, on, "const fd_certify = true;\n") != null);
    try testing.expect(std.mem.find(u8, on, "const finite_proved = true;\n") != null);
}

test "§9.15 analysis_name is the kind's spelling unless the line names one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tran = try runner(arena, "an", try parse(arena, "//! time 0, 1n\n"));
    try testing.expect(std.mem.find(u8, tran, "const analysis_name = \"tran\";\n") != null);
    try testing.expect(std.mem.find(u8, tran, "    run_kind = .tran;\n") != null);
    const named = try runner(arena, "an", try parse(arena, "//! analysis dc mydc\n"));
    try testing.expect(std.mem.find(u8, named, "const analysis_name = \"mydc\";\n") != null);
    try testing.expect(std.mem.find(u8, named, "    run_kind = .dc;\n") != null);
}

test "`//! spice` lines join into one netlist in source order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena, "//! spice R1 a b 1k\n//! spice + tc1=0\n//! lrm 5.8\n//! spice C1 b 0 1p\n");
    try testing.expectEqualStrings("R1 a b 1k\n+ tc1=0\nC1 b 0 1p", d.harness.spice);
    try testing.expectEqualStrings("", (try parse(arena, "")).harness.spice);
}

test "the directive line rule: indentation, CRLF and a marker with no space" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena, "  //! temp 310\r\n\t//!lrm 5.8\r\n// ! temp 999\n//!\n//!   \n");
    try testing.expectEqual(@as(f64, 310), d.bench.temperature_k);
    try testing.expectEqualStrings("5.8", d.harness.lrm[0]);
    // `//!!` opens with the word `!`, which no directive is.
    try testing.expectError(error.UnknownDirective, parse(arena, "//!! lrm 5.8\n"));
}

test "an lrm cite's annex is one letter, A to H" {
    for ("ABCDEFGH") |letter| {
        const cite = [1]u8{letter};
        try testing.expect(tb.validSection(&cite));
    }
    for ("IJZah") |letter| {
        const cite = [1]u8{letter};
        try testing.expect(!tb.validSection(&cite));
    }
    try testing.expect(tb.validSection("H.2:3"));
}

test "a `//! time` before 0 is refused when the directives are read (BadTime)" {
    // Oracle: a transient starts at 0 (VAMS §4.5.4: `$abstime` is not
    // negative). The rewrite accepted -1n and the mixed runner failed at
    // run time. 0 itself is the first legal time.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.BadTime, tb.Spec.parse(arena_state.allocator(), "//! time -1n, 0, 1n\n", null));
    _ = try tb.Spec.parse(arena_state.allocator(), "//! time 0, 1n\n", null);
}
