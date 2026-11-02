//! The `analog` module through its public API: lowering and the SSA builder
//! under every allocation failure, lowering's determinism, the §4.6.4.6
//! noise coefficient and §5.6 per-`<+` lookups, and the self-checks that
//! lower a source and read the diagnostics or the MIR out.
//!
//! LRM clauses this file's code cites: §1.1, §1.3.1, §1.3.1.2, §2.6.2-§2.9.2,
//! §3.2-§3.13.2, §4.2-§4.7.3, §5.3.2-§5.11, §6.3.1-§6.8, §7.3-§7.3.2.1, §9.
//! IEEE 1364-2005 clauses cited: §4.2.1, §5.5.1.

const std = @import("std");
const Lower = @import("analog").Lower;
const Ssa = @import("analog").Ssa;
const Mir = @import("ir").Mir;
const diag = @import("diag");

/// Sources that between them reach every file of the module: parameters and an
/// alias, ports, a vector net and a branch, variables and a runtime-indexed
/// array, a function, a conditional, a loop, a §7.3.1 select of a wide
/// discrete input (its `Model` words), a contribution; a named block, a
/// case, an event with a timer, a display and a strobe, a `$bound_step`, a
/// `$limit` through a user limiter, a seeded distribution, a `$table_model`,
/// a filter, a noise source, an indirect branch and a contribution.
const oom_sources = [_][]const u8{
    \\module m(p, q, o);
    \\  inout p, q, o; electrical p, q, o;
    \\  parameter real g = 1.0;
    \\  real x, n;
    \\  integer s, k;
    \\  analog function real lim;
    \\    input vnew, vold; real vnew, vold;
    \\    lim = vnew;
    \\  endfunction
    \\  analog begin : blk
    \\    real y;
    \\    s = 7;
    \\    x = $rdist_uniform(s, 0.0, 1.0);
    \\    case (k) 0: y = 1.0; default: y = 2.0; endcase
    \\    @(timer(0, 1n)) k = k + 1;
    \\    @(cross(V(p) - 0.5, 1)) $strobe("x=%g", x);
    \\    $display("y=%g", y);
    \\    $bound_step(1n);
    \\    n = white_noise(1e-20, "th");
    \\    I(p) <+ g * $limit(V(p), lim) + 3.0 * n + ddt(1p * V(p));
    \\    I(q) <+ $table_model(V(q), '{0.0, 1.0}, '{0.0, 2.0}, "1LL") + transition(y, 0, 1n);
    \\    V(o) : V(q) == 0.0;
    \\  end
    \\endmodule
    ,
    \\module m(p, n);
    \\  inout p, n; electrical p, n;
    \\  electrical [1:0] b;
    \\  branch (p, n) br;
    \\  parameter real g = 1.0 from [0:inf);
    \\  localparam integer k = 3;
    \\  aliasparam ga = g;
    \\  real x, a[0:2];
    \\  integer i;
    \\  analog function real sq;
    \\    input v; real v;
    \\    sq = v * v;
    \\  endfunction
    \\  analog begin
    \\    x = 0.0;
    \\    for (i = 0; i < k; i = i + 1) a[i % 3] = sq(V(br)) + i;
    \\    if (V(p) > 0.5) x = a[i % 3]; else x = -g;
    \\    I(br) <+ x * V(br) + 0.0 * V(b[1], b[0]);
    \\  end
    \\endmodule
    ,
    \\module m(p);
    \\  inout p; electrical p;
    \\  reg [63:0] r;
    \\  initial #1 r = 64'h1234_5678_9abc_def0;
    \\  real y;
    \\  analog begin
    \\    y = r[40:33];
    \\    I(p) <+ y * V(p);
    \\  end
    \\endmodule
    ,
};

/// Lowers `src` with every buffer, the SSA builder's tables included, from
/// `gpa`; a failed allocation must come back as `error.OutOfMemory`.
fn lowerAll(gpa: std.mem.Allocator, src: []const u8) !void {
    var h: Lower.Harness = undefined;
    try h.init(gpa, src);
    defer h.deinit();
    h.low.builder.map = gpa;
    const out = try h.lower() orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(out.nodes.len != 0);
}

test "lower: every allocation failure unwinds as OutOfMemory and leaks nothing" {
    for (oom_sources) |src| try std.testing.checkAllAllocationFailures(std.testing.allocator, lowerAll, .{src});
}

test "lower: the same source lowers to the same MIR and node table twice" {
    // Determinism oracle: a hash map's iteration order reaching the output
    // would make two lowerings of one source differ.
    for (oom_sources) |src| {
        var runs: [2]Lower.Harness = undefined;
        for (&runs) |*h| try h.init(std.testing.allocator, src);
        defer for (&runs) |*h| h.deinit();
        var outs: [2]Lower.Lowered = undefined;
        for (&runs, &outs) |*h, *o| o.* = (try h.lower()).?;
        try std.testing.expectEqualSlices(Mir.Opcode, runs[0].mir.insts.items(.op), runs[1].mir.insts.items(.op));
        try std.testing.expectEqual(outs[0].nodes.len, outs[1].nodes.len);
        for (outs[0].nodes.items(.name), outs[1].nodes.items(.name)) |a, b| try std.testing.expectEqualStrings(a, b);
        try std.testing.expectEqual(outs[0].params.items.len, outs[1].params.items.len);
        for (outs[0].params.items, outs[1].params.items) |a, b| try std.testing.expectEqualStrings(a.name, b.name);
    }
}

/// A diamond (§5.8) then a loop (§5.9) whose header is sealed after its
/// back edge, every read through the builder, every table from `gpa`.
fn ssaProgram(gpa: std.mem.Allocator) !void {
    var mir: Mir = .{};
    defer mir.deinit(gpa);
    var b = Ssa.SsaBuilder.init(gpa, &mir);
    b.map = gpa;
    defer b.deinit();
    const entry = try mir.addBlock(gpa);
    const then_b = try mir.addBlock(gpa);
    const else_b = try mir.addBlock(gpa);
    const join = try mir.addBlock(gpa);
    const header = try mir.addBlock(gpa);
    const body = try mir.addBlock(gpa);
    const exit = try mir.addBlock(gpa);
    try b.sealBlock(entry);
    try b.addPredecessor(then_b, entry);
    try b.addPredecessor(else_b, entry);
    try b.sealBlock(then_b);
    try b.sealBlock(else_b);
    try b.addPredecessor(join, then_b);
    try b.addPredecessor(join, else_b);
    try b.sealBlock(join);
    const x = b.newPlace();
    const i = b.newPlace();
    try b.writeVariable(x, then_b, .f_one);
    try b.writeVariable(x, else_b, .f_two);
    try b.writeVariable(i, entry, .zero);
    const xj = try b.readVariable(x, join);
    try b.addPredecessor(header, join);
    try b.addPredecessor(body, header);
    try b.sealBlock(body);
    const iv = try b.readVariable(i, body);
    try b.writeVariable(i, body, try mir.emit(gpa, body, .iadd, &.{ iv, .one }));
    try b.addPredecessor(header, body);
    try b.sealBlock(header);
    try b.addPredecessor(exit, header);
    try b.sealBlock(exit);
    // The diamond's phi survives the loop; the induction variable is a real phi.
    try std.testing.expectEqual(mir.resolveAlias(xj), mir.resolveAlias(try b.readVariable(x, exit)));
    try std.testing.expectEqual(iv, mir.resolveAlias(try b.readVariable(i, exit)));
}

test "SsaBuilder: every allocation failure unwinds as OutOfMemory and leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ssaProgram, .{});
}

/// The one noise row of contribution 0 of `body`, lowered in a module with
/// electrical `p`, `q` and real variables `n`, `x`.
fn noiseRow(h: *Lower.Harness, body: []const u8) !Lower.NoiseSrc {
    const src = try std.testing.allocator.print(
        \\module m(p, q);
        \\  inout p, q; electrical p, q;
        \\  real n, x;
        \\  analog begin
        \\{s}
        \\  end
        \\endmodule
    , .{body});
    defer std.testing.allocator.free(src);
    try h.init(std.testing.allocator, src);
    const out = (try h.lower()) orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
    const srcs = out.contributions.items[0].noise_srcs;
    try std.testing.expectEqual(@as(usize, 1), srcs.len);
    return srcs[0];
}

fn constOf(mir: *const Mir, v: Mir.Value) ?f64 {
    return switch (mir.valueDef(mir.resolveAlias(v))) {
        .float_const => |x| x,
        .inst_result, .int_const, .undef, .str_const, .param_ref, .block_param => null,
    };
}

test "§4.6.4.6 noise coefficient: the factor, its §1.3.1.2 sign, and the shapes with none" {
    const Want = union(enum) { factor: f64, nonlinear, runtime };
    const cases = [_]struct { body: []const u8, want: Want }{
        .{ .body = "n = white_noise(1); I(p) <+ 3.0 * n;", .want = .{ .factor = 3.0 } },
        // `I(q,p) <+ c*n` drives the canonical (p,q) branch with -c.
        .{ .body = "n = white_noise(1); I(q, p) <+ 3.0 * n;", .want = .{ .factor = -3.0 } },
        .{ .body = "n = white_noise(1); I(p) <+ n / 4.0 + V(p);", .want = .runtime },
        // The generator squared has no single factor.
        .{ .body = "n = white_noise(1); I(p) <+ n * n;", .want = .nonlinear },
        // A diamond: the coefficient is the phi of the arms' factors.
        .{ .body = "n = white_noise(1); if (V(q) > 0) x = 2.0 * n; else x = 5.0 * n; I(p) <+ x;", .want = .runtime },
    };
    for (cases) |c| {
        var h: Lower.Harness = undefined;
        defer h.deinit();
        const row = try noiseRow(&h, c.body);
        switch (c.want) {
            .factor => |f| {
                try std.testing.expect(!row.nonlinear);
                try std.testing.expectEqual(f, constOf(&h.mir, row.coeff).?);
            },
            .nonlinear => {
                try std.testing.expect(row.nonlinear);
                try std.testing.expectEqual(Mir.Value.f_one, row.coeff);
            },
            .runtime => {
                try std.testing.expect(!row.nonlinear);
                try std.testing.expect(row.coeff != .f_zero);
                try std.testing.expectEqual(@as(?f64, null), constOf(&h.mir, row.coeff));
            },
        }
    }
}

test "§5.6 the per-`<+` lookups: indirect pairs, opposite quantities and probe pairs are unordered or per branch" {
    try Lower.expectBodies(&.{
        // §5.6.7.2 on the reversed pair: E0409 whichever spelling comes second.
        .{ .src = "analog begin V(p, q) : V(p) == 0.0; I(q, p) <+ 1e-6; end", .code = .E0409 },
        // §1.3.1: a contribution on the reversed spelling makes (p,q) a source.
        .{ .src = "analog begin x = V(p, q) + I(p, q); I(q, p) <+ x * 1m; end", .code = null },
    });
}

test "§5.6.1.3 a parallel named branch keeps what it retained" {
    // `I(b)` is another branch, so `V(a)` survives it; `I(a)` is the same
    // branch, so it discards what `V(a)` retained.
    const cases = [_]struct { flow: []const u8, kept: f64 }{
        .{ .flow = "b", .kept = 1.0 },
        .{ .flow = "a", .kept = 0.0 },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p, q);
            \\  inout p, q; electrical p, q;
            \\  branch (p, q) a, b;
            \\  analog begin
            \\    V(a) <+ 1.0;
            \\    I({s}) <+ 2.0;
            \\  end
            \\endmodule
        , .{c.flow});
        defer std.testing.allocator.free(src);
        var h: Lower.Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        const out = (try h.lower()) orelse {
            h.dump();
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(@as(usize, 2), out.contributions.items.len);
        // `wrote_val` is §5.6.1.3's retention flag: 1 kept, 0 discarded.
        try std.testing.expectEqual(c.kept, constOf(&h.mir, out.contributions.items[0].wrote_val).?);
    }
}

test "Clause 9 calls in expression position: the argument rules lowering judges" {
    try Lower.expectBodies(&.{
        // §9.5.1 Table 9-24: "rw" is no `type` form; "r+b" is.
        .{ .src = "analog begin iv = $fopen(\"o.txt\", \"rw\"); I(p) <+ iv; end", .code = .E0889 },
        .{ .src = "analog begin iv = $fopen(\"o.txt\", \"r+b\"); I(p) <+ iv * V(p); end", .code = null },
        // §9.5.1/§9.5.2: a descriptor is "a 32-bit integer".
        .{ .src = "analog begin iv = $feof(r); I(p) <+ iv; end", .code = .E0888 },
        // `$prev` takes exactly one argument.
        .{ .src = "analog begin x = $prev(V(p), 1.0); I(p) <+ x; end", .code = .E0809 },
        .{ .src = "analog begin x = $prev(V(p)); I(p) <+ x * V(p); end", .code = null },
        // §9.5.3: the string writers are tasks, with no value.
        .{ .src = "analog begin iv = $swrite(sv, \"a\"); I(p) <+ iv; end", .code = .E0813 },
        // §9.19: a port identifier, not a variable.
        .{ .src = "analog begin iv = $port_connected(x); I(p) <+ iv; end", .code = .E0822 },
        .{ .src = "analog begin iv = $port_connected(q); I(p) <+ iv * V(p); end", .code = null },
        // §9.15 Table 9-28's hierarchy rows fold here.
        .{ .src = "analog begin sv = $simparam$str(\"module\"); I(p) <+ V(p); end", .code = null },
        // §9.17.3: the first argument is an access function, and the second a
        // string or an analog function (a variable is neither, §2.8).
        .{ .src = "analog I(p) <+ $limit(x, \"pnjlim\", 0.025, 0.6);", .code = .E0891 },
        .{ .src = "analog I(p) <+ $limit(V(p), x);", .code = .E0891 },
        // §9.13.2: a degree of freedom is a count in the reference domain.
        .{ .src = "analog begin iv = $dist_chi_square(seed, 1.5); I(p) <+ iv; end", .code = .E0816 },
        .{ .src = "analog begin iv = $dist_chi_square(seed, 2); I(p) <+ iv * V(p); end", .code = null },
    });
}

/// Lowers `body` (as `expectBodies` does) with `tbl` written to `t.tbl` in a
/// fresh directory on the include path; null means it lowered clean.
fn tableVerdict(body: []const u8, tbl: []const u8) !?@import("diag").Code {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "t.tbl", .data = tbl });
    const dir = ".zig-cache/tmp/" ++ tmp.sub_path;
    const gpa = std.testing.allocator;
    const src = try gpa.print(
        \\module m(p, q);
        \\  inout p, q; electrical p, q;
        \\{s}
        \\endmodule
    , .{body});
    defer gpa.free(src);
    var h: Lower.Harness = undefined;
    try h.init(gpa, src);
    defer h.deinit();
    const dirs = [_][]const u8{dir};
    h.low.opts.include_dirs = &dirs;
    if (try h.lower() != null) return null;
    return h.bag.at(0).code;
}

test "§9.21.1 data files and §4.6.4.3 noise_table files: the shared format" {
    const D = @import("diag").Code;
    const cases = [_]struct { body: []const u8, tbl: []const u8, want: ?D }{
        // Comments anywhere, blank lines, tabs and CRLF are all format.
        .{ .body = "analog I(p) <+ $table_model(V(p), \"t.tbl\");", .tbl = "# x y\n0 0\n\n1\t2 # end\r\n", .want = null },
        // Rows of unequal width are no data set: the first call's error, not
        // the compilation's (§9.21.1 "captured on the first call").
        .{ .body = "analog I(p) <+ $table_model(V(p), \"t.tbl\");", .tbl = "0 0\n1\n", .want = null },
        // A file of only comments holds no data set either.
        .{ .body = "analog I(p) <+ $table_model(V(p), \"t.tbl\");", .tbl = "# nothing\n\n", .want = null },
        // One input needs a dependent column too.
        .{ .body = "analog I(p) <+ $table_model(V(p), \"t.tbl\");", .tbl = "0\n1\n", .want = .E0815 },
        // Table 9-30 `I` spends a column on no dimension: three columns, one
        // input, the dependent is column 3.
        .{ .body = "analog I(p) <+ $table_model(V(p), \"t.tbl\", \"I,1LL;1\");", .tbl = "9 0 0\n9 1 2\n", .want = null },
        // Fewer sub-strings than dimensions: the rest keep `1LL`.
        .{ .body = "analog I(p) <+ $table_model(V(p), V(q), \"t.tbl\", \"1CC\");", .tbl = "0 0 0\n0 1 1\n1 0 1\n1 1 2\n", .want = null },
        // §4.6.4.3: pairs, one per line.
        .{ .body = "analog I(p) <+ noise_table(\"t.tbl\");", .tbl = "1 1e-20\n10 1e-21\n", .want = null },
        .{ .body = "analog I(p) <+ noise_table(\"t.tbl\");", .tbl = "1 1e-20 3\n", .want = .E0519 },
        .{ .body = "analog I(p) <+ noise_table(\"t.tbl\");", .tbl = "1 x\n", .want = .E0519 },
        .{ .body = "analog I(p) <+ noise_table(\"vera_no_such.tbl\");", .tbl = "", .want = .E0519 },
    };
    for (cases) |c| try std.testing.expectEqual(c.want, try tableVerdict(c.body, c.tbl));
}

test "§5.8.1 isStaticValue: a block or value judged static once stays judged, and nothing else is" {
    try Lower.expectBodies(&.{
        // The second `if` reuses the first's verdict on the entry chain, and
        // its own merge of two static arms is static too.
        .{ .src = "analog begin x = g; if (g > 0) x = 2 * g; if (x > 0) r = ddt(V(p)); I(p) <+ r; end", .code = null },
        // A static walk first, then a merge one arm of which reads a probe:
        // the earlier verdicts must not leak into the dynamic one.
        .{ .src = "analog begin x = g; if (g > 0) x = 2 * g; if (x > 0) r = 1; if (V(q) > 0) x = V(p); if (x > 0) r = ddt(V(p)); I(p) <+ r; end", .code = .E0514 },
    });
}

// ---------------------------------------------------------------------------
// Lowering self-checks: source in, diagnostics or MIR out.
// ---------------------------------------------------------------------------
const Access = Lower.Access;

/// The one lowering harness (`Lower.Harness`), shared with every `analog/*.zig` test.
const Harness = Lower.Harness;

test "§6.3.1 paramset defparams follow final parameter values and freeze the selected generate shape" {
    const source =
        \\module top(p);
        \\  inout p; electrical p;
        \\  parameter integer enabled = 1;
        \\  card #(.select(enabled)) u(p);
        \\endmodule
        \\paramset card wrapper;
        \\  parameter integer select = 1;
        \\  .enabled = select;
        \\endparamset
        \\module wrapper(p);
        \\  inout p; electrical p;
        \\  parameter integer enabled = 1;
        \\  if (enabled) begin bad child(p); end
        \\  analog I(p) <+ 0.0;
        \\endmodule
        \\module bad(p);
        \\  inout p; electrical p;
        \\  leaf child(p); defparam child.gain = 5.0;
        \\endmodule
        \\module leaf(p);
        \\  inout p; electrical p;
        \\  parameter real gain = 1.0;
        \\  analog I(p) <+ gain * V(p);
        \\endmodule
    ;
    for ([_]?f64{ null, 0, 1 }) |override| {
        var h: Harness = undefined;
        try h.init(std.testing.allocator, source);
        defer h.deinit();
        var overrides: [1]Lower.ParamOverride = undefined;
        if (override) |value| {
            overrides[0] = .{ .name = "enabled", .value = value };
            h.low.opts.param_overrides = &overrides;
        }
        if (override != null and override.? == 0) {
            const out = try h.low.lowerFile();
            const index = h.low.param_index.get("u.enabled").?;
            try std.testing.expect(out.params.items[index].shape);
            try std.testing.expectEqual(@as(u32, 0), h.bag.err_count);
        } else {
            try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
            var found = false;
            for (0..h.bag.count()) |i| if (h.bag.at(i).code == .E0926) {
                try std.testing.expect(std.mem.find(u8, h.bag.at(i).message, "`u`") != null);
                found = true;
            };
            try std.testing.expect(found);
        }
    }
}

test "lower: system math aliases preserve operand-sensitive result types" {
    const cases = [_]struct { expr: []const u8, op: Mir.Opcode, div: Mir.Opcode }{
        .{ .expr = "abs(a)", .op = .iabs, .div = .idiv },
        .{ .expr = "$abs(a)", .op = .iabs, .div = .idiv },
        .{ .expr = "min(a,b)", .op = .imin, .div = .idiv },
        .{ .expr = "$min(a,b)", .op = .imin, .div = .idiv },
        .{ .expr = "max(a,b)", .op = .imax, .div = .idiv },
        .{ .expr = "$max(a,b)", .op = .imax, .div = .idiv },
        .{ .expr = "abs(r)", .op = .fabs, .div = .fdiv },
        .{ .expr = "$abs(r)", .op = .fabs, .div = .fdiv },
        .{ .expr = "min(a,r)", .op = .fmin, .div = .fdiv },
        .{ .expr = "$min(a,r)", .op = .fmin, .div = .fdiv },
        .{ .expr = "$min(r,a)", .op = .fmin, .div = .fdiv },
        .{ .expr = "max(r,a)", .op = .fmax, .div = .fdiv },
        .{ .expr = "$max(r,a)", .op = .fmax, .div = .fdiv },
        .{ .expr = "$max(a,r)", .op = .fmax, .div = .fdiv },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p);
            \\inout p; electrical p;
            \\parameter integer a = 3, b = 5;
            \\parameter real r = 3.0;
            \\analog I(p) <+ {s}/2;
            \\endmodule
        , .{c.expr});
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        _ = try h.low.lowerFile();
        const ops = h.mir.insts.items(.op);
        try std.testing.expectEqual(@as(usize, 1), std.mem.countScalar(Mir.Opcode, ops, c.op));
        try std.testing.expectEqual(@as(usize, 1), std.mem.countScalar(Mir.Opcode, ops, c.div));
    }
}

test "lower: system math aliases reject wrong arity" {
    for ([_][]const u8{ "$abs()", "$abs(1,2)", "$min(1)", "$min(1,2,3)", "$max(1)", "$max(1,2,3)" }) |expr| {
        const src = try std.testing.allocator.print(
            "module m(p); inout p; electrical p; analog I(p) <+ {s}; endmodule",
            .{expr},
        );
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }
        var found = false;
        for (0..h.bag.count()) |i| {
            if (h.bag.at(i).code == .E0506) found = true;
        }
        try std.testing.expect(found);
    }
}

test "lower: contribution splits into resistive and reactive parts" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module rc(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1k from (0:inf);
        \\  parameter real c = 1p;
        \\  real g;
        \\  analog begin
        \\    g = 1.0 / r;
        \\    if (V(p,n) > 0.0)
        \\      I(p,n) <+ g * V(p,n);
        \\    I(p,n) <+ ddt(c * V(p,n));
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();

    // §6.5 ports first, in header order — this is the host's terminal order.
    try std.testing.expectEqual(@as(u32, 2), h.low.out.num_ports);
    try std.testing.expectEqualStrings("p", h.low.out.nodes.items(.name)[0]);
    try std.testing.expectEqualStrings("n", h.low.out.nodes.items(.name)[1]);

    // §3.4.2 the value range MUST survive to proof.zig.
    try std.testing.expectEqual(@as(usize, 2), h.low.out.params.items.len);
    try std.testing.expectEqualStrings("r", h.low.out.params.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), h.low.out.params.items[0].ranges.len);
    try std.testing.expect(h.low.out.params.items[0].ranges[0].kind == .from);

    // §5.6.1.3 both `<+` statements accumulate into ONE target…
    try std.testing.expectEqual(@as(usize, 1), h.low.out.contributions.items.len);
    const c = h.low.out.contributions.items[0];
    try std.testing.expectEqual(Access.flow, c.access);
    try std.testing.expectEqual(@as(u32, 0), @backingInt(c.hi));
    try std.testing.expectEqual(@as(u32, 1), @backingInt(c.lo));
    // …and §5.6.1.2 splits them: the guarded g*V is resistive, ddt(c*V) is not.
    const resist = h.mir.resolveAlias(c.resist_val);
    const react = h.mir.resolveAlias(c.react_val);
    try std.testing.expect(resist != .f_zero); // a phi over the §5.8 guard
    try std.testing.expectEqual(Mir.Opcode.phi, h.mir.instOp(h.mir.valueDef(resist).inst_result));
    // The reactive part is `c * V(p,n)` — the charge, NOT its derivative.
    const react_inst = h.mir.valueDef(react).inst_result;
    try std.testing.expectEqual(Mir.Opcode.fadd, h.mir.instOp(react_inst));
    try std.testing.expectEqual(Mir.Opcode.fmul, h.mir.instOp(
        h.mir.valueDef(h.mir.instData(react_inst).binary.rhs).inst_result,
    ));
}

test "lower: a ddt that is not a linear factor is its own unknown, row and charge site (§4.5.2)" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module nonlinear(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p,n) <+ sin(ddt(V(p,n)));
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 3), h.low.out.nodes.len);
    try std.testing.expect(h.low.out.nodes.items(.kind)[2] == .op_state);
    try std.testing.expectEqual(@as(usize, 1), h.low.out.charge_sites.items.len);
    try std.testing.expectEqual(@as(f64, -1.0), h.low.out.charge_sites.items[0].sign);
}

test "lower: genvar loops unroll, procedural loops do not" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module chain(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  genvar i;
        \\  analog begin
        \\    for (i = 0; i < 3; i = i + 1)
        \\      I(a,b) <+ i * V(a,b);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    // §6.6.1: three unrolled bodies accumulate into one target, and the loop
    // left no CFG behind (entry only).
    try std.testing.expectEqual(@as(usize, 1), h.low.out.contributions.items.len);
    try std.testing.expectEqual(@as(u32, 1), h.mir.blockCount());
}

test "lower: §3.2.2 a runtime-indexed array is one storage, a constant-indexed one is scalars" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  genvar g;
        \\  real h[0:7], c[0:1][0:2];
        \\  integer k, i;
        \\  analog begin
        \\    @(initial_step) k = 0;
        \\    for (g = 0; g < 2; g = g + 1) c[g][1] = V(a,b);
        \\    for (i = 0; i < 8; i = i + 1) h[i] = c[1][1] * i;
        \\    h[k] = 2.0 * h[k];
        \\    I(a,b) <+ h[3] + c[0][1];
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(!h.bag.failed());
    // `h` is read and written at `i` and `k`: one storage of 8. `c` is only
    // ever indexed by constants and a genvar, so it stays six places.
    try std.testing.expectEqual(@as(usize, 1), h.low.out.mem_arrays.items.len);
    try std.testing.expectEqualStrings("h", h.low.out.mem_arrays.items[0].name);
    try std.testing.expectEqual(@as(u32, 8), h.low.out.mem_arrays.items[0].len);
    var n: [3]u32 = @splat(0); // anew, load, store
    for (h.mir.insts.items(.op)) |op| switch (op) {
        .anew => n[0] += 1,
        .fload => n[1] += 1,
        .store => n[2] += 1,
        else => {}, // else: only the array ops are counted
    };
    // One declaration; `h[k]` and `h[3]` read; the loop body and `h[k] =` write.
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 2 }, &n);
}

test "lower: §5.4.3 port access — what is rejected, and what the unknown is" {
    const cases = [_]struct { src: []const u8, want: diag.Code, msg: []const u8 = "" }{
        // "The expression V(<a>) is invalid for ports and nets, where V is a
        // potential access function."
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog I(p) <+ V(<p>);
        \\endmodule
        , .want = .E0507, .msg = "potential access function" },
        // "The port access function shall not be used on the left side of a
        // contribution operator <+."
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog I(<p>) <+ 1.0;
        \\endmodule
        , .want = .E0407 },
        // §4.4.2 "the expression list is a single port of the module": an
        // internal net has no outside, so I(<n>) would be an identical zero.
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  electrical n;
        \\  analog I(p, n) <+ I(<n>);
        \\endmodule
        , .want = .E0508, .msg = "I(<n>)" },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try h.init(std.testing.allocator, c.src);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        try std.testing.expectEqual(c.want, h.bag.at(0).code);
        if (c.msg.len != 0)
            try std.testing.expect(std.mem.find(u8, h.bag.at(0).message, c.msg) != null);
    }
}

test "lower: §5.4.3 repeated I(<p>) is one unknown, appended after the ports" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(a, c);
        \\  inout a, c; electrical a, c;
        \\  analog I(a, c) <+ I(<a>) + I(<c>) + I(<a>);
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();

    try std.testing.expectEqual(@as(u32, 2), h.low.out.num_ports);
    try std.testing.expectEqual(@as(usize, 2), h.low.out.port_probes.items.len);
    // Deduped by port, in first-probe order, and never inside `num_ports`.
    try std.testing.expectEqual(@as(u32, 0), @backingInt(h.low.out.port_probes.items[0].port));
    try std.testing.expectEqual(@as(u32, 1), @backingInt(h.low.out.port_probes.items[1].port));
    for (h.low.out.port_probes.items) |pp| {
        try std.testing.expect(@backingInt(pp.u) >= h.low.out.num_ports);
        // The kind tag, which codegen's `isFlowUnknown` reads. Not the
        // `"flow(<"` spelling: §2.8.1 lets a net be declared `\flow(<p>)`.
        // The spelling the host sees is pinned by codegen.zig's "the `U` block
        // is the SPELLING contract" test.
        try std.testing.expectEqual(pp.port, h.low.out.nodes.items(.kind)[@backingInt(pp.u)].port_flow);
    }
    try std.testing.expectEqualStrings("flow(<a>)", Lower.nodeName(&h.low, h.low.out.port_probes.items[0].u));
}

test "lower: §5.6.1.3 a kind mismatch REPLACES the retained value, and §5.4.2.2 reads it" {
    var h: Harness = undefined;
    // §5.6.1.3's own worked example, whose stated answer is 7.0 and whose whole
    // point is that 8.0 (every potential contribution accumulated, both
    // conversions ignored) is wrong.
    try h.init(std.testing.allocator,
        \\module vr(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    V(p,n) <+ 1.0;
        \\    I(p,n) <+ 2.0;
        \\    V(p,n) <+ 3.0;
        \\    V(p,n) <+ 4.0;
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();

    // Two entries — the pair received both kinds — but only ONE survives with a
    // value. `dispatch.emitStamps` skips a contribution whose value folds to `.f_zero`,
    // so the discarded flow source of 2.0 emits no row at all, which is what
    // "the flow being discarded" has to mean in the device.
    try std.testing.expectEqual(@as(usize, 2), h.low.out.contributions.items.len);
    for (h.low.out.contributions.items) |c| {
        switch (c.access) {
            .flow => try std.testing.expectEqual(Mir.Value.f_zero, c.resist_val),
            .potential => try std.testing.expect(c.resist_val != .f_zero),
        }
        try std.testing.expectEqual(Mir.Value.f_zero, c.react_val);
    }

    // §5.4.2.2 the read side: a flow read AFTER a flow contribution is the
    // retained value, so it mints no `flow(p,n)` unknown; before one — or on a
    // POTENTIAL source, whose branch current codegen does pin — it still does.
    //
    // This asserts whether an unknown exists, read off the kind tag (the node
    // pair keyed in `flow_unknowns`). The spelling is pinned by codegen.zig's
    // "the `U` block is the SPELLING contract" test.
    const cases = [_]struct { src: []const u8, unknown: bool }{
        .{ .src = "I(p,n) <+ 1.0; x = I(p,n);", .unknown = false },
        .{ .src = "x = I(p,n); I(p,n) <+ 1.0;", .unknown = true },
        .{ .src = "V(p,n) <+ 1.0; x = I(p,n);", .unknown = true },
    };
    for (cases) |c| {
        var g: Harness = undefined;
        const src = try std.testing.allocator.print(
            \\module fr(p, n);
            \\  inout p, n; electrical p, n;
            \\  real x;
            \\  analog begin {s} end
            \\endmodule
        , .{c.src});
        defer std.testing.allocator.free(src);
        try g.init(std.testing.allocator, src);
        defer g.deinit();
        _ = try g.low.lowerFile();
        // `p` and `n` are `nodes` rows 0 and 1, so the branch is that pair.
        try std.testing.expectEqual(c.unknown, g.low.out.flow_unknowns.contains(.{ .hi = @fromBackingInt(0), .lo = @fromBackingInt(1) }));
    }
}

test "lower: scan destinations are guarded by the single assignment count" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module scan(p, n);
        \\  inout p, n; electrical p, n;
        \\  integer fd, count, iv; real rv; string sv;
        \\  analog begin
        \\    iv = 73; rv = 2.5; sv = "kept";
        \\    count = $sscanf("12 nope", "%d %f", iv, rv, sv);
        \\    count = $fscanf(fd, "%d %f", iv, rv, sv);
        \\    I(p,n) <+ iv + rv + count;
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());
    var string_counts: usize = 0;
    var file_counts: usize = 0;
    var guarded: usize = 0;
    for (0..h.mir.blockCount()) |bi| {
        const b: Mir.Block = @fromBackingInt(@intCast(bi));
        var it = h.mir.blockInsts(b);
        while (it.next()) |inst| {
            if (h.mir.instOp(inst) == .call) {
                const name = h.mir.instData(inst).call.name;
                if (std.mem.eql(u8, name, "$sscanf")) string_counts += 1;
                if (std.mem.eql(u8, name, "$fscanf")) file_counts += 1;
            }
            if (h.mir.instOp(inst) != .select) continue;
            const selection = h.mir.instData(inst).ternary;
            const condition = h.mir.resolveAlias(selection.cond);
            const comparison = h.mir.valueDef(condition).inst_result;
            try std.testing.expectEqual(Mir.Opcode.igt, h.mir.instOp(comparison));
            const lhs = h.mir.resolveAlias(h.mir.instData(comparison).binary.lhs);
            const count_inst = h.mir.valueDef(lhs).inst_result;
            try std.testing.expectEqual(Mir.Opcode.call, h.mir.instOp(count_inst));
            const name = h.mir.instData(count_inst).call.name;
            try std.testing.expect(std.mem.eql(u8, name, "$sscanf") or std.mem.eql(u8, name, "$fscanf"));
            guarded += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), string_counts);
    try std.testing.expectEqual(@as(usize, 1), file_counts);
    try std.testing.expectEqual(@as(usize, 6), guarded);
}

test "lower: A.6.4 the analog_statement / analog_event_statement split" {
    // §5.10 "Contribution statements cannot be used inside an event control
    // block"; A.6.4 `analog_event_statement` has no contribution alternative.
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module e(p, c);
        \\  inout p, c; electrical p, c;
        \\  analog @(cross(V(c), +1)) I(p) <+ V(p);
        \\endmodule
    );
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h.bag.count());
    try std.testing.expectEqual(diag.Code.E0406, h.bag.at(0).code);

    // `disable` is the mirror image: absent from `analog_statement`, present in
    // `analog_event_statement`. There is no §5.11 entry for it (5.11 is
    // jump_statement), so the diagnostic must not claim one.
    var h2: Harness = undefined;
    try h2.init(std.testing.allocator,
        \\module d(p);
        \\  inout p; electrical p;
        \\  analog begin : work
        \\    if (V(p) > 1.0) disable work;
        \\    I(p) <+ V(p);
        \\  end
        \\endmodule
    );
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h2.bag.count());
    try std.testing.expectEqual(diag.Code.E0401, h2.bag.at(0).code);
    // A.6.4, never §5.11 (which is jump_statement) — the citation is the code's.
    try std.testing.expectEqualStrings("A.6.4", diag.info(.E0401).lrm);
}

test "lower: §5.10.4 a named event resolves; anything else at `@`/`->` is E0705" {
    // The accepting side is three fixtures (annex_a/17, ch05/named_event_*,
    // annex_c/19), which pin the NUMBER end to end. What no fixture reaches is
    // the resolution failure, and it has to be a failure in both positions:
    // §2.8 gives an event a name and no value, so a real variable is not an
    // event even though `@(v)` would type-check as an integer guard.
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module ev(p);
        \\  inout p; electrical p; real v; event tick;
        \\  analog begin
        \\    @(initial_step) -> tick;
        \\    @(tick) v = 1.0;
        \\    @(v) v = 2.0;
        \\    I(p) <+ v;
        \\  end
        \\endmodule
    );
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h.bag.count());
    try std.testing.expectEqual(diag.Code.E0705, h.bag.at(0).code);
    try std.testing.expectEqualStrings("`v`", h.bag.at(0).message);

    // The trigger goes through the same table, so a misspelling there lands on
    // the same code rather than silently triggering nothing.
    var h2: Harness = undefined;
    try h2.init(std.testing.allocator,
        \\module ev2(p);
        \\  inout p; electrical p; event tick;
        \\  analog begin
        \\    @(initial_step) -> tock;
        \\    I(p) <+ V(p);
        \\  end
        \\endmodule
    );
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0705, h2.bag.at(0).code);
    try std.testing.expectEqualStrings("`tock`", h2.bag.at(0).message);
}

test "lower: §5.10.3.4 absdelta bounds do not freeze card defaults" {
    // A host can replace every default below with valid values. Unlike a
    // literal negative bound, these analog_expression operands cannot be
    // refused from their declarations alone. This is the compile-time half;
    // event_bounds_mixed_legal.va runs legal runtime operands through the
    // emitted mixed-signal host.
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module ad(p);
        \\  inout p; electrical p;
        \\  parameter real delta = -1.0, ttol = -1.0, etol = -1.0, en = 0.5;
        \\  real sampled;
        \\  always @(absdelta(V(p), delta, ttol, etol, en)) sampled = V(p);
        \\  analog I(p) <+ 0.0;
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(!h.bag.failed());
}

test "lower: an unknown name carries a `did you mean` help" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  real vds;
        \\  analog I(p) <+ vdss * V(p);
        \\endmodule
    );
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0314, h.bag.at(0).code);
    try std.testing.expectEqualStrings("`vdss`", h.bag.at(0).message);
    var nbuf: [diag.max_children]diag.Note = undefined;
    const notes = h.bag.notes(h.bag.at(0), &nbuf);
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    try std.testing.expectEqualStrings("did you mean `vds`?", notes[0].text);
}

test "lower: §3.3 Table 3-3 string concatenation folds; the integer form never reaches here" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p;
        \\  electrical p;
        \\  string a = "hello", b = "world", c;
        \\  analog begin
        \\    c = {a, " ", b};
        \\    I(p) <+ 0.0 * V(p);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());

    // The LRM's own example: `{ "hello", " ", "world" }` == `"hello world"`.
    var found = false;
    for (h.mir.strings.texts.items) |s| {
        if (std.mem.eql(u8, s, "hello world")) found = true;
    }
    try std.testing.expect(found);

    // A non-string operand has no width here (the parser folds the sized-
    // constant form), so it is rejected rather than silently coerced.
    var h2: Harness = undefined;
    try h2.init(std.testing.allocator,
        \\module m; integer a, b; analog a = {b, b}; endmodule
    );
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0327, h2.bag.at(0).code);
    try std.testing.expect(std.mem.find(u8, h2.bag.at(0).message, "only sized constants") != null);
}

test "lower: §3.2 a variable some path reads before writing is held, and only that" {
    // §5.6.1.3 "Unlike variables, the contributed value for a branch is only
    // valid for the current iteration": a variable keeps its value, which a
    // read is able to see only where no write of this evaluation precedes it.
    const W = Lower.HeldVar.Why;
    const cases = [_]struct { body: []const u8, held: usize, why: W = .unless_invariant }{
        .{ .body = "x = 2.0; I(p) <+ x;", .held = 0 },
        .{ .body = "if (V(p) > 0) x = 1.0; else x = 2.0; I(p) <+ x;", .held = 0 },
        .{ .body = "if (V(p) > 0) x = 1.0; I(p) <+ x;", .held = 1 }, // the else path
        .{ .body = "x = x + 1.0; I(p) <+ x;", .held = 1, .why = .retained }, // the read reaches the write
        .{ .body = "I(p) <+ x; x = V(p);", .held = 1, .why = .retained },
        .{ .body = "if (V(p) > 0) I(p) <+ x; else x = 1.0;", .held = 1 }, // the arms exclude each other
        .{ .body = "for (k = 0; k < 2; k = k + 1) begin $strobe(\"%g\", x); x = 1.0; end", .held = 1, .why = .retained }, // the next iteration
        .{ .body = "a[0] = 1.0; a[1] = 2.0; I(p) <+ a[0] + a[1];", .held = 0 },
        .{ .body = "a[0] = 1.0; I(p) <+ a[1];", .held = 2 }, // every element of the array
        .{ .body = "I(p) <+ x;", .held = 0 }, // never written: nothing to retain
        .{ .body = "@(cross(V(p), 1)) x = 1.0; I(p) <+ x;", .held = 1, .why = .event },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p);
            \\  inout p;
            \\  electrical p;
            \\  real x, y, a[0:1];
            \\  integer k;
            \\  analog begin
            \\    {s}
            \\  end
            \\endmodule
        , .{c.body});
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        const out = try h.low.lowerFile();
        errdefer std.debug.print("body: {s}\n", .{c.body});
        try std.testing.expectEqual(c.held, out.held_vars.items.len);
        for (out.held_vars.items) |v| try std.testing.expectEqual(c.why, v.why);
    }
}

test "lower: A.6.2 an initial block of constant assignments lowers; its refusals name their own clause" {
    // The accepting side is six fixtures (ch07/digital_initial_accepted,
    // discrete_bus_narrow, discrete_bus_31, discrete_real_from_analog,
    // annex_c/13, ch08/analog_digital_initial_order), which pin the VALUE end to
    // end. Every body that is not the constant shape (a non-constant
    // right-hand side, a loop, an array element, a system task) is a process
    // and makes the module mixed (`lower_context.isMixed`'s test, #57), so it
    // runs on the kernel rather than being refused. What stays refused here is
    // stated below, each under its own rule.
    const cases = [_]struct { stmt: []const u8, code: diag.Code }{
        // §5.10 event control: the block suspends, so it is a PROCESS and the
        // module is mixed; what it suspends on is `initial_step`, which §5.10
        // does not allow "in the digital context".
        .{ .stmt = "@(initial_step) q = 1;", .code = .E0708 },
        // §6.8 a name this module never declares. Nothing else lowers the block,
        // so if this scan does not report it, nobody does.
        .{ .stmt = "nope = 1;", .code = .E0313 },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p);
            \\  inout p; electrical p;
            \\  integer q; real v; integer arr[0:3];
            \\  initial begin {s} end
            \\  analog begin v = V(p); I(p) <+ v + q; end
            \\endmodule
        , .{c.stmt});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.bag.at(i).code == c.code) seen = true;
        }
        std.testing.expect(seen) catch |e| {
            std.debug.print("initial statement: {s}\n", .{c.stmt});
            return e;
        };
    }

    // The accepting shape, at the seam that matters: the constant reaches the
    // variable's INITIAL VALUE, which is where an A.2.2.1 declaration assignment
    // lands, and a parameter counts as a constant (§3.4).
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  parameter real k = 2.5;
        \\  integer q; real r;
        \\  initial begin q = 3; r = k; q = 4; end
        \\  analog I(p) <+ V(p) + q + r;
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 0), h.bag.count());
    // Last assignment wins: the body is sequential.
    try std.testing.expectEqual(@as(usize, 2), h.low.initial_state.count());
}

test "lower: a 60000-statement dependency chain lowers without exhausting the stack" {
    // An adversarial-size run: `scanFinite` recursed along the whole
    // chain and overflowed the native stack at 2e4 chained statements.
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "module m(p);\ninout p; electrical p;\nreal x;\nanalog begin\nx = 0.0;\n");
    for (0..60000) |_| try src.appendSlice(gpa, "x = x + 1.0;\n");
    try src.appendSlice(gpa, "I(p) <+ x;\nend\nendmodule\n");
    var h: Harness = undefined;
    try h.init(gpa, src.items);
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 0), h.bag.count());
}

test "A.8.2 an omitted system-function argument with no meaning is a named error, never a crash" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { call: []const u8, bad: bool }{
        .{ .call = "$limit(V(p), \"pnjlim\", 0.025, 0.6)", .bad = false },
        .{ .call = "$limit(V(p), , 0.025, 0.6)", .bad = true },
        .{ .call = "$table_model(V(p), , \"1LL\")", .bad = true },
        .{ .call = "$hypot(V(p), )", .bad = true },
    };
    for (cases) |c| {
        const src = try gpa.print(
            \\module m(p);
            \\inout p; electrical p;
            \\analog I(p) <+ {s};
            \\endmodule
        , .{c.call});
        defer gpa.free(src);
        var h: Harness = undefined;
        try h.init(gpa, src);
        defer h.deinit();
        _ = h.low.lowerFile() catch |err| switch (err) {
            error.DiagnosticsReported => {},
            else => |e| return e,
        };
        var errors: usize = 0;
        var e0894 = false;
        for (0..h.bag.count()) |i| if (h.bag.at(i).severity == .err) {
            errors += 1;
            e0894 = e0894 or h.bag.at(i).code == .E0894;
        };
        if (errors != @intFromBool(c.bad) or e0894 != c.bad) {
            for (0..h.bag.count()) |i| std.debug.print("{s}: {s} {s}\n", .{ c.call, @tagName(h.bag.at(i).code), h.bag.at(i).message });
            return error.TestUnexpectedResult;
        }
    }
}

test "A.8.1 an empty pattern element is E0894 except in §3.6.3.2's bus nodeset; A.8.2 noise functions take no empty slot" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { src: []const u8, code: ?diag.Code }{
        .{ .src = "parameter real a[0:2] = '{1.0, , 3.0};\nanalog I(p) <+ a[1] * V(p);", .code = .E0894 },
        .{ .src = "parameter real a[0:2] = '{1.0, 2.0, 3.0};\nanalog I(p) <+ a[1] * V(p);", .code = null },
        .{ .src = "real a[0:2];\nanalog begin a = '{1.0, , 3.0}; I(p) <+ a[1] * V(p); end", .code = .E0894 },
        .{ .src = "analog I(p) <+ white_noise(1e-20, , \"x\");", .code = .E0505 },
        .{ .src = "analog I(p) <+ white_noise(1e-20, \"x\");", .code = null },
    };
    for (cases) |c| {
        const src = try gpa.print(
            \\module m(p);
            \\inout p; electrical p;
            \\{s}
            \\endmodule
        , .{c.src});
        defer gpa.free(src);
        var h: Harness = undefined;
        try h.init(gpa, src);
        defer h.deinit();
        _ = h.low.lowerFile() catch |err| switch (err) {
            error.DiagnosticsReported => {},
            else => |e| return e,
        };
        var first: ?diag.Code = null;
        for (0..h.bag.count()) |i| if (h.bag.at(i).severity == .err) {
            first = h.bag.at(i).code;
            break;
        };
        try std.testing.expectEqual(c.code, first);
    }
}

test "§9.17.3 a limiter's formals are all input, and the simulator supplies two" {
    // "The arguments of the user-defined function shall all be declared input."
    try Lower.expectVerdict(
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog function real lim;
        \\    input vnew; output vold;
        \\    real vnew, vold;
        \\    lim = vnew;
        \\  endfunction
        \\  analog I(p) <+ 1m * $limit(V(p), lim);
        \\endmodule
    , .E0814);
    // vnew and vold come from the simulator; a third formal has no actual.
    try Lower.expectVerdict(
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog function real lim;
        \\    input vnew, vold, k;
        \\    real vnew, vold, k;
        \\    lim = k * vnew;
        \\  endfunction
        \\  analog I(p) <+ 1m * $limit(V(p), lim);
        \\endmodule
    , .E0511);
}

/// Lowers `body` inside `expectBodies`' module and returns the first error's
/// code, or null when it lowered clean.
fn bodyVerdict(body: []const u8) !?diag.Code {
    const gpa = std.testing.allocator;
    const src = try gpa.print(
        \\module m(p, q);
        \\  inout p, q; electrical p, q;
        \\  real x;
        \\{s}
        \\endmodule
    , .{body});
    defer gpa.free(src);
    var h: Lower.Harness = undefined;
    try h.init(gpa, src);
    defer h.deinit();
    if (try h.lower() != null) return null;
    for (0..h.bag.count()) |i| if (h.bag.at(i).severity == .err) return h.bag.at(i).code;
    return error.TestUnexpectedResult; // `lower` failed with no error reported
}

test "A.8.2 an analog operator's omitted argument is a verdict, and one past its longest list an error" {
    // Oracle: Syntax 4-3 and 4-4 fix each operator's longest list, so one
    // argument more is an error, and the longest list itself lowers clean.
    // An omitted slot is its clause's to judge (§4.5.14 defaults some), so
    // any verdict passes there, but a verdict: the slot is source text.
    const longest = [_][]const u8{
        "ddt(V(p), 1u)",                                  "ddx(V(p), V(q))",
        "idt(V(p), 0.0, 0, 1u)",                          "idtmod(V(p), 0.0, 1.0, 0.0, 1u)",
        "absdelay(V(p), 1n, 2n)",                         "transition(x, 0, 1n, 1n, 1p)",
        "slew(V(p), 1e9, -1e9)",                          "laplace_nd(V(p), '{1.0}, '{1.0, 1.0}, 1u)",
        "zi_nd(V(p), '{1.0}, '{1.0}, 1n, 1p, 0)",         "limexp(V(p))",
        "white_noise(1e-20, \"th\")",                     "flicker_noise(1e-20, 1.0, \"fl\")",
        "noise_table('{1.0, 1e-20, 2.0, 1e-20}, \"nt\")", "ac_stim(\"ac\", 1.0, 0.0)",
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (longest) |call| {
        const open = std.mem.findScalar(u8, call, '(').?;
        const args = call[open + 1 .. call.len - 1];
        try expectBodyCode(try arena.print("analog I(p) <+ {s};", .{call}), null);
        try std.testing.expect(try bodyVerdict(try arena.print("analog I(p) <+ {s}, 1.0);", .{call[0 .. call.len - 1]})) != null);
        // Each slot in turn left empty, its commas kept.
        var depth: u32 = 0;
        var start: usize = 0;
        for (args, 0..) |c, i| {
            switch (c) {
                '(', '{' => depth += 1,
                ')', '}' => depth -= 1,
                else => {},
            }
            if (i + 1 != args.len and (c != ',' or depth != 0)) continue;
            const end = if (c == ',') i else args.len;
            _ = try bodyVerdict(try arena.print("analog I(p) <+ {s}({s}{s});", .{ call[0..open], args[0..start], args[end..] }));
            start = i + 1;
        }
    }
    // §5.6.7.2's indirect form reads its operator's first slot for a probe.
    for ([_][]const u8{ "ddt(, 1u)", "idt(, 0.0)", "idtmod(, 0.0, 1.0)" }) |op|
        _ = try bodyVerdict(try arena.print("analog V(p) : {s} == V(q);", .{op}));
    // The clauses that do judge an omitted slot.
    try expectBodyCode("analog I(p) <+ ddt(V(p), );", .E0505);
    try expectBodyCode("analog I(p) <+ ddx(V(p), );", .E0504);
    try expectBodyCode("analog I(p) <+ $simprobe(, \"g\");", .E0894);
}

fn expectBodyCode(body: []const u8, want: ?diag.Code) !void {
    const got = try bodyVerdict(body);
    if (got != want) std.debug.print("`{s}`: got {?t}, want {?t}\n", .{ body, got, want });
    try std.testing.expectEqual(want, got);
}

test "§3.12 a named branch whose two ends are one node lowers: a short, not a V(n, n)" {
    // Oracle: §4.4's "they shall not evaluate to the same signal" constrains
    // the two net expressions of an access, and `I(br)` has one; §3.12
    // puts no rule on a branch's terminals being the same net.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for ([_][]const u8{
        "analog begin I(br) <+ V(q); I(q) <+ I(br); end",
        "analog I(br) <+ V(q);",
        "analog I(q) <+ I(br);",
        "analog begin I(br) <+ ddt(V(q) * 1p); I(q) <+ I(br); end",
        "analog V(br) <+ 0.0;",
    }) |b| try expectBodyCode(try arena_state.allocator().print("branch (p, p) br;\n{s}", .{b}), null);
}

test "§4.4 one net named twice in an access is E0315; two ports a parent shorts are two nets" {
    // Oracle: §4.4's "they shall not evaluate to the same signal", read on
    // the module as written. A module is legal or not by its own text, so
    // an instance connecting two ports to one net (`res r1(a, a)`, a SPICE
    // `R1 a a`) cannot make it illegal; Table 4-16's `I(n1, n1)` can.
    const res = "module res(p, n); inout p, n; electrical p, n; {s} endmodule\nmodule top(a); inout a; electrical a; res r1(a, a); endmodule\n";
    for ([_]Lower.Case{
        .{ .src = "analog I(p, n) <+ V(p, n) / 1k;", .code = null },
        .{ .src = "branch (p, n) b; analog I(b) <+ V(b) / 1k;", .code = null },
        .{ .src = "analog I(p, p) <+ V(p, n) / 1k;", .code = .E0315 },
    }) |c| {
        const src = try std.testing.allocator.print(res, .{c.src});
        defer std.testing.allocator.free(src);
        try Lower.expectVerdict(src, c.code);
    }
    // §1.3.1.1 collapses every ground net onto one node: two of them are
    // two signals.
    try expectBodyCode("ground g1, g2; analog I(p) <+ V(g1, g2);", null);
}

test "IEEE 1364-2005 §4.11 a genvar shares the module name space with parameters, variables and nets (E0362)" {
    for ([_]Lower.Case{
        .{ .src = "genvar i; real i; analog I(p) <+ V(p);", .code = .E0362 },
        .{ .src = "genvar i; parameter real i = 1.0; analog I(p) <+ V(p);", .code = .E0362 },
        .{ .src = "genvar i; electrical i; analog I(p) <+ V(p);", .code = .E0362 },
        .{ .src = "genvar k; real i; analog I(p) <+ V(p);", .code = null },
    }) |c| try expectBodyCode(c.src, c.code);
}

test "a call with more operands than its 24-bit count holds is E1021, and one with fewer lowers" {
    // Oracle: `Mir.call_args_max`, the row's count field; a pattern
    // argument is one operand per element (A.8.1 replication included).
    try expectBodyCode("analog I(p) <+ laplace_nd(V(p), '{16777216{1.0}}, '{1.0});", .E1021);
    try expectBodyCode("analog I(p) <+ laplace_nd(V(p), '{4{1.0}}, '{1.0});", null);
}
