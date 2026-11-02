//! Parser self-checks: the real lexer drives the real parser.
//!
//! Source in, `Ast` and diagnostics out, asserted per Annex A production.
//! Oracles: the value or diagnostic the cited clause states (each refusal
//! beside a legal neighbour), and, over seeded token-level mutations of a
//! corpus, the parser's own contract (`checkParserContract`).
//!
//! LRM clauses cited: §1, §2.6.1, §2.6.2, §2.7, §2.8.1, §2.9, §3.2.1, §3.3,
//! §3.4.1, §3.4.2, §3.4.7, §3.6.3.2, §3.8, §3.12, §4.2.1.1, §4.2.2, §4.2.13,
//! §4.2.14, §4.4, §4.4.1, §4.5.11, §4.7.1, §5.4.3, §5.6.8.2, §6.2, §6.2.2,
//! §6.3.1, §6.4.1, §6.4.3, §6.5.1, §6.5.2, §6.6, §6.6.2, §6.6.3, §6.7, §7.8,
//! §7.8.3, §9.18, §9.22, §10.6; IEEE 1364-2005 §3.7.3, §4.3.2, §4.4, §4.10.1,
//! §6.1.4, §7.14, §8.1.4, §8.8, §9.3, §12.3.3, §12.5, §13.3.1, §14.1, §14.2,
//! §14.3, §15.1, §15.3.4.

const std = @import("std");
const frontend = @import("frontend");
const parser = frontend.Parser;
const token = frontend.token;
const keyword = frontend.keyword;
const lexer = frontend.lexer;
const Ast = frontend.Ast;
const diag = @import("diag");
const Parser = parser.Parser;
const deep_stack = @import("base").deep_stack;
const TestResult = parser.TestResult;
const newBag = parser.newBag;
const parseForTest = parser.parseForTest;

test "§2.6.2 scaled literals are refused in every digital delay production before folding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct {
        fn parse(a: std.mem.Allocator, src: []const u8, digital: bool) !TestResult {
            var list = try lexer.tokenize(a, src, null);
            const bag = try newBag(a, src);
            var p = Parser.init(a, src, list.items(.tag), list.items(.start), bag);
            p.digital = digital;
            const file = p.parseSourceFile() catch |e| switch (e) {
                error.ParseError => p.file,
                else => return e,
            };
            try std.testing.expect(!p.in_digital_delay);
            return .{ .file = file, .bag = bag };
        }

        fn rejected(a: std.mem.Allocator, src: []const u8, digital: bool) !void {
            const r = try parse(a, src, digital);
            var errors: usize = 0;
            for (0..r.count()) |i| if (diag.severityOf(r.code(i)) == .err) {
                try std.testing.expectEqual(diag.Code.E0247, r.code(i));
                errors += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), errors);
        }
    };
    const invalid = [_][]const u8{
        "module m; initial #5u; endmodule",
        "module m; reg q; initial q = #(1 + 2u) 1; endmodule",
        "module m; reg q; initial q <= #1m 1; endmodule",
        "module m; initial #(0 ? 3u : 1); endmodule",
        "module m; wire #(1u, 2, 3) q; endmodule",
        "module m; wire q; assign #(1, 2u) q = 1; endmodule",
        "module m; wire q; buf #(1, 2u) g(q, 1); endmodule",
        "module m; wire q; nmos #(1, 2u, 3) g(q, 1, 1); endmodule",
        "primitive p(q,a); output q; input a; table 0:0; 1:1; endtable endprimitive module m; wire q; p #2u g(q,1); endmodule",
        "module m(input a, output y); buf g(y,a); specify (a => y) = 1u; endspecify endmodule",
        // The body and following declaration are outside the delay context.
        "module m; initial #5u $display(1m); parameter real g = 2m; endmodule",
    };
    for ([_]bool{ false, true }) |digital| {
        for (invalid) |src| try Case.rejected(arena, src, digital);
        for ("TGMKkmunpfa") |suffix| {
            const src = try arena.print("module m; initial #1.25{c}; endmodule", .{suffix});
            try Case.rejected(arena, src, digital);
        }
        const legal = try Case.parse(arena,
            \\module m;
            \\parameter real delay_units = 0.25;
            \\wire #0.5 w; reg q;
            \\assign #2.5e-1 w = q;
            \\buf #(0.5, 2.5e-1) g(w,q);
            \\child #(.g(1m)) u();
            \\function real f; input real t; f=t; endfunction
            \\initial begin
            \\  #delay_units q = #0.5 1;
            \\  q <= #2.5e-1 0;
            \\  #(f (* metadata = 1u *) (2.5e-1)) $display(1m);
            \\end
            \\endmodule
        , digital);
        // The analog-only parse warns for the primitive's missing executor;
        // neither parse may refuse any legal delay or ordinary scaled value.
        try std.testing.expectEqual(@as(usize, if (digital) 0 else 1), legal.count());
        if (!digital) try std.testing.expectEqual(diag.Code.W0252, legal.code(0));

        // Resolving child to a UDP is elaboration's job. Retain lexical
        // evidence from a discarded operand, but not from call metadata.
        const ambiguous = try Case.parse(
            arena,
            "module m; child #(0 ? 1u : 0.25, f (* metadata=1u *) (0.5)) u(); endmodule",
            digital,
        );
        try std.testing.expectEqual(@as(usize, 0), ambiguous.count());
        const overrides = ambiguous.file.modules[0].instances[0].params;
        try std.testing.expect(overrides[0].scaled_literal_tok != null);
        try std.testing.expect(overrides[1].scaled_literal_tok == null);
    }
    // Typical-value selection must not hide a scaled min/max operand.
    try Case.rejected(arena, "module m; wire #(1u:2:3) q; endmodule", true);
    try Case.rejected(arena, "module m; wire #(1:2:3u) q; endmodule", true);
}

test "escaped identifier expressions share declaration normalization" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = [_][]const u8{
        "a.b",                                                                                              "a..b", ".", "a/b", "a\\b", "a`b", "abc", "module",
        "!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~",
    };
    for (names) |name| {
        const src = try arena.print(
            "module m; integer \\{s} ; initial begin \\{s} = 9; $display(\"%0d\", \\{s} ); end endmodule",
            .{ name, name, name },
        );
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(usize, 0), res.count());
        const declared = res.file.modules[0].vars[0].name;
        var references: usize = 0;
        for (res.file.exprs.nodes.items(.tag), res.file.exprs.nodes.items(.str)) |tag, str| {
            if (tag == .ident) {
                try std.testing.expectEqual(declared, str);
                references += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), references);
    }
}

test "escaped nature access shares expression normalization" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try parseForTest(
        arena,
        "nature n; access = \\a.b ; endnature module m(p); inout p; electrical p; analog \\a.b (p) <+ 0; endmodule",
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());
    const body = res.file.stmt(res.file.modules[0].analog[0].body);
    const lhs = switch (body) {
        .contribute => |c| c.lhs,
        else => return error.WrongTag,
    };
    try std.testing.expectEqual(Ast.ExprTag.branch_access, res.file.exprs.tag(lhs));
}

test "escaped hierarchy head shares instance normalization" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try parseForTest(
        arena,
        "module m; child \\a.b (); integer z; initial z = \\a.b .c; endmodule",
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());
    const declared = res.file.modules[0].instances[0].name;
    var references: usize = 0;
    for (res.file.exprs.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .hier_ident) {
            const parts = res.file.exprs.nameParts(@fromBackingInt(@intCast(i)));
            try std.testing.expectEqual(@as(usize, 2), parts.len);
            try std.testing.expectEqual(declared, parts[0]);
            references += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), references);
}

test "§10.6 begin_keywords picks which annex B words are reserved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // LRM §10.6 worked example: `sin` is a port name under 1364-2005. The
    // body still uses `analog`, a VAMS-only keyword, because §10.6 changes
    // what is reserved, not how it lexes.
    const ok =
        \\`begin_keywords "1364-2005"
        \\module m2(sin, n);
        \\  inout sin, n;
        \\  electrical sin, n;
        \\  analog I(sin,n) <+ V(sin,n) + sin;
        \\endmodule
        \\`end_keywords
    ;
    const a = try parseForTest(arena, ok);
    try std.testing.expectEqual(@as(usize, 0), a.count());
    try std.testing.expectEqualStrings("sin", a.file.str(a.file.modules[0].ports[0].name));

    // Same code, VAMS keywords: "shall result in an error".
    const bad =
        \\`begin_keywords "VAMS-2023"
        \\module m2(sin, n);
        \\  inout sin, n;
        \\endmodule
        \\`end_keywords
    ;
    const b = try parseForTest(arena, bad);
    try std.testing.expect(b.count() > 0);
    try std.testing.expectEqual(diag.Code.E0208, b.code(0));
    try std.testing.expectEqualStrings("found `sin`", b.msg(0));

    // The set is restored by `end_keywords, so `sin` is reserved again after.
    const c = try parseForTest(arena,
        \\`begin_keywords "1364-1995"
        \\`end_keywords
        \\module m(sin);
        \\endmodule
    );
    try std.testing.expect(c.count() > 0);

    // §10.6: only these five specifiers exist.
    const d = try parseForTest(arena, "`begin_keywords \"1800-2017\"\n`end_keywords\n");
    try std.testing.expectEqual(diag.Code.E0135, d.code(0));
    try std.testing.expectEqualStrings("`1800-2017`", d.msg(0));

    // Unbalanced. An open `begin_keywords at end of file is not an error:
    // §10.6 scopes the directive "even across source code file boundaries".
    const e = try parseForTest(arena, "`begin_keywords \"VAMS-2.3\"\nmodule m; endmodule\n");
    try std.testing.expectEqual(@as(usize, 0), e.count());
    // The other way round has no such reading.
    const f = try parseForTest(arena, "`end_keywords\n");
    try std.testing.expectEqual(diag.Code.E0136, f.code(0));

    // §10.6: "can only be specified outside of a design element".
    const g = try parseForTest(arena,
        \\module m;
        \\`begin_keywords "1364-2005"
        \\endmodule
        \\`end_keywords
    );
    try std.testing.expectEqual(diag.Code.E0202, g.code(0));
    try std.testing.expectEqualStrings("`begin_keywords inside a module", g.msg(0));
}

test "--std=1364-2005 frees AMS keywords as identifiers and refuses AMS constructs (E0242)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct {
        fn parse(a: std.mem.Allocator, src: []const u8, set: keyword.KeywordSet) !TestResult {
            var list = try lexer.tokenize(a, src, null);
            const bag = try newBag(a, src);
            var p = Parser.init(a, src, list.items(.tag), list.items(.start), bag);
            p.setLanguage(set);
            const file = p.parseSourceFile() catch |e| switch (e) {
                error.ParseError => p.file,
                else => return e,
            };
            return .{ .file = file, .bag = bag };
        }
    };
    const verilog = "module m; reg analog; wire sin; endmodule\n";
    try std.testing.expectEqual(@as(usize, 0), (try Case.parse(arena, verilog, .v1364_2005)).count());
    try std.testing.expectEqual(diag.Code.E0208, (try Case.parse(arena, verilog, .vams_2023)).code(0));
    // ... as module and instance names, and as a statement's target.
    const names = "module connect; endmodule\nmodule m; reg string; connect u(); initial begin string = 1; end endmodule\n";
    try std.testing.expectEqual(@as(usize, 0), (try Case.parse(arena, names, .v1364_2005)).count());
    // IEEE 1364-2005 §19.11: "1364-2001-noconfig" is no newer than 1364-2001.
    const noconfig = "`begin_keywords \"1364-2001-noconfig\"\nmodule m; reg config; endmodule\n`end_keywords\n";
    try std.testing.expectEqual(@as(usize, 0), (try Case.parse(arena, noconfig, .v1364_2001)).count());
    // Under the AMS default, a pre-2023 set frees `expm1`; a model's
    // own `expm1` frees it in any set, with W0259.
    const own = "module m; analog function real expm1; input x; real x; expm1 = exp(x) - 1.0; endfunction\nendmodule\n";
    const own_r = try Case.parse(arena, own, .vams_2023);
    try std.testing.expectEqual(@as(usize, 1), own_r.count());
    try std.testing.expectEqual(diag.Code.W0259, own_r.code(0));
    const own_old = "`begin_keywords \"VAMS-2.3\"\n" ++ own ++ "`end_keywords\n";
    try std.testing.expectEqual(@as(usize, 0), (try Case.parse(arena, own_old, .vams_2023)).count());

    // One error per construct, and the construct is still read past.
    const ams = try Case.parse(arena, "nature N; endnature\nmodule m; analog begin end\nreg r; endmodule\n", .v1364_2005);
    try std.testing.expectEqual(@as(usize, 2), ams.count());
    try std.testing.expectEqual(diag.Code.E0242, ams.code(0));
    try std.testing.expectEqualStrings("`nature` under \"1364-2005\"", ams.msg(0));
    try std.testing.expectEqual(diag.Code.E0242, ams.code(1));

    // A 1364 tool knows no Verilog-AMS keyword set.
    const spec = try Case.parse(arena, "`begin_keywords \"VAMS-2.3\"\n`end_keywords\n", .v1364_2005);
    try std.testing.expectEqual(diag.Code.E0135, spec.code(0));
}

test "--sim=verilogA refuses what annex C removes (E0250), and takes the rest of Verilog-AMS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct {
        fn parse(a: std.mem.Allocator, src: []const u8) !TestResult {
            var list = try lexer.tokenize(a, src, null);
            const bag = try newBag(a, src);
            var p = Parser.init(a, src, list.items(.tag), list.items(.start), bag);
            p.verilog_a = true;
            const file = p.parseSourceFile() catch |e| switch (e) {
                error.ParseError => p.file,
                else => return e,
            };
            return .{ .file = file, .bag = bag };
        }
    };
    // Annex C.2 through C.8: disciplined nets (`wire` with a discipline is
    // clause 3's, C.4), named branches and events, analog blocks and
    // functions, ranged parameters, instances. C.17: an unused discrete
    // discipline (annex D's `logic`) is silently ignored.
    const subset =
        \\discipline logic; domain discrete; enddiscipline
        \\nature Charge; abstol = 1e-14; access = Q; units = "C"; endnature
        \\discipline elec; domain continuous; potential Charge; enddiscipline
        \\module r(p, n); inout p, n; elec p, n; wire elec w; event e;
        \\  parameter real r = 1 from (0:inf); branch (p, n) b;
        \\  analog function real f; input x; real x; f = x; endfunction
        \\  analog begin @(initial_step) ; I(b) <+ V(b) / r; end
        \\endmodule
        \\module top; r u(); endmodule
        \\
    ;
    const legal = try Case.parse(arena, subset);
    for (0..legal.count()) |i| std.debug.print("unexpected {t}: {s}\n", .{ legal.code(i), legal.msg(i) });
    try std.testing.expectEqual(@as(usize, 0), legal.count());
    // One E0250 per construct, each named, in source order, and the
    // construct parsed past.
    const digital = try Case.parse(arena,
        \\discipline d; domain discrete; enddiscipline
        \\connectrules cr; endconnectrules
        \\module m(a); input a; elec a; reg q; wire w; wreal r; d x;
        \\  assign w = a; and g(w, a, a); task t; ; endtask
        \\  initial q = 1; always @(a) q = a;
        \\  analog begin if (a === 1) ; casex (a) 1: ; endcase end
        \\endmodule
        \\
    );
    // The W0252 an analog parse puts on a gate primitive is not the subset's.
    // C.4's `domain discrete` is the use `d x`, judged once the file is read.
    const want = [_][]const u8{ "connectrules", "reg", "wreal", "assign", "and", "task", "initial", "always", "===", "casex", "domain discrete" };
    var k: usize = 0;
    for (0..digital.count()) |i| {
        if (digital.code(i) != .E0250) continue;
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "`{s}` under --sim=verilogA", .{want[k]}), digital.msg(i));
        k += 1;
    }
    try std.testing.expectEqual(want.len, k);
}

test "§2.6.1 based literals decode to the right VALUE, not just to a token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module m;
        \\  integer a, b, c, d, e, f;
        \\  analog begin
        \\    a = 8'hFFFF;
        \\    b = 4'shf;
        \\    c = 'h837ff;
        \\    d = 16'b0011_0101;
        \\    e = 'shffffffff;
        \\    f = 'hffffffff;
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());

    const body = res.file.modules[0].analog[0].body;
    const stmts = switch (res.file.stmt(body)) {
        .block => |blk| blk.body,
        else => return error.WrongTag,
    };
    // The size truncates 8'hFFFF to 255, and the `s` designator makes 4'shf -1.
    // IEEE 1364-2005 §3.5.1: unsized is 32 bits, so 'shffffffff is -1 too,
    // and without the `s` it stays 2^32 - 1.
    const want = [_]i64{ 255, -1, 0x837ff, 0x35, -1, 0xffffffff };
    for (stmts, want) |s, expect| {
        const rhs = switch (res.file.stmt(s)) {
            .assign => |a2| a2.value,
            else => return error.WrongTag,
        };
        try std.testing.expectEqual(expect, res.file.exprs.intValue(rhs));
    }
}

test "§4.2.13 a sized-constant concatenation joins BITS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseForTest(arena,
        \\module m;
        \\  integer a, b, c;
        \\  analog begin
        \\    a = {4'b1010, 4'b0101};
        \\    b = {1'b1, 3'b101};
        \\    c = {4'shf, 4'b0001};
        \\  end
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());

    const stmts = switch (res.file.stmt(res.file.modules[0].analog[0].body)) {
        .block => |blk| blk.body,
        else => return error.WrongTag,
    };
    // 0xA5; §4.2.13's own example `{1'b1, 3'b101}` == 4'b1101; and a signed
    // operand contributes its bits (4'shf is -1, i.e. 1111), not its value.
    const want = [_]i32{ 165, 0b1101, 0xf1 };
    for (stmts, want) |s, expect| {
        const rhs = switch (res.file.stmt(s)) {
            .assign => |a| a.value,
            else => return error.WrongTag,
        };
        try std.testing.expectEqual(expect, res.file.exprs.intValue(rhs));
    }

    // "Unsized constant numbers shall not be allowed in concatenations."
    const unsized = try parseForTest(arena, "module m; integer a; analog a = {1'b1, 3}; endmodule");
    try std.testing.expectEqual(diag.Code.E0216, unsized.code(0));
    // §3.2.1: 33 bits does not fit an integer, and must not wrap silently.
    const wide = try parseForTest(arena, "module m; integer a; analog a = {16'h0, 16'h0, 1'b1}; endmodule");
    try std.testing.expectEqual(diag.Code.E0217, wide.code(0));
    try std.testing.expectEqualStrings("at least 33 bits wide", wide.msg(0));
    // A brace list with no sized operand stays a `.concat`. As a §4.5.11
    // filter coefficient it is lowering's refusal (E0572), not the parser's.
    const coeffs = try parseForTest(arena, "module m; real a; analog a = laplace_nd(1.0, {1,0}, {1,1}); endmodule");
    try std.testing.expectEqual(@as(usize, 0), coeffs.count());
}

test "§4.2.13 replication unrolls into the operand list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseForTest(arena,
        \\module m;
        \\  integer a, b, c;
        \\  analog begin
        \\    a = {4{2'b10}};
        \\    b = {1'b0, {3{1'b1, 1'b0}}};
        \\    c = {{0{1'b1}}, 4'b0101};
        \\  end
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());

    const stmts = switch (res.file.stmt(res.file.modules[0].analog[0].body)) {
        .block => |blk| blk.body,
        else => return error.WrongTag,
    };
    // 4.2.13's own three worked cases: "{4{w}} yields the same value as
    // {w, w, w, w}" (8 bits, 10101010); "{b, {3{a, b}}} yields the same value
    // as {b, a, b, a, b, a, b}" (7 bits, 0101010); and a zero replication
    // "considered to have a size of zero and ignored", leaving 4'b0101 alone.
    const want = [_]i32{ 170, 42, 5 };
    for (stmts, want) |s, expect| {
        const rhs = switch (res.file.stmt(s)) {
            .assign => |a| a.value,
            else => return error.WrongTag,
        };
        try std.testing.expectEqual(expect, res.file.exprs.intValue(rhs));
    }

    // §3.3 Table 3-3: "multiplier ... can be nonconstant" for a string result,
    // so a non-literal count is not a parse error; lowering repeats the string.
    const nonconst = try parseForTest(arena, "module m; integer i; string s; analog s = {i{\"Hi\"}}; endmodule");
    try std.testing.expectEqual(@as(usize, 0), nonconst.count());

    // A.8.1's assignment-pattern replication, §4.2.14's own `'{5{0.0}}`, is a
    // different brace with a different meaning: five elements, not five
    // copies of a bit pattern.
    const pat = try parseForTest(arena, "module m; parameter real d[0:4] = '{5{0.0}}; endmodule");
    try std.testing.expectEqual(@as(usize, 0), pat.count());
    try std.testing.expectEqual(@as(usize, 5), pat.file.exprs.args(pat.file.modules[0].params[0].default).len);
}

test "a resistor parses into ports, ranged parameters and a contribution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1k from (0:inf) exclude 0;
        \\  real g;
        \\  analog begin : body
        \\    g = 1.0 / r;
        \\    if (V(p, n) > 0.0) g = g * 2;
        \\    I(p, n) <+ g * V(p, n) + ddt(V(p, n)) - $temperature;
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 1), res.file.modules.len);

    const m = res.file.modules[0];
    try std.testing.expectEqualStrings("res", res.file.str(m.name));
    try std.testing.expectEqual(@as(usize, 2), m.ports.len);
    try std.testing.expectEqual(Ast.Direction.inout, m.ports[0].direction);
    // `electrical p, n;` binds the discipline to the port, not a second net.
    try std.testing.expectEqualStrings("electrical", res.file.str(m.ports[1].discipline));
    try std.testing.expectEqual(@as(usize, 0), m.nets.len);

    // §3.4.2 ranges must survive to proof.zig.
    try std.testing.expectEqual(@as(usize, 1), m.params.len);
    const p0 = m.params[0];
    try std.testing.expectEqual(Ast.Type.real, p0.ty);
    try std.testing.expectEqual(@as(f64, 1000.0), res.file.exprs.realValue(p0.default));
    try std.testing.expectEqual(@as(usize, 2), p0.ranges.len);
    try std.testing.expect(!p0.ranges[0].lo_inclusive);
    try std.testing.expectEqual(Ast.ExprTag.pos_inf, res.file.exprs.tag(p0.ranges[0].hi));
    try std.testing.expectEqual(Ast.ValueRange.Kind.exclude, p0.ranges[1].kind);

    try std.testing.expectEqual(@as(usize, 1), m.analog.len);
    const blk = switch (res.file.stmt(m.analog[0].body)) {
        .block => |b| b,
        else => return error.WrongTag,
    };
    try std.testing.expectEqualStrings("body", res.file.str(blk.name));
    try std.testing.expectEqual(@as(usize, 3), blk.body.len);
    const contrib = switch (res.file.stmt(blk.body[2])) {
        .contribute => |c| c,
        else => return error.WrongTag,
    };
    // `I(p,n)` is a branch probe because `I` is a nature access name (§4.4.1).
    try std.testing.expectEqual(Ast.ExprTag.branch_access, res.file.exprs.tag(contrib.lhs));
    // §4.2.2: `a*b + f(x) - $t` parses as `(a*b + f(x)) - $t`.
    try std.testing.expectEqual(Ast.BinaryOp.sub, res.file.exprs.binOp(contrib.rhs));
}

test "A.1.8 connectrules: both item forms land in their typed slots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every optional slot of connect_insertion in one block, plus both
    // resolution targets, asserted on the AST directly.
    const src =
        \\connectrules cr;
        \\  connect a2d;
        \\  connect a2d split #(.tt(3.5), .vcc(3.3)) input elec, output dig;
        \\  connect d2a merged elec, dig;
        \\  connect e18, e33 resolveto exclude;
        \\  connect x, y, a resolveto a;
        \\endconnectrules
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 1), res.file.connectrules.len);
    const cr = res.file.connectrules[0];
    try std.testing.expectEqualStrings("cr", res.file.str(cr.name));

    try std.testing.expectEqual(@as(usize, 3), cr.insertions.len);
    try std.testing.expectEqual(Ast.ConnectInsertion.Mode.unspecified, cr.insertions[0].mode);
    try std.testing.expectEqual(@as(?Ast.ConnectInsertion.PortOverrides, null), cr.insertions[0].overrides);
    const full = cr.insertions[1];
    try std.testing.expectEqual(Ast.ConnectInsertion.Mode.split, full.mode);
    try std.testing.expectEqual(@as(usize, 2), full.params.len);
    try std.testing.expectEqualStrings("tt", res.file.str(full.params[0].name));
    try std.testing.expectEqual(Ast.Direction.input, full.overrides.?.a_dir);
    try std.testing.expectEqual(Ast.Direction.output, full.overrides.?.b_dir);
    try std.testing.expectEqualStrings("dig", res.file.str(full.overrides.?.b));
    // The undirected override shape keeps both directions unspecified.
    try std.testing.expectEqual(Ast.Direction.unspecified, cr.insertions[2].overrides.?.a_dir);

    try std.testing.expectEqual(@as(usize, 2), cr.resolutions.len);
    try std.testing.expect(cr.resolutions[0].exclude);
    try std.testing.expectEqual(Ast.StrId.none, cr.resolutions[0].resolved);
    try std.testing.expectEqual(@as(usize, 3), cr.resolutions[1].disciplines.len);
    try std.testing.expect(!cr.resolutions[1].exclude);
    try std.testing.expectEqualStrings("a", res.file.str(cr.resolutions[1].resolved));

    // A.1.8's connect_port_overrides admits four direction pairings;
    // `input _, input _` is not one (E0207).
    const bad = try parseForTest(arena,
        \\connectrules crx;
        \\  connect a2d input elec, input dig;
        \\endconnectrules
    );
    try std.testing.expectEqual(diag.Code.E0207, bad.code(0));
}

test "§3.7 wreal: a net type in a `.v` and a `.va` alike" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module m(a, b);
        \\  input wreal a;
        \\  output b;
        \\  wreal b;
        \\  wreal [3:0] bus;
        \\  wreal seeded = 2.5;
        \\endmodule
    ;

    // Annex C.4 / C.8 remove `wreal` from the Verilog-A subset only; in
    // Verilog-AMS §3.7/§6.5.3 make it a net and port type.
    const va = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), va.count());
    try std.testing.expectEqual(Ast.NetKind.wreal, va.file.modules[0].ports[0].kind);

    // A digital parse reads the same text through A.2.1.2
    // `[ net_type | wreal ]` and A.2.1.3's two `wreal` arms, both to
    // `NetKind.wreal`.
    var list = try lexer.tokenize(arena, src, null);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);
    p.digital = true;
    const file = p.parseSourceFile() catch |e| switch (e) {
        error.ParseError => p.file,
        else => return e,
    };
    try std.testing.expect(!bag.failed());

    const m = file.modules[0];
    try std.testing.expectEqual(Ast.NetKind.wreal, m.ports[0].kind); // `input wreal a;`
    try std.testing.expectEqual(Ast.NetKind.wreal, m.ports[1].kind); // `output b;` + `wreal b;`
    // The body nets keep the range and the `net_decl_assignment` driver.
    try std.testing.expectEqual(@as(usize, 2), m.nets.len);
    try std.testing.expectEqual(Ast.NetKind.wreal, m.nets[0].kind);
    try std.testing.expect(m.nets[0].range != null);
    try std.testing.expect(m.nets[1].init != .none);
}

test "UDP single transition descriptor per sequential row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // One pair is one edge, not two. All shorthand edge symbols are
    // independently legal with a level input; level-only rows remain legal.
    for ([_][]const u8{ "(01) 0", "0 (10)", "(0?) 1", "? (??)", "r 0", "R 0", "f 0", "F 0", "p 0", "P 0", "n 0", "N 0", "* 0", "0 1", "x 0" }) |inputs| {
        const src = try arena.print("primitive u(q,a,b); output q; reg q; input a,b; table {s} : ? : 1; endtable endprimitive", .{inputs});
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(usize, 0), res.count());
        try std.testing.expectEqual(@as(usize, 1), res.file.udps[0].rows.len);
    }
    // Pair/pair, pair/symbol in either order and symbol/symbol all exceed
    // the same source restriction, even when their transitions differ.
    for ([_][]const u8{ "(01) (10)", "(01) r", "f (10)", "r f", "P N", "* (??)", "(0?) *", "R F" }) |inputs| {
        const src = try arena.print("primitive u(q,a,b); output q; reg q; input a,b; table {s} : ? : 1; endtable endprimitive", .{inputs});
        const res = try parseForTest(arena, src);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(diag.Code.E0234, res.code(0));
        try std.testing.expectEqualStrings("a sequential UDP table entry permits at most one input transition descriptor", res.bag.at(0).message);
    }
}

test "A.5.1 a UDP's port list is an output and at least one input, in both header arms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try expectFirstErrors(arena_state.allocator(), &.{
        .{ .src = "primitive u(q); output q; table 0 : 1; endtable endprimitive", .code = .E0207 },
        .{ .src = "primitive u(output q); table 0 : 1; endtable endprimitive", .code = .E0207 },
        .{ .src = "primitive u(q, a); output q; input a; table 0 : 1; endtable endprimitive", .code = null },
        .{ .src = "primitive u(output q, input a); table 0 : 1; endtable endprimitive", .code = null },
    }, true);
}

test "A.5.1 a udp_declaration survives the parse, both header arms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both A.5.1 arms, and the sequential body's three moving parts: the
    // `udp_initial_statement`, an `edge_indicator` spelled across several
    // tokens, and a `next_state` of `-`.
    const src =
        \\primitive comb (q, a, b);
        \\  output q; input a, b;
        \\  table
        \\    0 ? : 0;
        \\    ? 0 : 0;
        \\    1 1 : 1;
        \\  endtable
        \\endprimitive
        \\primitive dff (output reg q, input clk, input d);
        \\  initial q = 1'b0;
        \\  table
        \\    (01) 0 : ? : 0;
        \\    (01) 1 : ? : 1;
        \\    (0x) ? : ? : -;
        \\  endtable
        \\endprimitive
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 2), res.file.udps.len);

    const comb = res.file.udps[0];
    try std.testing.expectEqualStrings("comb", res.file.str(comb.name));
    // A.5.2 puts the output first, so ports[0] is `q` and the rest are inputs.
    try std.testing.expectEqual(@as(usize, 3), comb.ports.len);
    try std.testing.expectEqualStrings("q", res.file.str(comb.ports[0]));
    try std.testing.expectEqualStrings("b", res.file.str(comb.ports[2]));
    try std.testing.expect(!comb.is_sequential);
    try std.testing.expectEqual(Ast.ExprId.none, comb.init);
    try std.testing.expectEqual(@as(usize, 3), comb.rows.len);
    try std.testing.expectEqualStrings("0?", comb.rows[0].inputs);
    try std.testing.expectEqual(@as(u8, '0'), comb.rows[0].output);
    try std.testing.expectEqual(@as(u8, 0), comb.rows[0].state);

    const dff = res.file.udps[1];
    try std.testing.expectEqualStrings("dff", res.file.str(dff.name));
    try std.testing.expectEqualStrings("clk", res.file.str(dff.ports[1]));
    try std.testing.expect(dff.is_sequential);
    try std.testing.expect(dff.init != .none);
    // `(01) 0` is one edge field and one level field, several tokens. The
    // characters are kept as one string: splitting it per input port is the
    // evaluator's job and needs the port count.
    try std.testing.expectEqualStrings("(01)0", dff.rows[0].inputs);
    try std.testing.expectEqual(@as(u8, '?'), dff.rows[0].state);
    try std.testing.expectEqual(@as(u8, '1'), dff.rows[1].output);
    try std.testing.expectEqual(@as(u8, '-'), dff.rows[2].output);
}

test "A.2.5: `from` needs a bracket, and saying so is a diagnostic not an assert" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The bare-expression range belongs to `exclude` alone.
    const bad = try parseForTest(arena, "module m; parameter real g = 1 from 5; endmodule");
    try std.testing.expectEqual(@as(usize, 1), bad.count());
    try std.testing.expectEqual(diag.Code.E0207, bad.code(0));
    try std.testing.expectEqualStrings("expected `(` or `[` — only `exclude` takes a bare value", bad.bag.at(0).point);

    // The sibling that is in the grammar parses.
    const ok = try parseForTest(arena, "module m; parameter real g = 1 exclude 5; endmodule");
    try std.testing.expectEqual(@as(usize, 0), ok.count());
}

test "Table 4-3 precedence: ?: is the ONLY right-associative operator (§4.2.2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module m(p);
        \\  inout p;
        \\  electrical p;
        \\  analog I(p) <+ 1 + 2 * 3 ** 2 ** 3 > 4 ? V(p) : 2 ? 3 : 4;
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    const e = &res.file.exprs;
    const rhs = switch (res.file.stmt(res.file.modules[0].analog[0].body)) {
        .contribute => |c| c.rhs,
        else => return error.WrongTag,
    };
    // `?:` is lowest and right-associative: cond ? V(p) : (2 ? 3 : 4)
    try std.testing.expectEqual(Ast.ExprTag.ternary, e.tag(rhs));
    try std.testing.expectEqual(Ast.ExprTag.ternary, e.tag(e.ternaryElse(rhs)));
    // §4.2.2: "All operators associate left to right with the exception of
    // the conditional operator which associates right to left." So the cond is
    // `(1 + (2 * ((3 ** 2) ** 3))) > 4`: `**` groups on the left, and the
    // nested pow hangs off `lhs`. (IEEE 1800's right-associative `**` would
    // make `2**3**2` 512; §4.2.2 gives 64.)
    const cond = e.lhs(rhs);
    try std.testing.expectEqual(Ast.BinaryOp.gt, e.binOp(cond));
    const add = e.lhs(cond);
    try std.testing.expectEqual(Ast.BinaryOp.add, e.binOp(add));
    const mul = e.rhs(add);
    try std.testing.expectEqual(Ast.BinaryOp.mul, e.binOp(mul));
    const pow = e.rhs(mul);
    try std.testing.expectEqual(Ast.BinaryOp.pow, e.binOp(pow));
    try std.testing.expectEqual(Ast.BinaryOp.pow, e.binOp(e.lhs(pow)));
    try std.testing.expectEqual(Ast.ExprTag.int_literal, e.tag(e.rhs(pow)));
}

test "A.6.2/A.6.5: discrete statement forms are grammar in a discrete body of any module, not in analog" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `always`, `assign`, `#`, `wait`, `<=` and intra-assignment timing in an
    // analog module's discrete processes: all module items or statements.
    const ok = try parseForTest(arena,
        \\module m(p);
        \\  inout p; electrical p;
        \\  reg clk, q; wire w;
        \\  assign w = q;
        \\  initial begin clk = 0; #4 clk = 1; wait (q) q = #1 0; end
        \\  always @(posedge clk) q <= 1;
        \\  analog I(p) <+ V(p);
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), ok.count());
    const m = ok.file.modules[0];
    try std.testing.expectEqual(@as(usize, 1), m.assigns.len);
    try std.testing.expectEqual(@as(usize, 2), m.discrete.len);
    // The same forms in an analog block are not analog statements (A.6.4).
    const nba = try parseForTest(arena, "module m(p); inout p; electrical p; integer s; analog begin s <= 1; I(p) <+ V(p); end endmodule");
    try std.testing.expectEqual(diag.Code.E0214, nba.code(0));
    const delay = try parseForTest(arena, "module m(p); inout p; electrical p; analog begin #1 I(p) <+ V(p); end endmodule");
    try std.testing.expectEqual(diag.Code.E0254, delay.code(0));
}

test "A.6.9 a task enable keeps its arguments while the rest of the file grows the expression pool" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The enable's arguments once aliased the pool: the later module's
    // expressions moved it, and they read freed memory (an E1100 design
    // panicked in `digital.compile.infer`, 0xAAAAAAAA in Debug).
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena,
        \\module m;
        \\  reg [7:0] a, b;
        \\  task t(input [7:0] x, input [7:0] y); a = x + y; endtask
        \\  initial t(a[3:0], b);
        \\endmodule
        \\module n;
        \\  reg [31:0] s;
        \\  initial begin
        \\
    );
    for (0..4096) |_| try src.appendSlice(arena, "    s = s + {2{s[3:0]}} - $signed(s[7:0]);\n");
    try src.appendSlice(arena, "  end\nendmodule\n");
    const r = try parseForTest(arena, src.items);
    try std.testing.expectEqual(@as(usize, 0), r.count());
    const enable = r.file.stmt(r.file.modules[0].discrete[0].body).sys_task;
    try std.testing.expectEqualStrings("t", r.file.str(enable.name));
    try std.testing.expectEqual(@as(usize, 2), enable.args.len);
    try std.testing.expectEqual(Ast.ExprTag.index, r.file.exprs.tag(enable.args[0]));
    try std.testing.expectEqual(Ast.ExprTag.ident, r.file.exprs.tag(enable.args[1]));
}

test "A.6.8: `forever` is a digital loop_statement and not an analog_loop_statement (G.2.1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ok = try parseForTest(arena,
        \\module m(p);
        \\  inout p; electrical p;
        \\  integer k;
        \\  initial forever #1 k = k + 1;
        \\  analog I(p) <+ V(p);
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), ok.count());
    const body = ok.file.modules[0].discrete[0].body;
    // Recorded as §9.6's `while (1)`: the condition is the literal 1.
    const loop = ok.file.stmt(body).while_stmt;
    try std.testing.expectEqual(Ast.ExprTag.int_literal, ok.file.exprs.tag(loop.cond));
    try std.testing.expectEqual(@as(i64, 1), ok.file.exprs.intLiteral(loop.cond).value);
    // G.2.1 retired the analog forever: parsed, then refused by A.6.8.
    const ana = try parseForTest(arena, "module m(p); inout p; electrical p; analog forever I(p) <+ V(p); endmodule");
    try std.testing.expectEqual(diag.Code.E0256, ana.code(0));
    try std.testing.expectEqual(@as(usize, 1), ana.count());
    // `statement`, not `statement_or_null`: a null body is E0296.
    const null_body = try parseForTest(arena, "module m(p); inout p; electrical p; initial forever ; analog I(p) <+ V(p); endmodule");
    try std.testing.expectEqual(diag.Code.E0296, null_body.code(0));
}

test "A.3.4: a switch instance closed early is refused by its class" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try parseForTest(arena, "module m; wire a, b, c; cmos g (a, b, c); endmodule");
    try std.testing.expectEqual(diag.Code.E0209, r.code(0));
    try std.testing.expect(std.mem.find(u8, r.msg(0), "cmos_switchtype") != null);
}

test "errors are collected with locations and parsing continues" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module bad(p);
        \\  inout p;
        \\  electrical p;
        \\  child u(p);
        \\  driver_update w;
        \\  analog I(p) <+ V(p);
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    // `child u(p);` is a §6.2.2 module_instantiation; `driver_update` (a
    // reserved word) begins no A.1.4 module item, so it is E0240, not E0205.
    try std.testing.expectEqual(@as(usize, 1), res.count());
    try std.testing.expectEqual(diag.Code.E0240, res.code(0));
    try std.testing.expectEqual(@as(usize, 1), res.file.modules[0].instances.len);

    // The span still points at the offending token, on line 5.
    const idx = try diag.LineIndex.build(arena, src);
    try std.testing.expectEqual(@as(u32, 5), idx.loc(res.bag.at(0).span.start).line);
    // Recovery kept going: the analog block after the bad items still parsed.
    try std.testing.expectEqual(@as(usize, 1), res.file.modules[0].analog.len);
}

test "annex C rejections keep their pinned wording" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { src: []const u8, code: diag.Code, point: []const u8 = "" }{
        // §2.9 "Nesting of attribute instances is disallowed. It shall be illegal
        // to specify the value of an attribute with a constant expression that
        // contains an attribute instance." The outer instance sits in a slot
        // Syntax 2-7 has, and A.8.3 gives the `+` its own attribute slot, so the
        // inner one is refused by this rule, not by the grammar.
        .{
            .src = "module m(p); inout p; electrical p; (* o = (1 + (* i *) 2) *) parameter real x = 1.0; analog I(p) <+ x; endmodule",
            .code = .E0357,
        },
        // A.1.3 `# ( parameter_declaration { , parameter_declaration } )`
        // has no SystemVerilog elision of the `parameter` keyword, so a bare
        // type ends the list at the `(`.
        .{ .src = "module m #(real a = 1) (p); endmodule", .code = .E0207, .point = "expected `)`" },
    };
    for (cases) |c| {
        const res = try parseForTest(arena, c.src);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(c.code, res.code(0));
        // E0207's title is only "unexpected token": what was wanted rides on
        // the caret, so that is what the fixtures pin.
        if (c.point.len != 0)
            try std.testing.expectEqualStrings(c.point, res.bag.at(0).point);
    }
}

test "§6.6 generate: what does not nest, what may not be declared, what may share a name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const head = "module m(p); inout p; electrical p; ";
    // `.code = null`: the parser must accept it. Every rule here is about
    // position, so the permitted position is pinned beside the refused one.
    const cases = [_]struct { src: []const u8, code: ?diag.Code }{
        // §6.6 "Generate regions do not nest, and they may only occur directly
        // within a module": both halves, then the legal single region.
        .{ .src = head ++ "generate generate if (1) ; endgenerate endgenerate endmodule", .code = .E0228 },
        .{ .src = head ++ "generate if (1) begin generate if (1) ; endgenerate end endgenerate endmodule", .code = .E0228 },
        .{ .src = head ++ "generate if (1) ; endgenerate endmodule", .code = null },
        // §6.6 a generate block "may not contain ... parameter declarations".
        // `localparam` in the same position is `module_or_generate_item`'s own
        // alternative, and a `parameter` back at module scope is untouched.
        .{ .src = head ++ "generate if (1) begin parameter real x = 1.0; end endgenerate endmodule", .code = .E0229 },
        .{ .src = head ++ "generate parameter real x = 1.0; endgenerate endmodule", .code = .E0229 },
        .{ .src = head ++ "generate if (1) begin localparam real x = 1.0; end endgenerate endmodule", .code = null },
        .{ .src = head ++ "parameter real x = 1.0; generate if (1) ; endgenerate endmodule", .code = null },
        // §6.6.2 "Named generate blocks may not have the same name as any other
        // declaration in the same scope", and §6.6.1 the same for a loop
        // construct's instance array. The declaration may come after.
        .{ .src = head ++ "real g; generate if (1) begin end endgenerate endmodule", .code = null },
        .{ .src = head ++ "real g; generate if (1) begin : g end endgenerate endmodule", .code = .E0230 },
        .{ .src = head ++ "generate if (1) begin : g end endgenerate real g; endmodule", .code = .E0230 },
        .{ .src = head ++ "genvar i; real g; generate for (i=0;i<2;i=i+1) begin : g end endgenerate endmodule", .code = .E0230 },
        // §6.6.2 "... as blocks in any other generate construct in the same
        // scope, even if not selected for instantiation", hence `if (0)`.
        .{ .src = head ++ "generate if (1) begin : b end if (0) begin : b end endgenerate endmodule", .code = .E0230 },
        // ...against the permission in the preceding bullet: "more than one block
        // within a single conditional generate construct" may share a name, and
        // an `else if` chain is one construct by §6.6.2's direct nesting.
        .{ .src = head ++ "generate if (1) begin : b end else begin : b end endgenerate endmodule", .code = null },
        .{ .src = head ++ "generate if (1) begin : b end else if (1) begin : b end else begin : b end endgenerate endmodule", .code = null },
        // Syntax 6-8 case_generate_construct: a label list, a `default`, and the
        // arms sharing one name (one construct). A.1.4 makes it a
        // module_or_generate_item with or without a generate region, as the
        // loop and if constructs are.
        .{ .src = head ++ "generate case (1) 1, 2: begin : b end default: begin : b end endcase endgenerate endmodule", .code = null },
        .{ .src = head ++ "case (1) 1: ; endcase endmodule", .code = null },
        // §6.6: a generate block brings its module instances, defparams,
        // discrete blocks and events into existence only when the scheme
        // selects or repeats it. The block keeps its instances for elaboration
        // to gate (`Flatten.genInstances`), and an analog parse hoists its
        // discrete blocks and events for the kernel's digital parse to gate.
        // A defparam has no such home: E0235.
        .{ .src = head ++ "generate if (0) begin r u(p); end endgenerate endmodule", .code = null },
        .{ .src = head ++ "generate if (0) begin defparam u.x = 1.0; end endgenerate endmodule", .code = .E0235 },
        .{ .src = head ++ "generate if (0) begin initial begin end end endgenerate endmodule", .code = null },
        .{ .src = head ++ "generate if (0) begin event e; end endgenerate endmodule", .code = null },
        // A generate region has no scheme; its items are ordinary module items.
        .{ .src = head ++ "generate r u(p); endgenerate endmodule", .code = null },
        // IEEE 1364 §19.6: `resetall is illegal within a module, legal between.
        .{ .src = "`resetall\n" ++ head ++ "`resetall\nendmodule", .code = .E0236 },
        .{ .src = "`resetall\n" ++ head ++ "endmodule\n`resetall\n", .code = null },
    };
    for (cases) |c| {
        const res = try parseForTest(arena, c.src);
        if (c.code) |code| {
            try std.testing.expect(res.count() > 0);
            try std.testing.expectEqual(code, res.code(0));
        } else {
            try std.testing.expectEqual(@as(usize, 0), res.count());
        }
    }
}

test "4.7.1's bullet list and 4.7.2.2 are checked at the declaration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const head = "module m(p); inout p; electrical p; analog function real f; ";
    const cases = [_]struct { body: []const u8, code: diag.Code }{
        // "shall have at least one formal argument declared"
        .{ .body = "f = 1.0; endfunction", .code = .E0224 },
        // "all formal arguments shall have an associated block item
        // declaration specifying the data type of the argument"; the
        // direction alone is not one.
        .{ .body = "input x; f = x; endfunction", .code = .E0225 },
        // "shall not use named blocks"
        .{ .body = "input x; real x; begin : b f = x; end endfunction", .code = .E0226 },
        // 4.7.2.2 "shall specify an expression"
        .{ .body = "input x; real x; begin return; end endfunction", .code = .E0227 },
        // A.2.6: the item is A.2.1.2's input_declaration, which has no type.
        .{ .body = "input real x; f = x; endfunction", .code = .E0291 },
        // A.2.6 has no null item, A.6.4 no null analog_function_statement.
        .{ .body = "input x; ; real x; f = x; endfunction", .code = .E0219 },
        // A.6.3: only a named block declares, and 4.7.1 forbids the name.
        .{ .body = "input x; real x; begin real y; y = x; f = y; end endfunction", .code = .E0290 },
    };
    for (cases) |c| {
        const src = try std.mem.concat(arena, u8, &.{ head, c.body, " analog I(p) <+ f(1.0); endmodule" });
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(c.code, res.code(0));
    }

    // The legal spellings: the type in a separate block item declaration,
    // A.2.1.2's one typed direction (`output integer`), an unnamed block, and
    // a `return` with an expression. None may report anything.
    for ([_][]const u8{
        "input x; output integer k; real x; f = x; endfunction",
        "input x; real x; f = x; endfunction",
        "input x; real x; begin f = x; end endfunction",
        "input x; real x; begin return x; end endfunction",
    }) |body| {
        const src = try std.mem.concat(arena, u8, &.{ head, body, " analog I(p) <+ f(1.0); endmodule" });
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }

    // A function without `analog` is IEEE 1364-2005's (§4.7), whose A.2.6/A.2.7
    // forms the bullet list does not govern: an untyped `input x;` is a 1-bit
    // reg, and `automatic`, `signed [range]`, `realtime`, `time` and `reg`
    // formals parse.
    for ([_][]const u8{
        "function integer g; input x; g = x; endfunction",
        "function automatic signed [7:0] g(input reg [7:0] x); g = -x; endfunction",
        "function realtime g; input realtime t; g = t; endfunction",
        "function time g; input time t; reg [3:0] r; g = t; endfunction",
    }) |decl| {
        const src = try std.mem.concat(arena, u8, &.{ "module m(p); inout p; electrical p; ", decl, " analog I(p) <+ V(p); endmodule" });
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "casex/casez and reduction xor PARSE, so lowering owns the annex C rule" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A parse error here would name no rule and make §4.2.10's E0320
    // unreachable; the check belongs where the meaning is known (casex/casez
    // lower, §7.3.2).
    for ([_][]const u8{
        "module m; integer s; analog casex (s) 0: s = 1; endcase endmodule",
        "module m; integer s; analog casez (s) 0: s = 1; endcase endmodule",
        "module m; integer b, q; analog q = ^b; endmodule",
        "module m; integer b, q; analog q = ~^b; endmodule",
    }) |src| {
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "A.6.4 has no null statement outside a conditional, case or event body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // annex G.2.2: the three survivors stay legal, the free-standing `;` does
    // not. `analog ;` is the A.6.2 form of the same mistake.
    for ([_][]const u8{
        "module m(p); inout p; electrical p; analog begin ; I(p) <+ 1.0; end endmodule",
        "module m(p); inout p; electrical p; analog ; endmodule",
        // An event block's `if` arm is analog_statement_or_null, but a block
        // in that arm is a plain analog_seq_block again.
        "module m(p); inout p; electrical p; integer c; analog begin @(initial_step) begin if (c) begin ; end end I(p) <+ 1.0; end endmodule",
    }) |bad| {
        const res = try parseForTest(arena, bad);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(diag.Code.E0219, res.code(0));
    }
    for ([_][]const u8{
        "module m(p); inout p; electrical p; integer c; analog begin if (c) ; else I(p) <+ 1.0; end endmodule",
        "module m(p); inout p; electrical p; integer c; analog begin case (c) 0: ; default: I(p) <+ 1.0; endcase end endmodule",
        "module m(p); inout p; electrical p; analog begin @(initial_step) ; I(p) <+ 1.0; end endmodule",
        // A.6.3's analog_event_seq_block takes analog_event_statements, nested
        // event blocks included, and those have the null alternative.
        "module m(p); inout p; electrical p; integer n; analog begin @(initial_step) begin ; n = 1; begin ; end ; end I(p) <+ 1.0; end endmodule",
    }) |good| {
        const res = try parseForTest(arena, good);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "A.6.5 gives a step event no empty analysis list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad = try parseForTest(arena, "module m(p); inout p; electrical p; real x; analog begin @(final_step()) x = 0.0; I(p) <+ x; end endmodule");
    try std.testing.expect(bad.count() > 0);
    try std.testing.expectEqual(diag.Code.E0220, bad.code(0));

    // Both legal forms: the bare keyword, and a non-empty list.
    for ([_][]const u8{
        "module m(p); inout p; electrical p; real x; analog begin @(final_step) x = 0.0; I(p) <+ x; end endmodule",
        "module m(p); inout p; electrical p; real x; analog begin @(final_step(\"tran\")) x = 0.0; I(p) <+ x; end endmodule",
    }) |good| {
        const res = try parseForTest(arena, good);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "a missing terminator suggests inserting it after the PREVIOUS token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The caret lands on `end`, one line after the mistake. What makes the
    // message actionable is the fix: a zero-width insertion at the end of the
    // contribution, which is where a person has to type the `;`.
    const src =
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ V(p, n)
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(diag.Code.E0207, res.code(0));

    var nbuf: [diag.max_children]diag.Note = undefined;
    const notes = res.bag.notes(res.bag.at(0), &nbuf);
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    const fix = notes[0].fix orelse return error.TestExpectedFix;
    try std.testing.expectEqualStrings(";", fix.replacement);
    // Zero width: an insertion, not a replacement.
    try std.testing.expectEqual(fix.span.start, fix.span.end);
    // ...and it is anchored just past `)`, not at the `end` the caret is under.
    try std.testing.expectEqualStrings("V(p, n)", src[fix.span.start - 7 .. fix.span.start]);

    // A terminator is the only shape that earns an insertion: E0208 wants a
    // name, and no fix can invent one. Here a number stands where
    // list_of_branch_identifiers wants a name.
    const named = try parseForTest(arena, "module m(p); inout p; electrical p; branch (p) 7; endmodule");
    try std.testing.expectEqual(diag.Code.E0208, named.code(0));
    try std.testing.expectEqual(@as(u8, 0), named.bag.at(0).note_count);
}

test "§2.7 a string may not span lines, however it is continued" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The IEEE 1800 §5.9 continuation bsim4va's $strobe uses, and a plain
    // runaway. Both are E0138; only the first earns the SystemVerilog note.
    const cases = [_]struct { src: []const u8, notes: u8 }{
        .{ .src = "module m; analog $strobe(\"a\\\nb\"); endmodule", .notes = 2 },
        .{ .src = "module m; analog $strobe(\"a\nb\"); endmodule", .notes = 1 },
    };
    for (cases) |c| {
        const res = try parseForTest(arena, c.src);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(diag.Code.E0138, res.code(0));
        try std.testing.expectEqualStrings(
            "this literal is still open at the end of the line",
            res.bag.at(0).point,
        );
        try std.testing.expectEqual(c.notes, res.bag.at(0).note_count);
    }
}

test "analog functions, events, case and indirect contributions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\nature Voltage;
        \\  units = "V";
        \\  access = Pot;
        \\  abstol = 1e-6;
        \\endnature
        \\discipline el;
        \\  potential Voltage;
        \\  potential.abstol = 1e-9;
        \\  domain continuous;
        \\  max_voltage = 48.0;
        \\enddiscipline
        \\module m(p, n);
        \\  inout p, n;
        \\  el p, n;
        \\  branch (p, n) br;
        \\  real x[0:1];
        \\  integer k;
        \\  analog function real half;
        \\    input v;
        \\    real v;
        \\    half = v / 2.0;
        \\  endfunction
        \\  analog begin
        \\    @(initial_step("dc", "tran")) x[0] = 0.0;
        \\    @(cross(Pot(p, n), +1) or timer(1n, 1n)) x[1] = 1.0;
        \\    for (k = 0; k < 2; k = k + 1) x[0] = x[0] + half(Pot(br));
        \\    case (k)
        \\      0, 1: $strobe("k=%d", k);
        \\      default: ;
        \\    endcase
        \\    Pot(p, n) : Pot(p) == 2.0 * x[0];
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 1), res.file.natures.len);
    try std.testing.expectEqual(@as(usize, 1), res.file.disciplines.len);
    const d = res.file.disciplines[0];
    try std.testing.expectEqualStrings("Voltage", res.file.str(d.potential));
    try std.testing.expectEqual(Ast.DisciplineDecl.Domain.continuous, d.domain);
    try std.testing.expectEqual(@as(usize, 1), d.overrides.len);
    // §3.6.2.7 a discipline's user-defined attribute, kept like a nature's.
    try std.testing.expectEqual(@as(usize, 1), d.attrs.len);
    try std.testing.expectEqualStrings("max_voltage", res.file.str(d.attrs[0].name));

    const m = res.file.modules[0];
    try std.testing.expectEqual(@as(usize, 1), m.branches.len);
    try std.testing.expectEqual(@as(usize, 1), m.functions.len);
    // `input v; real v;` types the argument and does not leave a local.
    try std.testing.expectEqual(@as(usize, 1), m.functions[0].args.len);
    try std.testing.expectEqual(Ast.Type.real, m.functions[0].args[0].ty);
    try std.testing.expectEqual(@as(usize, 0), m.functions[0].vars.len);

    const body = switch (res.file.stmt(m.analog[0].body)) {
        .block => |b| b.body,
        else => return error.WrongTag,
    };
    try std.testing.expectEqual(@as(usize, 5), body.len);
    const ev = switch (res.file.stmt(body[0])) {
        .event_control => |c| c.event,
        else => return error.WrongTag,
    };
    // §5.10.2: the argument list is analysis-name strings, not expressions.
    try std.testing.expectEqual(Ast.ExprTag.event_initial_step, res.file.exprs.tag(ev));
    try std.testing.expectEqual(@as(usize, 2), res.file.exprs.nameParts(ev).len);
    try std.testing.expectEqualStrings("dc", res.file.str(res.file.exprs.nameParts(ev)[0]));

    const ev2 = switch (res.file.stmt(body[1])) {
        .event_control => |c| c.event,
        else => return error.WrongTag,
    };
    try std.testing.expectEqual(Ast.ExprTag.event_or, res.file.exprs.tag(ev2));
    try std.testing.expectEqual(
        Ast.ExprTag.event_function,
        res.file.exprs.tag(res.file.exprs.lhs(ev2)),
    );
    // §5.6.7 indirect contribution survives parsing (lowering may reject it).
    switch (res.file.stmt(body[4])) {
        .indirect => |ind| try std.testing.expectEqual(
            Ast.ExprTag.branch_access,
            res.file.exprs.tag(ind.probe),
        ),
        else => return error.WrongTag,
    }
}

test "§2.6.1 AST preserves exact digital literals and known literal metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try parseForTest(arena,
        \\module literals;
        \\  integer a, b, c, d;
        \\  initial begin
        \\    a = 85'hz3;
        \\    b = 8'shf;
        \\    c = 128'd18446744073709551617;
        \\    d = 'hx;
        \\    d = {4'b10xz, 4'hf};
        \\  end
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 4), res.file.exprs.logic.items.len);
    try std.testing.expectEqual(@as(u32, 85), res.file.exprs.logic.items[0].width);
    try std.testing.expectEqual(@as(u64, 3), res.file.exprs.logic.items[0].values()[0]);
    try std.testing.expectEqual(@as(u32, 128), res.file.exprs.logic.items[1].width);
    try std.testing.expect(!res.file.exprs.logic.items[2].sized);
    try std.testing.expectEqual(@as(u32, 8), res.file.exprs.ints.items[0].width);
    try std.testing.expect(res.file.exprs.ints.items[0].signed);
    var copy: Ast.SourceFile = .empty;
    try copy.seedFrom(arena, &res.file);
    try std.testing.expect(copy.exprs.logic.items[0].planes.ptr != res.file.exprs.logic.items[0].planes.ptr);
    try std.testing.expectEqualSlices(u64, res.file.exprs.logic.items[0].planes, copy.exprs.logic.items[0].planes);
}

test "A.8.3 min:typ:max reads its typical member, and no analog expression has one (E0295)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A.2.4 param_assignment: bare, and A.8.4's parenthesised constant
    // primary in a parameter declared inside an analog block.
    const ok = try parseForTest(arena,
        \\module m(p); inout p; electrical p;
        \\  parameter real a = 1.0 : 2.0 : 3.0;
        \\  analog begin : b
        \\    parameter real c = (4.0 : 5.0 : 6.0);
        \\    I(p) <+ a * c * V(p);
        \\  end
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), ok.count());
    try std.testing.expectEqual(@as(f64, 2.0), ok.file.exprs.realValue(ok.file.modules[0].params[0].default));

    // A.8.4's analog_primary is `( analog_expression )`.
    const bad = try parseForTest(arena, "module m(p); inout p; electrical p; real x; analog begin x = (1.0 : 2.0 : 3.0); I(p) <+ x; end endmodule");
    try std.testing.expectEqual(@as(usize, 1), bad.count());
    try std.testing.expectEqual(diag.Code.E0295, bad.code(0));
}

test "A.1.3 a null port keeps its position under a name no source spells" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseForTest(arena, "module m(a, , .x(), b); inout a, b; electrical a, b; endmodule");
    try std.testing.expectEqual(@as(usize, 0), res.count());
    const ports = res.file.modules[0].ports;
    try std.testing.expectEqual(@as(usize, 4), ports.len);
    try std.testing.expectEqualStrings("\tnull2", res.file.str(ports[1].name));
    try std.testing.expectEqualStrings("\tnull3", res.file.str(ports[2].name));
    try std.testing.expectEqualStrings("x", res.file.str(ports[2].connName()));
    try std.testing.expectEqualStrings("b", res.file.str(ports[3].connName()));
}

test "Annex A text the parser used to take is refused by its production; the neighbour parses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const head = "module m(p, n); inout p, n; electrical p, n; ";
    const add2 = "analog function real add2; input a, b; real a, b; add2 = a + b; endfunction ";
    const cases = [_]struct { bad: []const u8, good: []const u8, code: diag.Code }{
        // A.8.2 `analog_function_call ::= ... ( analog_expression { , analog_expression } )`.
        .{ .bad = head ++ add2 ++ "analog I(p, n) <+ add2(, 1.0);", .good = head ++ add2 ++ "analog I(p, n) <+ add2(2.0, 1.0);", .code = .E0289 },
        .{ .bad = head ++ add2 ++ "analog I(p, n) <+ add2(1.0, );", .good = head ++ add2 ++ "analog I(p, n) <+ add2(1.0, 2.0);", .code = .E0289 },
        .{ .bad = head ++ "analog I(p, n) <+ Vp(, n);", .good = head ++ "analog I(p, n) <+ V(p, n);", .code = .E0289 },
        .{ .bad = head ++ "analog Ip() <+ V(p, n);", .good = head ++ "analog I(p) <+ V(p, n);", .code = .E0289 },
        // A.6.3: only a named block declares.
        .{ .bad = head ++ "analog begin real x; x = V(p, n); I(p, n) <+ x; end ", .good = head ++ "analog begin : b real x; x = V(p, n); I(p, n) <+ x; end ", .code = .E0290 },
        // A.2.1.3: names, or assignments, never both.
        .{ .bad = "module m(p, n); inout p, n; electrical p = 1.5, n; ", .good = "module m(p, n); inout p, n; electrical p = 1.5; electrical n; ", .code = .E0292 },
        .{ .bad = "module m(p, n); inout p, n; electrical p, n = 1.5; ", .good = "module m(p, n); inout p, n; electrical p; electrical n = 1.5; ", .code = .E0292 },
        .{ .bad = head ++ "supply1 supply1 s1; ", .good = head ++ "supply1 s1; ", .code = .E0207 },
        // A.4.1 names a module instance; A.5.4's unnamed UDP instance has two terminals.
        .{ .bad = head ++ "child(p); ", .good = head ++ "child c1(p); ", .code = .E0293 },
        // A.7.1 `pulsestyle_onevent list_of_path_outputs ;`.
        .{ .bad = head ++ "specify pulsestyle_onevent (p); endspecify ", .good = head ++ "specify pulsestyle_onevent p; endspecify ", .code = .E0207 },
        // A.8.5: an lvalue opens with a name or `{`.
        .{ .bad = head ++ "analog begin 2.0 = V(p, n); end ", .good = head ++ "analog begin : b real x; x = V(p, n); end ", .code = .E0207 },
        .{ .bad = head ++ "reg q; initial begin #1 20 = 1'bx; end ", .good = head ++ "reg q; initial begin #1 q = 1'bx; end ", .code = .E0207 },
        // A.2.6: a function without `analog` has `input` formals only.
        .{ .bad = head ++ "function real g; input a; output b; g = a; endfunction ", .good = head ++ "function real g; input a; g = a; endfunction ", .code = .E0207 },
    };
    for (cases) |c| {
        for ([_][]const u8{ c.bad, c.good }, [_]bool{ true, false }) |body, bad| {
            const res = try parseForTest(arena, try std.mem.concat(arena, u8, &.{ body, "endmodule" }));
            var first: ?diag.Code = null;
            for (0..res.count()) |i| if (res.bag.at(i).severity == .err) {
                first = res.code(i);
                break;
            };
            try std.testing.expectEqual(if (bad) @as(?diag.Code, c.code) else null, first);
        }
    }

    // A.6.9: a call heading a discrete statement is a task enable, whose null
    // argument is IEEE 1364-2005 §10.2.2's refusal (the digital engine's),
    // not A.8.2's E0289. A function call in the same block is still E0289.
    const task_src = "module m; integer x; task take(input a, input b); begin end endtask " ++
        "function integer f(input a, input b); f = a; endfunction ";
    const enable = try parseForTest(arena, task_src ++ "initial take(1'b1, ); endmodule");
    for (0..enable.count()) |i| try std.testing.expect(enable.code(i) != .E0289);
    const call = try parseForTest(arena, task_src ++ "initial x = f(1, ); endmodule");
    try std.testing.expect(call.count() > 0);
    try std.testing.expectEqual(diag.Code.E0289, call.code(0));
}

test "an attribute instance before an item list's closer prefixes nothing: E0207 in every list (#49, #50, #66, #69)" {
    // §2.9: an attribute_instance is "a prefix attached to a declaration, a
    // module item, a statement, or a port connection". Each bad source puts
    // one where its list closes, so it is refused once, by E0207 and not as
    // the start of a statement (E0209); the good one has it prefix an item.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const head = "module m(p); inout p; electrical p; ";
    const cases = [_]struct { bad: []const u8, good: []const u8, digital: bool = false }{
        .{ .bad = head ++ "analog I(p) <+ V(p); (* a *) endmodule", .good = head ++ "(* a *) analog I(p) <+ V(p); endmodule" },
        .{ .bad = head ++ "if (1) begin analog I(p) <+ V(p); (* a *) end endmodule", .good = head ++ "if (1) begin (* a *) analog I(p) <+ V(p); end endmodule" },
        .{ .bad = head ++ "generate analog I(p) <+ V(p); (* a *) endgenerate endmodule", .good = head ++ "generate (* a *) analog I(p) <+ V(p); endgenerate endmodule" },
        .{ .bad = head ++ "analog function real f; input x; real x; (* a *) endfunction analog I(p) <+ V(p); endmodule", .good = head ++ "analog function real f; input x; (* a *) real x; f = x; endfunction analog I(p) <+ V(p); endmodule" },
        .{ .bad = head ++ "parameter real r = 1; analog I(p) <+ r * V(p); endmodule paramset ps m; parameter real q = 2; .r = q; (* a *) endparamset", .good = head ++ "parameter real r = 1; analog I(p) <+ r * V(p); endmodule paramset ps m; (* a *) parameter real q = 2; .r = q; endparamset" },
        .{ .bad = head ++ "analog I(p) <+ V(p); endmodule (* a *)", .good = "(* a *) " ++ head ++ "analog I(p) <+ V(p); endmodule" },
        // #50: a digital function or task body, as `vera --run` parses it.
        // The good source's attribute prefixes the body's first statement.
        .{ .bad = "module m; function integer f(input x); (* a *) endfunction endmodule", .good = "module m; function integer f(input x); (* a *) f = x; endfunction endmodule", .digital = true },
        .{ .bad = "module m; task t; input x; (* a *) endtask endmodule", .good = "module m; task t; input x; (* a *) $display(x); endtask endmodule", .digital = true },
        // #66: statement blocks. Before the closer of an analog or digital
        // `begin`, a `fork`, or a subroutine body after its statement.
        .{ .bad = head ++ "analog begin (* a *) end endmodule", .good = head ++ "analog begin (* a *) I(p) <+ V(p); end endmodule" },
        .{ .bad = head ++ "analog begin I(p) <+ V(p); (* a *) end endmodule", .good = head ++ "analog begin I(p) <+ V(p); (* a *) I(p) <+ V(p); end endmodule" },
        .{ .bad = "module m; reg r; initial begin r = 0; (* a *) end endmodule", .good = "module m; reg r; initial begin (* a *) r = 0; end endmodule", .digital = true },
        .{ .bad = "module m; reg r; initial fork r = 0; (* a *) join endmodule", .good = "module m; reg r; initial fork (* a *) r = 0; join endmodule", .digital = true },
        .{ .bad = "module m; function integer f(input x); f = x; (* a *) endfunction endmodule", .good = "module m; function integer f(input x); (* a *) f = x; endfunction endmodule", .digital = true },
        .{ .bad = "module m; task t; input x; $display(x); (* a *) endtask endmodule", .good = "module m; task t; input x; (* a *) $display(x); endtask endmodule", .digital = true },
        // #69: a case statement's arm list, analog and digital, all three
        // kinds. The good source's attribute prefixes the arm's statement
        // (A.6.7 `statement_or_null`).
        .{ .bad = head ++ "analog case (1) 1: I(p) <+ V(p); (* a *) endcase endmodule", .good = head ++ "analog case (1) 1: (* a *) I(p) <+ V(p); endcase endmodule" },
        .{ .bad = head ++ "analog begin casex (1) default: I(p) <+ V(p); (* a *) endcase end endmodule", .good = head ++ "analog begin casex (1) default: (* a *) I(p) <+ V(p); endcase end endmodule" },
        .{ .bad = "module m; reg r; initial case (r) 1: r = 0; (* a *) endcase endmodule", .good = "module m; reg r; initial case (r) 1: (* a *) r = 0; endcase endmodule", .digital = true },
        .{ .bad = "module m; reg r; initial casez (r) 1'b?: r = 0; (* a *) endcase endmodule", .good = "module m; reg r; initial casez (r) 1'b?: (* a *) r = 0; endcase endmodule", .digital = true },
    };
    for (cases) |c| {
        const bad = if (c.digital) try parseDigitalForTest(arena, c.bad) else try parseForTest(arena, c.bad);
        var e0207: u32 = 0;
        for (0..bad.count()) |i| {
            if (bad.code(i) == .E0207) e0207 += 1;
            try std.testing.expect(bad.code(i) != .E0209);
        }
        try std.testing.expectEqual(@as(u32, 1), e0207);
        const good = if (c.digital) try parseDigitalForTest(arena, c.good) else try parseForTest(arena, c.good);
        for (0..good.count()) |i| try std.testing.expect(good.bag.at(i).severity != .err);
    }
}

// ---------------------------------------------------------------------------
// Corner cases, one Annex A production or LRM rule per test. Every expected
// value is read off the cited clause or production, never off the parser's
// output. The oracle of each refusal is the diagnostic the clause names; the
// legal neighbour beside it shows the refusal is not a blanket one.
// ---------------------------------------------------------------------------

/// The first error-severity diagnostic of `r`, or null when it has none.
/// Warnings (W0251, W0252, W0253) do not count: they leave the file accepted.
fn firstError(r: TestResult) ?diag.Code {
    for (0..r.count()) |i| if (r.bag.at(i).severity == .err) return r.code(i);
    return null;
}

/// The message of the first error-severity diagnostic of `r`, or "".
fn firstErrorMsg(r: TestResult) []const u8 {
    for (0..r.count()) |i| if (r.bag.at(i).severity == .err) return r.msg(i);
    return "";
}

/// Lexes and parses `src` the way `vera --run` does (`Parser.digital`).
fn parseDigitalForTest(arena: std.mem.Allocator, src: []const u8) !TestResult {
    const list = try lexer.tokenize(arena, src, null);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);
    p.digital = true;
    const file = p.parseSourceFile() catch |e| switch (e) {
        error.ParseError => p.file,
        else => return e,
    };
    return .{ .file = file, .bag = bag };
}

/// One source and the first error it must raise; null means it must parse.
const Expect = struct { src: []const u8, code: ?diag.Code };

/// Parses each case (analog, or digital when `digital`) and checks its first
/// error, printing the source of the case that disagrees.
fn expectFirstErrors(arena: std.mem.Allocator, cases: []const Expect, digital: bool) !void {
    for (cases) |c| {
        const r = if (digital) try parseDigitalForTest(arena, c.src) else try parseForTest(arena, c.src);
        std.testing.expectEqual(c.code, firstError(r)) catch |e| {
            std.debug.print("source: {s}\nfirst message: {s}\n", .{ c.src, firstErrorMsg(r) });
            return e;
        };
    }
}

/// The right-hand side of module 0's first analog block, which the caller
/// wrote as one assignment or contribution.
fn analogRhs(r: TestResult) !Ast.ExprId {
    return switch (r.file.stmt(r.file.modules[0].analog[0].body)) {
        .assign => |a| a.value,
        .contribute => |c| c.rhs,
        else => error.WrongTag, // else: the caller wrote one assignment or contribution; any other statement fails the test
    };
}

test "Parser token access: tokenText strips `\\`, reservedIs and eatSymbol read spellings, peekAt clamps (§2.8.1, A.7)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "\\a.b  specify => z";
    const list = try lexer.tokenize(arena, src, null);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);
    // §2.8.1: "the leading backslash character is not considered to be part
    // of the identifier".
    try std.testing.expectEqual(token.Tag.escaped_identifier, p.peek());
    try std.testing.expectEqualStrings("a.b", p.tokenText(0));
    // ...and its period becomes a space, so it cannot read as a hierarchy
    // separator (`internTok`).
    try std.testing.expectEqualStrings("a b", p.file.str(try p.internTok(0)));
    try std.testing.expect(p.reservedIs(1, "specify"));
    try std.testing.expect(!p.reservedIs(1, "endspecify"));
    p.pos = 2;
    // `=>` is one token the lexer tags `.invalid`; only its spelling says so.
    try std.testing.expect(!p.eatSymbol("*>"));
    try std.testing.expectEqual(@as(u32, 2), p.pos);
    try std.testing.expect(p.eatSymbol("=>"));
    try std.testing.expectEqual(@as(u32, 3), p.pos);
    // Lookahead past the end reads the final `.eof`, never out of bounds.
    try std.testing.expectEqual(token.Tag.eof, p.peekAt(1000));
    try std.testing.expectEqual(@as(usize, 0), bag.count());

    // IEEE 1364-2005 §3.7.3: a system task "shall not be escaped", so the
    // escaped name keeps its `\` and can name no system task.
    const src2 = "\\$display x";
    const list2 = try lexer.tokenize(arena, src2, null);
    var q = Parser.init(arena, src2, list2.items(.tag), list2.items(.start), try newBag(arena, src2));
    try std.testing.expectEqualStrings("\\$display", q.file.str(try q.internTok(0)));
}

test "internTok keeps every two escaped names apart, and no interned name holds a period (§2.8.1; IEEE 1364-2005 §3.7.1, §3.7.3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Oracle: §3.7.1's identity, `identity` below. A period would read as
    // a hierarchy separator after this point (`elab.sep`).
    const names = [_][]const u8{
        "ab",     "$ab",     "\\ab",    "\\$ab", "\\\\ab", "\\\\$ab", "\\\\\\$ab", "\\a.b",
        "\\$a.b", "\\\\a.b", "\\$a.b.", "\\.ab", "\\ab.",  "\\$",     "\\\\",      "\\1ab",
        "a_b",    "\\a_b",
    };
    const src = try std.mem.join(arena, " ", &names);
    const list = try lexer.tokenize(arena, src, null);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), try newBag(arena, src));
    try std.testing.expectEqual(names.len + 1, list.len); // one token each, then `.eof`
    var ids: [names.len]Ast.StrId = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try p.internTok(@intCast(i));
        try std.testing.expect(std.mem.findScalar(u8, p.file.str(id.*), '.') == null);
    }
    for (names, ids, 0..) |a, ia, i| for (names[i + 1 ..], ids[i + 1 ..]) |b, ib| {
        if (std.mem.eql(u8, identity(a), identity(b)) != (ia == ib)) {
            std.debug.print("`{s}` and `{s}` intern as `{s}` and `{s}`\n", .{ a, b, p.file.str(ia), p.file.str(ib) });
            return error.TestUnexpectedResult;
        }
    };
}

/// §3.7.1: an escaped name is the text after its `\`, the same identifier
/// as a simple one of that spelling and no other; §3.7.3: `\$x` is not
/// the system name `$x`. So a name's identity is that simple spelling, or
/// else the escaped spelling itself.
fn identity(name: []const u8) []const u8 {
    if (name[0] != '\\') return name;
    const text = name[1..];
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return name;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return name;
    return text;
}

test "tokenText's identifier fast path agrees with the lexer's re-scan on every token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Every keyword spelling, reserved words with no tag of their own,
    // identifiers using each §2.8 character class, and tokens of every other
    // shape around them (the fast path must not reach those).
    var src: std.ArrayList(u8) = .empty;
    for (std.enums.values(token.Tag)) |t| if (token.isKeyword(t)) if (token.Tag.lexeme(t)) |w| {
        try src.appendSlice(arena, w);
        try src.append(arena, ' ');
    };
    try src.appendSlice(arena, "specify wreal pullup a _b c$d e9 abc_$1 \\esc.x  $sys `begin_keywords 12 3.5e-3 2.2n 4'hF \"s\" (* *) <+ >>> ;");
    for (mutation_corpus) |c| try src.appendSlice(arena, c);
    const list = try lexer.tokenize(arena, src.items, null);
    const p = Parser.init(arena, src.items, list.items(.tag), list.items(.start), try newBag(arena, src.items));
    var fast: usize = 0;
    for (p.tags, p.starts, 0..) |t, start, i| {
        if (t == .escaped_identifier) continue; // `tokenText` strips its `\`
        if (t == .identifier or token.isKeyword(t)) fast += 1;
        try std.testing.expectEqualStrings(lexer.tokenText(src.items, start), p.tokenText(@intCast(i)));
    }
    try std.testing.expect(fast > 200);
}

test "Parser.expect: E0207 leaves the cursor, and only a terminator earns an insertion fix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "module ;";
    const list = try lexer.tokenize(arena, src, null);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);

    try std.testing.expectError(error.ParseError, p.expect(.semicolon));
    try std.testing.expectEqual(@as(u32, 0), p.pos);
    try std.testing.expect(p.failed);
    try std.testing.expectEqual(diag.Code.E0207, bag.at(0).code);
    try std.testing.expectEqual(@as(u8, 1), bag.at(0).note_count); // the `;` insertion

    try std.testing.expectEqual(@as(u32, 0), try p.expect(.kw_module));
    try std.testing.expectEqual(@as(u32, 1), p.pos);

    // `end` closes a block, but no fix can say where the block should end.
    try std.testing.expectError(error.ParseError, p.expect(.kw_end));
    try std.testing.expectEqual(@as(u32, 1), p.pos);
    try std.testing.expectEqual(diag.Code.E0207, bag.at(1).code);
    try std.testing.expectEqual(@as(u8, 0), bag.at(1).note_count);
}

/// Parses `prefix ++ open*n ++ middle ++ close*n ++ suffix` and returns the
/// parser's `deepest`, failing the test on any diagnostic.
fn parseNested(arena: std.mem.Allocator, prefix: []const u8, open: []const u8, middle: []const u8, close: []const u8, suffix: []const u8, n: usize) !u32 {
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena, prefix);
    for (0..n) |_| try src.appendSlice(arena, open);
    try src.appendSlice(arena, middle);
    for (0..n) |_| try src.appendSlice(arena, close);
    try src.appendSlice(arena, suffix);
    const list = try lexer.tokenize(arena, src.items, null);
    const bag = try newBag(arena, src.items);
    var p = Parser.init(arena, src.items, list.items(.tag), list.items(.start), bag);
    _ = try p.parseSourceFile();
    try std.testing.expectEqual(@as(usize, 0), bag.count());
    try std.testing.expectEqual(@as(u32, 0), p.depth);
    try std.testing.expectEqual(@as(u32, 0), p.seg.frames);
    return p.deepest;
}

test "nesting has no parser bound: each construct at the old 1024 cap and far past it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // 1025 was one past E0241's old cap; 100,000 crosses many stack segments
    // (`segment_levels`), so the run also checks `frames` unwinds across them.
    for ([_]usize{ 1025, 100_000 }) |n| try parseEveryNesting(arena_state.allocator(), n);
}

test "nesting 5000 deep parses on a 1 MiB thread: the caller's stack is not what bounds it" {
    // Oracle: the guard page. An embedder's thread may have 1 MiB, and
    // `deep_stack` says nesting is bounded by memory, not by that stack.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const Run = struct {
        fn on(out: *anyerror!void) void {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_state.deinit();
            out.* = parseEveryNesting(arena_state.allocator(), 5000);
        }
    };
    var result: anyerror!void = {};
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, Run.on, .{&result});
    t.join();
    try result;
}

/// Parses each nesting construct `n` deep, failing on a diagnostic or on
/// a `deepest` short of `n`.
fn parseEveryNesting(arena: std.mem.Allocator, n: usize) !void {
    const m = "module m(p); inout p; electrical p; real r; integer k; analog begin ";
    const e = " end endmodule";
    const deep: u32 = @intCast(n);
    try std.testing.expect(try parseNested(arena, m ++ "r = ", "(", "1.0", ")", ";" ++ e, n) >= deep);
    // A.8.3: a unary operand is a primary, so a deep unary chain is
    // parenthesized (`- -x` is E0209).
    try std.testing.expect(try parseNested(arena, m ++ "r = ", "-(", "1.0", ")", ";" ++ e, n) >= deep);
    try std.testing.expect(try parseNested(arena, m ++ "r = ", "V(p) > 1 ? 1 : ", "0", "", ";" ++ e, n) >= deep);
    try std.testing.expect(try parseNested(arena, m ++ "r = ", "V(p) > 1 ? ", "1", " : 0", ";" ++ e, n) >= deep);
    try std.testing.expect(try parseNested(arena, m ++ "r = 1.0", " + 1.0", "", "", ";" ++ e, n) >= deep);
    try std.testing.expect(try parseNested(arena, m, "begin ", "r = 1;", " end", e, n) >= deep);
    try std.testing.expect(try parseNested(arena, m, "if (V(p) > 1) r = 1; else ", "r = 0;", "", e, n) >= deep);
    try std.testing.expect(try parseNested(arena, m ++ "k = ", "{", "1'b1", "}", ";" ++ e, n) >= deep);
    try std.testing.expect(try parseNested(arena, "module m; generate ", "if (1) begin ", "", "end ", "endgenerate endmodule", n) >= deep);
    // Left-assoc chains a loop builds: each link is one level of the tree.
    try std.testing.expect(try parseNested(arena, m ++ "r = x", "[0]", "", "", ";" ++ e, n) >= deep);
    try std.testing.expect(try parseNested(arena, m ++ "@(cross(V(p))", " or cross(V(p))", ") r = 1;", "", e, n) >= deep);
}

test "a defparam path's index folds on a stack sized for its depth (A.9.3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `u[1+1+...+1].p`: the fold of the index recurses once per `+`.
    const n = 100_000;
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena, "module m; defparam u[");
    for (0..n) |_| try src.appendSlice(arena, "1+");
    try src.appendSlice(arena, "1].p = 1; endmodule");
    const r = try parseForTest(arena, src.items);
    try std.testing.expectEqual(@as(usize, 0), r.count());
    try std.testing.expectEqualStrings("u[100001].p", r.file.str(r.file.modules[0].defparams[0].path));
}

test "§6.6 generate regions nested 10^5 deep are E0228, not a stack overflow" {
    // "Generate regions do not nest": each inner one is reported and read
    // on, a recursion through the module-item loop that no `enter` counts.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n = 100_000;
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena, "module m; ");
    for (0..n) |_| try src.appendSlice(arena, "generate ");
    for (0..n) |_| try src.appendSlice(arena, "endgenerate ");
    try src.appendSlice(arena, "endmodule");
    const r = try parseForTest(arena, src.items);
    try std.testing.expect(r.count() != 0);
    try std.testing.expectEqual(diag.Code.E0228, r.code(0));
}

// Left out of a single-threaded build: there no stack segment is
// reserved (`deep_stack` runs the walk in place), so nothing can refuse.
comptime {
    if (!@import("builtin").single_threaded) _ = threaded;
}
const threaded = struct {
    test "a stack segment that cannot be reserved is E0241, naming the depth" {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(arena, "module m; real r; analog r = ");
        try src.appendNTimes(arena, '(', parser.caller_levels + 1);
        try src.appendSlice(arena, "1.0");
        try src.appendNTimes(arena, ')', parser.caller_levels + 1);
        try src.appendSlice(arena, "; endmodule");
        deep_stack.refuse_for_test = true;
        defer deep_stack.refuse_for_test = false;
        const r = try parseForTest(arena, src.items);
        try std.testing.expectEqual(@as(?diag.Code, .E0241), firstError(r));
        try std.testing.expect(std.mem.find(u8, firstErrorMsg(r), "levels deep") != null);
    }
};

test "§2.9 attribute specs: the last value of a name wins, and a speculative read rewinds exactly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "(* vera_lte = 0, vera_lte = 1 *) x";
    const list = try lexer.tokenize(arena, src, null);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);

    const mark = p.markAttributes();
    try p.skipAttributes();
    try std.testing.expectEqual(token.Tag.identifier, p.peek());
    try std.testing.expectEqual(@as(usize, 2), p.attrs.items.len);
    // One prefix, one binding, owned by the declaration at the cursor.
    try std.testing.expectEqual(@as(usize, 1), p.file.attributes.items.len);
    try std.testing.expectEqual(p.pos, p.file.attributes.items[0].owner.tok);
    // §2.9: "If the same attribute name is defined more than once for the
    // same language element, the last attribute value shall be used."
    // `vera_lte` is the first `LteAttr.kind`, so slot 0.
    const lte = p.lteSince(0);
    try std.testing.expectEqual(@as(i64, 1), p.file.exprs.intValue(lte[0].?.value));
    try std.testing.expect(lte[1] == null);

    p.rewindAttributes(mark);
    try std.testing.expectEqual(@as(u32, 0), p.pos);
    try std.testing.expectEqual(@as(usize, 0), p.attrs.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.file.attributes.items.len);
    try std.testing.expectEqual(@as(usize, 0), bag.count());
}

test "§2.9 attribute instances: names, placement, and who owns the prefix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectFirstErrors(arena, &.{
        // A.9.1 `attr_name ::= identifier`: a keyword is not one...
        .{ .src = "(* module = 1 *) module m; endmodule", .code = .E0208 },
        // ...except §2.9.2's own `units`, which it prints unescaped (VD-024).
        .{ .src = "(* units = \"V\" *) module m; endmodule", .code = null },
        // An escaped keyword is an identifier (§2.8.1).
        .{ .src = "(* \\module = 1 *) module m; endmodule", .code = null },
        // §3.8: an instance is "a prefix attached to" what follows it.
        .{ .src = "module m; endmodule (* a *)", .code = .E0207 },
        // A.9.1 `attr_spec ::= attr_name [ = constant_expression ]`: an
        // empty instance has no attr_name.
        .{ .src = "(* *) module m; endmodule", .code = .E0208 },
    }, false);

    // §2.9 Example 5: a prefix on a declaration belongs to every name in its
    // list. Three bindings of one spec list: the `real` keyword the prefix
    // was read at, then `a` and `b`; the module item's own pass adds no
    // duplicate.
    const decl = try parseForTest(arena, "module m; (* desc = \"x\" *) real a, b; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(decl));
    const rows = decl.file.attributes.items;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    const vars = decl.file.modules[0].vars;
    try std.testing.expectEqual(vars[0].main_tok - 1, rows[0].owner.tok);
    try std.testing.expectEqual(vars[0].main_tok, rows[1].owner.tok);
    try std.testing.expectEqual(vars[1].main_tok, rows[2].owner.tok);
    for (rows) |row| {
        try std.testing.expect(row.owner.kind == .declaration);
        try std.testing.expect(row.specs.ptr == rows[0].specs.ptr);
    }

    // A.6.4 `{ attribute_instance } statement`: the prefix a block's
    // declaration scan read first is handed back and owned by the statement.
    const stmt = try parseForTest(arena, "module m; integer x; analog begin (* a *) x = 1; end endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(stmt));
    try std.testing.expectEqual(@as(usize, 1), stmt.file.attributes.items.len);
    try std.testing.expect(stmt.file.attributes.items[0].owner.kind == .statement);

    // §2.9 Example 7 `add (* mode = "cla" *) (b, c)`: a suffix on a function
    // name is the call's.
    const call = try parseForTest(arena, "module m; real x; analog x = f (* mode = \"cla\" *) (1.0); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(call));
    try std.testing.expectEqual(@as(usize, 1), call.file.attributes.items.len);
    try std.testing.expect(call.file.attributes.items[0].owner.kind == .expression);
    try std.testing.expectEqual(Ast.ExprTag.call, call.file.exprs.tag(try analogRhs(call)));

    // VerA's `vera_lte` on a keyword-named call is kept for that call alone.
    const lte = try parseForTest(arena, "module m(p); inout p; electrical p; real q; analog I(p) <+ ddt (* vera_lte = 0 *) (q); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(lte));
    try std.testing.expectEqual(@as(usize, 1), lte.file.lte_attrs.items.len);
    try std.testing.expect(lte.file.lte_attrs.items[0].kind == .vera_lte);
    try std.testing.expectEqual(Ast.StmtId.none, lte.file.lte_attrs.items[0].stmt);
    try std.testing.expectEqual(try analogRhs(lte), lte.file.lte_attrs.items[0].expr);
}

test "Table 4-3: every binary precedence level, left associativity, and unary over binary (§4.2.2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Each operator is one Table 4-3 row below the next, so each is the
    // right operand of the one before it.
    const r = try parseForTest(arena, "module m; integer x; analog x = a || b && c | d ^ e & f == g < h << i + j * k ** l; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(r));
    const ex = &r.file.exprs;
    const chain = [_]Ast.BinaryOp{ .logical_or, .logical_and, .bit_or, .bit_xor, .bit_and, .eq, .lt, .shl, .add, .mul, .pow };
    var e = try analogRhs(r);
    for (chain) |op| {
        try std.testing.expectEqual(Ast.ExprTag.binary, ex.tag(e));
        try std.testing.expectEqual(op, ex.binOp(e));
        try std.testing.expectEqual(Ast.ExprTag.ident, ex.tag(ex.lhs(e)));
        e = ex.rhs(e);
    }
    try std.testing.expectEqual(Ast.ExprTag.ident, ex.tag(e));

    // "All operators associate left to right": a - b - c is (a - b) - c.
    const left = try parseForTest(arena, "module m; integer x; analog x = a - b - c; endmodule");
    const lx = &left.file.exprs;
    const top = try analogRhs(left);
    try std.testing.expectEqual(Ast.BinaryOp.sub, lx.binOp(top));
    try std.testing.expectEqual(Ast.ExprTag.binary, lx.tag(lx.lhs(top)));
    try std.testing.expectEqual(Ast.ExprTag.ident, lx.tag(lx.rhs(top)));

    // Table 4-3's top row: unary binds tighter than `**`, so -a ** b is
    // (-a) ** b.
    const un = try parseForTest(arena, "module m; integer x; analog x = -a ** b; endmodule");
    const ux = &un.file.exprs;
    const pow = try analogRhs(un);
    try std.testing.expectEqual(Ast.BinaryOp.pow, ux.binOp(pow));
    try std.testing.expectEqual(Ast.UnaryOp.minus, ux.unOp(ux.lhs(pow)));
}

test "A.8.4 primaries: selects, part-selects, hierarchical names, probes, calls and inf" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // IEEE 1364-2005 §5.2.1 indexed part-select: `extra` 0 for `+:`, 1 for `-:`.
    for ([_]struct { sel: []const u8, tag: Ast.ExprTag, down: u32 }{
        .{ .sel = "y[3 +: 2]", .tag = .indexed_range, .down = 0 },
        .{ .sel = "y[3 -: 2]", .tag = .indexed_range, .down = 1 },
        .{ .sel = "y[3:0]", .tag = .range, .down = 0 },
    }) |c| {
        const src = try arena.print("module m; integer x, y; analog x = {s}; endmodule", .{c.sel});
        const r = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(?diag.Code, null), firstError(r));
        const sel = try analogRhs(r);
        try std.testing.expectEqual(Ast.ExprTag.index, r.file.exprs.tag(sel));
        const idx = r.file.exprs.rhs(sel);
        try std.testing.expectEqual(c.tag, r.file.exprs.tag(idx));
        if (c.tag == .indexed_range) try std.testing.expectEqual(c.down, r.file.exprs.extraOf(idx));
    }

    // §6.7 hierarchical names: dotted parts, `$root` as part 0, and a dotted
    // call under the joined name (§6.7.1).
    const hier = try parseForTest(arena, "module m; real x; analog x = a.b.c + $root.top.v + u.f(1.0); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(hier));
    const hx = &hier.file.exprs;
    const sum = try analogRhs(hier);
    const abc = hx.lhs(hx.lhs(sum));
    try std.testing.expectEqual(Ast.ExprTag.hier_ident, hx.tag(abc));
    try std.testing.expectEqual(@as(usize, 3), hx.nameParts(abc).len);
    const rooted = hx.rhs(hx.lhs(sum));
    try std.testing.expectEqualStrings("$root", hier.file.str(hx.nameParts(rooted)[0]));
    try std.testing.expectEqual(@as(usize, 3), hx.nameParts(rooted).len);
    const call = hx.rhs(sum);
    try std.testing.expectEqual(Ast.ExprTag.call, hx.tag(call));
    try std.testing.expectEqualStrings("u.f", hier.file.str(hx.strOf(call)));

    // §4.4.1: a declared access name probes; any other name calls (§4.7);
    // §4.4's generic `potential` probes as `V` does.
    const probe = try parseForTest(arena, "module m(p); inout p; electrical p; real x; analog x = V(p) + foo(p) + potential(p); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(probe));
    const px = &probe.file.exprs;
    const top = try analogRhs(probe);
    try std.testing.expectEqual(Ast.ExprTag.branch_access, px.tag(px.lhs(px.lhs(top))));
    try std.testing.expectEqual(Ast.ExprTag.call, px.tag(px.rhs(px.lhs(top))));
    try std.testing.expectEqual(Ast.ExprTag.branch_access, px.tag(px.rhs(top)));
    try std.testing.expectEqualStrings("potential", probe.file.str(px.strOf(px.rhs(top))));

    // §5.4.3 port branch `I(<p>)`.
    const port = try parseForTest(arena, "module m(p); inout p; electrical p; real x; analog x = I(<p>); endmodule");
    try std.testing.expectEqual(Ast.ExprTag.port_access, port.file.exprs.tag(try analogRhs(port)));

    // §5.6.8.2 hierarchical unnamed branch: the terminals land on the
    // instance path and the node is marked.
    const hb = try parseForTest(arena, "module m; real x; analog x = V(top.drv.branch(a, b)) + I(u.branch(<p>)); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(hb));
    const bx = &hb.file.exprs;
    const both = try analogRhs(hb);
    const v = bx.lhs(both);
    try std.testing.expectEqual(Ast.ExprTag.branch_access, bx.tag(v));
    try std.testing.expectEqual(Ast.branch_ref_hier_unnamed, bx.extraOf(v));
    const hi = bx.nameParts(bx.lhs(v));
    try std.testing.expectEqual(@as(usize, 3), hi.len);
    try std.testing.expectEqualStrings("top", hb.file.str(hi[0]));
    try std.testing.expectEqualStrings("a", hb.file.str(hi[2]));
    const pa = bx.rhs(both);
    try std.testing.expectEqual(Ast.ExprTag.port_access, bx.tag(pa));
    try std.testing.expectEqual(@as(usize, 2), bx.nameParts(bx.lhs(pa)).len);

    // A.2.5 value_range_expression `inf` as a primary.
    const inf = try parseForTest(arena, "module m; parameter real x = inf; endmodule");
    try std.testing.expectEqual(Ast.ExprTag.pos_inf, inf.file.exprs.tag(inf.file.modules[0].params[0].default));

    // A.6.9 a system task keeps an omitted argument as `.none`.
    const task = try parseForTest(arena, "module m; analog $strobe(\"a\", , 1); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(task));
    const st = task.file.stmt(task.file.modules[0].analog[0].body).sys_task;
    try std.testing.expectEqual(@as(usize, 3), st.args.len);
    try std.testing.expectEqual(Ast.ExprId.none, st.args[1]);

    // A token that begins no primary.
    try expectFirstErrors(arena, &.{
        .{ .src = "module m; integer x; analog x = ; endmodule", .code = .E0209 },
        .{ .src = "module m; integer x; analog x = 1; endmodule", .code = null },
    }, false);
}

test "A.6.4/A.6.5 statements: digital forms refused in analog by clause, kept in a discrete body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const head = "module m; integer x; reg c; event e; ";
    try expectFirstErrors(arena, &.{
        // A.6.4 has none of A.6.5's digital statements; each is parsed in
        // full and refused by its own code, so the block still parses.
        .{ .src = head ++ "analog begin wait (x) x = 1; end endmodule", .code = .E0255 },
        .{ .src = head ++ "analog begin force x = 1; end endmodule", .code = .E0258 },
        .{ .src = head ++ "analog begin release x; end endmodule", .code = .E0258 },
        .{ .src = head ++ "analog begin fork join end endmodule", .code = .E0249 },
        // In an initial or always body the same text is grammar (§7.2.2).
        .{ .src = head ++ "initial begin wait (x) x = 1; force x = 1; release x; fork join end endmodule", .code = null },
        // A.6.10 / §5.7: an lvalue is followed by `<+`, `=` or `:`.
        .{ .src = head ++ "analog x; endmodule", .code = .E0214 },
        // A.6.5 `disable` and `->`, and a case whose `default` has no colon.
        .{ .src = head ++ "initial begin disable a.b; -> e; end endmodule", .code = null },
        .{ .src = head ++ "analog case (x) default x = 1; endcase endmodule", .code = null },
        // IEEE 1364-2005 §15.1: "no timing check can appear in procedural code".
        .{ .src = head ++ "initial $setup(x, c, 1); endmodule", .code = .E0207 },
        // §9.22: driver_update belongs to a connect module.
        .{ .src = "module m; wire w; always @(driver_update w) ; endmodule", .code = .E0818 },
        .{ .src = "connectmodule c(w); input w; always @(driver_update w) ; endmodule", .code = null },
        // IEEE 1364-2005 A.6.2: `initial` takes a statement, never a null one.
        .{ .src = head ++ "initial ; endmodule", .code = .E0219 },
    }, false);
    try expectFirstErrors(arena, &.{
        .{ .src = "module m; initial ; endmodule", .code = .E0209 },
    }, true);

    // §9.3 procedural continuous assignments keep their kind; deassign and
    // release have no value.
    const pc = try parseForTest(arena, head ++ "initial begin force x = 1; release x; end endmodule");
    const blk = pc.file.stmt(pc.file.modules[0].discrete[0].body).block;
    try std.testing.expect(pc.file.stmt(blk.body[0]).assign.continuous == .force);
    try std.testing.expect(pc.file.stmt(blk.body[1]).assign.continuous == .release);
    try std.testing.expectEqual(Ast.ExprId.none, pc.file.stmt(blk.body[1]).assign.value);

    // A.6.5 `event_control ::= ... | @* | @ (*)`: the attribute tokens split
    // `(*)` three ways, and every spelling records no expression.
    for ([_][]const u8{ "@*", "@(*)", "@( *)", "@( * )" }) |spelling| {
        const src = try arena.print("{s}initial {s} x = 1; endmodule", .{ head, spelling });
        const r = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(?diag.Code, null), firstError(r));
        const ev = r.file.stmt(r.file.modules[0].discrete[0].body).event_control;
        try std.testing.expectEqual(Ast.ExprId.none, ev.event);
    }

    // A.6.5 intra-assignment `repeat ( n ) @ ( ... )`, and `<= @*`.
    const intra = try parseForTest(arena, head ++ "initial begin x = repeat (2) @(posedge c) 1; x <= @* 2; end endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(intra));
    const ib = intra.file.stmt(intra.file.modules[0].discrete[0].body).block;
    const rep = intra.file.stmt(ib.body[0]).assign;
    try std.testing.expect(rep.timing_repeat != .none);
    try std.testing.expect(rep.timing != .none);
    try std.testing.expect(!rep.timing_is_delay);
    const nba = intra.file.stmt(ib.body[1]).assign;
    try std.testing.expect(nba.nonblocking);
    try std.testing.expect(nba.timing_implicit);
}

test "A.1.3 module headers: parameter port lists, port styles and their refusals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectFirstErrors(arena, &.{
        // A.1.3 `module_parameter_port_list ::= # ( parameter_declaration
        // { , parameter_declaration } )`: `parameter`, at least one.
        .{ .src = "module m #(localparam a = 1) (); endmodule", .code = .E0246 },
        .{ .src = "module m #() (); endmodule", .code = .E0246 },
        .{ .src = "module m #(parameter a = 1, parameter b = 2) (); endmodule", .code = null },
        // §6.2: a list_of_port_declarations port "shall not be redeclared".
        .{ .src = "module m(input a); input a; endmodule", .code = .E0218 },
        // §6.5.2: a body direction names a header port.
        .{ .src = "module m(a); input z; endmodule", .code = .E0206 },
        // A.1.3: no port_declaration after a list_of_ports entry.
        .{ .src = "module m(a, input b); endmodule", .code = .E0207 },
        // Syntax 6-8: `begin` opens a generate block, never a module item.
        .{ .src = "module m; begin end endmodule", .code = .E0221 },
        // A token that begins no A.1.4 module_item.
        .{ .src = "module m; foo; endmodule", .code = .E0240 },
        .{ .src = "module m; endgenerate endmodule", .code = .E0240 },
    }, false);

    // IEEE 1364-2005 §4.10.1: with a header list, the body's parameters
    // "become local parameters".
    const hp = try parseForTest(arena, "module m #(parameter a = 1) (); parameter b = 2; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(hp));
    const params = hp.file.modules[0].params;
    try std.testing.expect(!params[0].is_local);
    try std.testing.expect(params[1].is_local);

    // IEEE 1364-2005 §12.3.3: one declaration covers every reference to a name.
    const twice = try parseForTest(arena, "module m(a, a); input a; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(twice));
    try std.testing.expectEqual(Ast.Direction.input, twice.file.modules[0].ports[1].direction);
    // Interleaved, each repeat takes its own name's first declaration.
    const mixed = try parseForTest(arena, "module m(a, b, a, b); input a; output b; electrical a; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(mixed));
    const mp = mixed.file.modules[0].ports;
    try std.testing.expectEqual(Ast.Direction.input, mp[2].direction);
    try std.testing.expectEqual(mp[0].discipline, mp[2].discipline);
    try std.testing.expectEqual(Ast.Direction.output, mp[3].direction);
    try std.testing.expectEqual(Ast.StrId.none, mp[3].discipline);

    // A.1.3 `. port_identifier ( [ port_expression ] )`: an external name over
    // one net, or over a concatenation's nets (§6.5.1).
    const named = try parseForTest(arena, "module m(.x(a), .y({b, c})); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(named));
    const ports = named.file.modules[0].ports;
    try std.testing.expectEqual(@as(usize, 3), ports.len);
    try std.testing.expectEqualStrings("a", named.file.str(ports[0].name));
    try std.testing.expectEqualStrings("x", named.file.str(ports[0].connName()));
    try std.testing.expect(!ports[1].concat_rest);
    try std.testing.expect(ports[2].concat_rest);
    try std.testing.expectEqualStrings("y", named.file.str(ports[2].connName()));

    // A.2.1.2's variable arm, `output reg`, with A.2.3's initializer.
    const vp = try parseForTest(arena, "module m(q); output reg [3:0] q = 0; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(vp));
    const v = vp.file.modules[0].vars[0];
    try std.testing.expect(v.storage == .reg);
    try std.testing.expect(v.init != .none);
    try std.testing.expect(v.packed_range != null);
    try std.testing.expectEqual(Ast.Direction.output, vp.file.modules[0].ports[0].direction);
    // ...which only `output` has.
    try expectFirstErrors(arena, &.{
        .{ .src = "module m(x); input integer x; endmodule", .code = .E0207 },
    }, false);
}

test "A.1.4 module items: nets, assigns, defparams, regs, and the identifier dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectFirstErrors(arena, &.{
        // IEEE 1364-2005 §4.3.2: scalared/vectored only with a range.
        .{ .src = "module m; wire scalared w; endmodule", .code = .E0207 },
        .{ .src = "module m; wire scalared [3:0] w; endmodule", .code = null },
        // §6.1.4: "(highz1, highz0) and (highz0, highz1) shall be treated as
        // illegal constructs"; A.2.2.2 pairs one 0-side with one 1-side.
        .{ .src = "module m; wire a; wire (highz0, highz1) w = a; endmodule", .code = .E0207 },
        .{ .src = "module m; wire a; wire (strong0, pull0) w = a; endmodule", .code = .E0207 },
        .{ .src = "module m; wire a; wire (small, strong1) w = a; endmodule", .code = .E0207 },
        // §4.4: a drive strength only with a net declaration assignment.
        .{ .src = "module m; wire (strong0, strong1) w; endmodule", .code = .E0207 },
        // A.2.1.3: a charge strength is `trireg`'s alone, and a charge word.
        .{ .src = "module m; wire (small) w; endmodule", .code = .E0257 },
        .{ .src = "module m; trireg (strong0) t; endmodule", .code = .E0257 },
        .{ .src = "module m; trireg (foo) t; endmodule", .code = .E0207 },
        // A.2.2.3 `delay3` has at most three values (E0210 at the fourth).
        .{ .src = "module m; wire #(1, 2, 3, 4) w; endmodule", .code = .E0210 },
        // An analog compilation has no array of nodes (IEEE 1364-2005 §4.9.1).
        // (`electrical n[0:3];` alone is an instance of module `electrical`:
        // the identifier dispatch reads `ident ident [` as A.4.1's.)
        .{ .src = "module m; wire n[0:3]; endmodule", .code = .E0205 },
        .{ .src = "module m; electrical a, n[0:3]; endmodule", .code = .E0205 },
        // §6.3.1 / A.9.3: an index that does not fold, in an analog parse.
        .{ .src = "module m; defparam u[k].x = 1; endmodule", .code = .E0231 },
    }, false);
    // The digital engine has net arrays, and folds a defparam index itself.
    try expectFirstErrors(arena, &.{
        .{ .src = "module m; wire n[0:3]; endmodule", .code = null },
        .{ .src = "module m; defparam u[k].x = 1; endmodule", .code = null },
    }, true);

    const nets = try parseForTest(arena, "module m; wire a; wire (pull1, weak0) w = a; trireg (large) t; wire #(1, 2, 3) d3; wire #5 d1; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(nets));
    const n = nets.file.modules[0].nets;
    try std.testing.expectEqual(@as(usize, 5), n.len);
    // Either order of a drive strength pair lands on its own side.
    try std.testing.expectEqual(Ast.Strength.weak, n[1].strength0);
    try std.testing.expectEqual(Ast.Strength.pull, n[1].strength1);
    try std.testing.expectEqual(Ast.Strength.large, n[2].charge);
    try std.testing.expect(n[3].delay.off != .none);
    // IEEE 1364-2005 §7.14: one value is every transition.
    try std.testing.expectEqual(n[4].delay.rise, n[4].delay.fall);
    try std.testing.expectEqual(n[4].delay.rise, n[4].delay.off);

    // A.2.2.3 `delay_value ::= ... | identifier`: a name, not a call on the
    // terminal list after it.
    const gate = try parseForTest(arena, "module m; parameter d = 2; wire g, i; buf #d (g, i); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(gate));
    try std.testing.expectEqual(Ast.ExprTag.ident, gate.file.exprs.nodes.items(.tag)[@backingInt(gate.file.modules[0].gates[0].delay.rise)]);

    // A.6.1 `assign [ drive_strength ] [ delay3 ]`: two values leave `off`
    // for evaluation (§7.14), not for the syntax.
    const asg = try parseForTest(arena, "module m; wire w, a; assign (weak0, pull1) #(1, 2) w = a; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(asg));
    const ca = asg.file.modules[0].assigns[0];
    try std.testing.expectEqual(Ast.Strength.weak, ca.strength0);
    try std.testing.expectEqual(Ast.Strength.pull, ca.strength1);
    try std.testing.expect(ca.delay.rise != .none and ca.delay.fall != ca.delay.rise);
    try std.testing.expectEqual(Ast.ExprId.none, ca.delay.off);

    // §6.3.1 defparam paths, a list of them, and a literal instance index.
    const dp = try parseForTest(arena, "module m; defparam u.x = 1, v.y = 2; defparam w[0].z = 3; defparam u.$xposition = 4; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(dp));
    const defs = dp.file.modules[0].defparams;
    try std.testing.expectEqual(@as(usize, 4), defs.len);
    try std.testing.expectEqualStrings("u.x", dp.file.str(defs[0].path));
    try std.testing.expectEqualStrings("v.y", dp.file.str(defs[1].path));
    try std.testing.expectEqualStrings("w[0].z", dp.file.str(defs[2].path));
    try std.testing.expectEqualStrings("u.$xposition", dp.file.str(defs[3].path));
    const ddp = try parseDigitalForTest(arena, "module m; defparam u[k].x = 1; endmodule");
    try std.testing.expectEqualStrings("u[].x", ddp.file.str(ddp.file.modules[0].defparams[0].path));
    try std.testing.expectEqual(@as(usize, 1), ddp.file.modules[0].defparams[0].indices.len);

    // A.2.1.3 `reg [ discipline_identifier ] ...` completes a header port's
    // discipline; a name then `[` is an array, not a discipline.
    const regs = try parseForTest(arena, "module m(p); output p; reg electrical p; reg r[0:3]; reg signed [7:0] a = 1, b; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(regs));
    const rm = regs.file.modules[0];
    try std.testing.expectEqualStrings("electrical", regs.file.str(rm.ports[0].discipline));
    try std.testing.expectEqual(@as(usize, 4), rm.vars.len);
    try std.testing.expectEqual(@as(usize, 1), rm.vars[1].dims.len);
    try std.testing.expect(rm.vars[2].is_signed and rm.vars[2].init != .none);
    try std.testing.expect(rm.vars[3].packed_range != null and rm.vars[3].init == .none);

    // A net type on a header port completes it (§7.9 resolves by it).
    const tri = try parseForTest(arena, "module m(p); inout p; tri0 p; endmodule");
    try std.testing.expectEqual(Ast.NetKind.tri0, tri.file.modules[0].ports[0].kind);
    try std.testing.expectEqual(@as(usize, 0), tri.file.modules[0].nets.len);

    // The identifier dispatch: `d n;` declares, `$root.` roots an Annex F.2.1
    // out-of-context declaration, `u #5 (...)` is A.5.4's.
    const ids = try parseForTest(arena, "module m; foo bar; electrical $root.top.n; u #5 g1(a, b); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(ids));
    const im = ids.file.modules[0];
    try std.testing.expectEqualStrings("foo", ids.file.str(im.nets[0].discipline));
    try std.testing.expectEqualStrings("$root.top.n", ids.file.str(im.nets[1].name));
    // An analog compile keeps no UDP instance (W0252).
    try std.testing.expectEqual(@as(usize, 0), im.instances.len);

    // §3.12 branches: a port branch, and a ranged branch array.
    const br = try parseForTest(arena, "module m(p, a, b); inout p, a, b; electrical p, a, b; branch (<p>) pb; branch (a, b) bb[0:3]; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(br));
    const bs = br.file.modules[0].branches;
    try std.testing.expect(bs[0].is_port_branch and bs[0].lo == .none);
    try std.testing.expect(!bs[1].is_port_branch and bs[1].range != null);
}

test "A.2.1.1/A.2.5 declarations: value ranges, packed ranges, aliasparams, variables" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // §3.4.2: `[` and `]` include, `(` and `)` exclude; `exclude` alone takes
    // a bare value; `-inf` and `inf` bound the open ends.
    const vr = try parseForTest(arena, "module m; parameter real a = 1 from [0:inf) exclude (2:3) exclude 5 from (-inf:0] exclude (7); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(vr));
    const ex = &vr.file.exprs;
    const rg = vr.file.modules[0].params[0].ranges;
    try std.testing.expectEqual(@as(usize, 5), rg.len);
    try std.testing.expect(rg[0].kind == .from and rg[0].lo_inclusive and !rg[0].hi_inclusive);
    try std.testing.expectEqual(Ast.ExprTag.pos_inf, ex.tag(rg[0].hi));
    try std.testing.expect(rg[1].kind == .exclude and !rg[1].lo_inclusive and !rg[1].hi_inclusive);
    try std.testing.expect(rg[2].kind == .exclude and rg[2].hi == .none);
    try std.testing.expect(!rg[3].lo_inclusive and rg[3].hi_inclusive);
    try std.testing.expectEqual(Ast.ExprTag.neg_inf, ex.tag(rg[3].lo));
    // `exclude ( expr )` is one value, not a range.
    try std.testing.expect(rg[4].hi == .none);

    // A string-set range (§3.4.2).
    const ss = try parseForTest(arena, "module m; parameter string s = \"a\" from '{\"a\", \"b\"}; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(ss));
    const sr = ss.file.modules[0].params[0].ranges[0];
    try std.testing.expect(sr.strings != null and sr.lo == .none);

    try expectFirstErrors(arena, &.{
        // A value_range closes with `]` or `)` and nothing else.
        .{ .src = "module m; parameter real a = 1 from [0:1; endmodule", .code = .E0210 },
        // A.2.1.1 `parameter [ signed ] [ range ]`: a width, no type.
        .{ .src = "module m; parameter [3:0] p = 3; endmodule", .code = null },
        // §3.4.7 prints `aliasparam m = $mfactor;`.
        .{ .src = "module m; parameter real r = 1; aliasparam m2 = $mfactor; endmodule", .code = null },
    }, false);

    const pr = try parseForTest(arena, "module m; parameter [3:0] p = 3; string s = \"x\"; time t; realtime rt; endmodule");
    const pm = pr.file.modules[0];
    try std.testing.expect(pm.params[0].packed_range != null);
    try std.testing.expectEqual(Ast.Type.unspecified, pm.params[0].ty);
    // §3.4.1: `time` folds to integer storage, `realtime` to real.
    try std.testing.expectEqual(Ast.Type.string, pm.vars[0].ty);
    try std.testing.expect(pm.vars[1].storage == .time and pm.vars[1].ty == .integer);
    try std.testing.expectEqual(Ast.Type.real, pm.vars[2].ty);
}

test "§6.6 generate: genblk<n> naming, its zero padding, direct nesting, and genvar loops" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // §6.6.3: "genblk<n> where <n> is the assigned number. If such a name
    // would conflict with an explicitly declared name, leading zeroes are
    // added until the name does not conflict." The declaration may follow.
    const r = try parseForTest(arena, "module m; if (1) begin end if (1) begin end if (1) begin : g end real genblk1; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(r));
    const m = r.file.modules[0];
    const names = [_][]const u8{ "genblk01", "genblk2", "g" };
    for (names, 0..) |want, i| {
        const then_s = r.file.stmt(m.analog[i].body).if_stmt.then_s;
        try std.testing.expectEqualStrings(want, r.file.str(r.file.stmt(then_s).block.gen_name));
    }

    // §6.6.2 direct nesting: the `else if` block is no scope, and the inner
    // construct's block is named as the outer construct's (number 1).
    const d = try parseForTest(arena, "module m; if (1) begin end else if (1) begin end endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(d));
    const outer = d.file.stmt(d.file.modules[0].analog[0].body).if_stmt;
    try std.testing.expectEqualStrings("genblk1", d.file.str(d.file.stmt(outer.then_s).block.gen_name));
    const direct = d.file.stmt(outer.else_s).block;
    try std.testing.expectEqual(Ast.StrId.none, direct.gen_name);
    const inner = d.file.stmt(direct.body[0]).if_stmt;
    try std.testing.expectEqualStrings("genblk1", d.file.str(d.file.stmt(inner.then_s).block.gen_name));

    try expectFirstErrors(arena, &.{
        // A.4.2 `genvar_initialization ::= genvar_identifier = ...`.
        .{ .src = "module m; for (i = 0; i < 2; i = i + 1) begin end endmodule", .code = .E0238 },
        .{ .src = "module m; genvar i; for (i = 0; i < 2; i = i + 1) begin end endmodule", .code = null },
        // A task in a generate block has no home in the analog parse (E0235).
        .{ .src = "module m; generate if (1) begin task t; begin end endtask end endgenerate endmodule", .code = .E0235 },
    }, false);
    // The digital parse keeps it on the block (IEEE 1364-2005 A.1.5).
    try expectFirstErrors(arena, &.{
        .{ .src = "module m; generate if (1) begin task t; begin end endtask end endgenerate endmodule", .code = null },
    }, true);
}

test "A.1.1/A.1.2/A.1.5 descriptions: library text refused, configurations read, recovery to the next description" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectFirstErrors(arena, &.{
        // A.1.1's two library_descriptions belong to library_text (E0232),
        // and the production is walked first.
        .{ .src = "library lib \"a.v\", \"b.v\" -incdir \"inc\";", .code = .E0232 },
        .{ .src = "include \"x.v\";", .code = .E0232 },
        .{ .src = "library lib \"a.v\" -foo;", .code = .E0207 },
        // IEEE 1364-2005 §14.1: a specify block "shall appear inside a module".
        .{ .src = "specify endspecify", .code = .E0245 },
        // Annex B words and keywords that begin no description.
        .{ .src = "table", .code = .E0201 },
        .{ .src = "endmodule", .code = .E0201 },
        // IEEE 1364-2005 §13.3.1.2: one default clause per configuration.
        .{ .src = "config c; design top; default liblist a; default liblist b; endconfig", .code = .E0243 },
        // §13.3.1.4: a cell clause naming a library takes `use`.
        .{ .src = "config c; design top; cell lib.x liblist a; endconfig", .code = .E0243 },
        // A.1.5: the design statement comes first, and endconfig closes.
        .{ .src = "config c; default liblist a; endconfig", .code = .E0207 },
        .{ .src = "config c; design top;", .code = .E0207 },
        // `use ... : config` is the literal keyword.
        .{ .src = "config c; design top; instance top.u use lib.x : foo; endconfig", .code = .E0207 },
    }, false);

    const cfg = try parseForTest(arena,
        \\config cfg;
        \\  design work.top;
        \\  default liblist work lib2;
        \\  instance top.u1 use lib2.cell1 : config;
        \\  cell c2 liblist lib3;
        \\endconfig
        \\module top; endmodule
    );
    // An analog compile binds nothing through it and says so (W0253).
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(cfg));
    try std.testing.expectEqual(@as(usize, 1), cfg.file.configs.len);
    const c = cfg.file.configs[0];
    try std.testing.expectEqualStrings("work", cfg.file.str(c.design[0].lib));
    try std.testing.expectEqualStrings("top", cfg.file.str(c.design[0].cell));
    try std.testing.expectEqual(@as(usize, 3), c.rules.len);
    try std.testing.expect(c.rules[0].select == .default);
    try std.testing.expectEqual(@as(usize, 2), c.rules[0].expand.liblist.len);
    try std.testing.expectEqualStrings("top.u1", cfg.file.str(c.rules[1].select.instance));
    try std.testing.expect(c.rules[1].expand.use.config);
    try std.testing.expectEqualStrings("lib2", cfg.file.str(c.rules[1].expand.use.lib));
    try std.testing.expectEqualStrings("c2", cfg.file.str(c.rules[2].select.cell.cell));
    var w0253 = false;
    for (0..cfg.count()) |i| w0253 = w0253 or cfg.code(i) == .W0253;
    try std.testing.expect(w0253);

    // A bad description costs only itself: the module after it parses.
    const rec = try parseForTest(arena, "junk junk; module b; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, .E0201), firstError(rec));
    try std.testing.expectEqual(@as(usize, 1), rec.file.modules.len);

    // §2.7 Table 2-2: an octal escape above \377 is an error, an unlisted
    // escape a warning that leaves the file accepted.
    try expectFirstErrors(arena, &.{
        .{ .src = "module m; analog $strobe(\"\\777\"); endmodule", .code = .E0148 },
        .{ .src = "module m; analog $strobe(\"\\q\"); endmodule", .code = null },
    }, false);

    // §3.3: an analog string ignores every \0; a digital one keeps it (§9.4.2).
    const nul = "module m; analog $strobe(\"a\\000b\"); endmodule";
    const an = try parseForTest(arena, nul);
    const asys = an.file.stmt(an.file.modules[0].analog[0].body).sys_task;
    try std.testing.expectEqualStrings("ab", an.file.str(an.file.exprs.strOf(asys.args[0])));
    const dg = try parseDigitalForTest(arena, nul);
    const ds = dg.file.stmt(dg.file.modules[0].analog[0].body).sys_task;
    try std.testing.expectEqualStrings("a\x00b", dg.file.str(dg.file.exprs.strOf(ds.args[0])));
}

test "A.5 UDPs: entry shapes, symbol alphabets, input caps and §8.1.4 conflicts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const comb = "primitive u(q, a); output q; input a; table ";
    const seq = "primitive u(q, a); output q; reg q; input a; table ";
    const tail = " endtable endprimitive";
    try expectFirstErrors(arena, &.{
        // A.5.3: one colon (combinational) or two (sequential).
        .{ .src = comb ++ "0;" ++ tail, .code = .E0234 },
        .{ .src = seq ++ "0 : 1 : 1 : 1;" ++ tail, .code = .E0234 },
        // level_symbol / output_symbol alphabets.
        .{ .src = comb ++ "q : 1;" ++ tail, .code = .E0233 },
        .{ .src = comb ++ "0 : 2;" ++ tail, .code = .E0233 },
        .{ .src = comb ++ "0 : 01;" ++ tail, .code = .E0233 },
        // `-` is a next_state, which only a sequential entry has.
        .{ .src = comb ++ "0 : -;" ++ tail, .code = .E0233 },
        .{ .src = seq ++ "0 : 0 : -;" ++ tail, .code = null },
        // An edge reaches edge_input_list only from a sequential_entry.
        .{ .src = comb ++ "r : 1;" ++ tail, .code = .E0234 },
        // current_state ::= level_symbol.
        .{ .src = seq ++ "0 : r : 1;" ++ tail, .code = .E0233 },
        // A.5.1 closes with endprimitive and A.5.3's body is a table.
        .{ .src = comb ++ "0 : 0; endtable", .code = .E0207 },
        .{ .src = "primitive u(q, a); output q; input a; endprimitive", .code = .E0207 },
        // IEEE 1364-2005 §8.1.4: "It is illegal to have the same combination
        // of inputs, including edges, specified for different outputs."
        .{ .src = comb ++ "0 : 0; 0 : 1;" ++ tail, .code = .E0248 },
        .{ .src = comb ++ "? : 0; 1 : 1;" ++ tail, .code = .E0248 },
        .{ .src = comb ++ "? : 0; 1 : 0;" ++ tail, .code = null },
        .{ .src = comb ++ "0 : 0; 1 : 1;" ++ tail, .code = null },
        // `-` reads as the current state: (0, 0) -> 0 twice agrees, (0, 1)
        // -> 1 and 0 does not.
        .{ .src = seq ++ "0 : 0 : -; 0 : 0 : 0;" ++ tail, .code = null },
        .{ .src = seq ++ "0 : 1 : -; 0 : 1 : 0;" ++ tail, .code = .E0248 },
        // §8.8: a level entry dominates an edge entry, so they never conflict.
        .{ .src = seq ++ "r : ? : 1; 1 : ? : 0;" ++ tail, .code = null },
    }, false);

    // No input-count cap (E1017 retired): 65 inputs, one past the old cap of
    // 64, and 1000, each with a full-width row and a conflicting pair, so the
    // §8.1.4 check runs over every column of a wide table too.
    for ([_]usize{ 65, 1000 }) |n| {
        var wide: std.ArrayList(u8) = .empty;
        try wide.appendSlice(arena, "primitive u(q");
        for (0..n) |i| try wide.print(arena, ", i{d}", .{i});
        try wide.appendSlice(arena, "); output q; input");
        for (0..n) |i| try wide.print(arena, "{s} i{d}", .{ if (i == 0) "" else ",", i });
        try wide.appendSlice(arena, "; table ");
        try wide.appendNTimes(arena, '0', n);
        try wide.appendSlice(arena, " : 0; ");
        const ok_len = wide.items.len;
        try wide.appendNTimes(arena, '?', n);
        try wide.appendSlice(arena, " : 1; endtable endprimitive");
        const r = try parseForTest(arena, wide.items);
        try std.testing.expectEqual(@as(?diag.Code, .E0248), firstError(r));
        try std.testing.expectEqual(@as(?diag.Code, null), firstError(try parseForTest(arena, try std.mem.concat(arena, u8, &.{ wide.items[0..ok_len], "endtable endprimitive" }))));
        try std.testing.expectEqual(n + 1, (try parseForTest(arena, try std.mem.concat(arena, u8, &.{ wide.items[0..ok_len], "endtable endprimitive" }))).file.udps[0].ports.len);
    }

    // A.5.4: a UDP instance's delay2 has no third value (E0239).
    // (`u #(...) g(...)` is A.4.1's parameter_value_assignment until
    // elaboration resolves `u`; a strength first makes it A.5.4's.)
    const udp = "primitive u(q, a, b); output q; input a, b; table 0 0 : 0; endtable endprimitive ";
    try expectFirstErrors(arena, &.{
        .{ .src = udp ++ "module m; wire q, a, b; u (strong0, weak1) #(1, 2, 3) g(q, a, b); endmodule", .code = .E0239 },
        .{ .src = udp ++ "module m; wire q, a, b; u (strong0, weak1) #(1, 2) g(q, a, b); endmodule", .code = null },
    }, false);
    // A digital parse keeps the instance with its strengths.
    const d = try parseDigitalForTest(arena, udp ++ "module m; wire q, a, b; u (strong0, weak1) g(q, a, b); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(d));
    try std.testing.expectEqual(@as(usize, 1), d.file.modules[0].instances.len);
    try std.testing.expectEqual(Ast.Strength.weak, d.file.modules[0].instances[0].strength1);
}

test "A.7 specify: path forms, delay counts, clause 14 rules and timing checks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try parseForTest(arena,
        \\module m(input a, input b, input clk, input en, input d, output y, output q);
        \\  specify
        \\    (a => y) = 1;
        \\    (a, b *> y) = (1, 2);
        \\    (posedge clk => (q +: d)) = 1;
        \\    if (en) (b => y) = 1;
        \\    ifnone (a => q) = 1;
        \\    (b => q) = (1, 2, 3, 4, 5, 6);
        \\  endspecify
        \\endmodule
    );
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(paths));
    const ps = paths.file.modules[0].paths;
    try std.testing.expectEqual(@as(usize, 6), ps.len);
    try std.testing.expect(!ps[0].full);
    try std.testing.expect(ps[1].full and ps[1].ins.len == 2 and ps[1].delays.len == 2);
    try std.testing.expect(ps[2].edge == .posedge and ps[2].data != .none and ps[2].data_polarity == .positive);
    try std.testing.expect(ps[3].cond != .none);
    try std.testing.expect(ps[4].ifnone);
    try std.testing.expectEqual(@as(usize, 6), ps[5].delays.len);

    const head = "module m(input a, input b, input clk, output y); ";
    try expectFirstErrors(arena, &.{
        // A.7.4: 1, 2, 3, 6 or 12 delays.
        .{ .src = head ++ "specify (a => y) = (1, 2, 3, 4); endspecify endmodule", .code = .E0207 },
        // A.7.2: `=>` joins one source to one destination.
        .{ .src = head ++ "specify (a, b => y) = 1; endspecify endmodule", .code = .E0207 },
        // A.7.2: `=>` or `*>`.
        .{ .src = head ++ "specify (a y) = 1; endspecify endmodule", .code = .E0207 },
        // §14.2.1 sources and destinations.
        .{ .src = "module m(output a, output y); specify (a => y) = 1; endspecify endmodule", .code = .E0245 },
        .{ .src = "module m(input a, input y); specify (a => y) = 1; endspecify endmodule", .code = .E0245 },
        .{ .src = head ++ "assign y = a; assign y = b; specify (a => y) = 1; endspecify endmodule", .code = .E0245 },
        // §14.2.5: a parallel path joins equal widths.
        .{ .src = "module m(input [3:0] a, output y); specify (a => y) = 1; endspecify endmodule", .code = .E0245 },
        .{ .src = "module m(input [3:0] a, output [0:3] y); specify (a => y) = 1; endspecify endmodule", .code = null },
        // §14.3: a path delay is a constant expression.
        .{ .src = head ++ "specify (a => y) = a; endspecify endmodule", .code = .E0245 },
        // §14.2.4.4: not ifnone beside an unconditional path for one path.
        .{ .src = head ++ "specify (a => y) = 1; ifnone (a => y) = 2; endspecify endmodule", .code = .E0245 },
        .{ .src = head ++ "specify if (b) (a => y) = 1; ifnone (a => y) = 2; endspecify endmodule", .code = null },
        // Table 14-1's operators only.
        .{ .src = head ++ "specify if (a + b) (a => y) = 1; endspecify endmodule", .code = .E0245 },
        // Syntax 14-5 / 14-4: ifnone takes a simple path, and an edge path's
        // polarity follows its destination.
        .{ .src = head ++ "specify ifnone (posedge clk => (y : a)) = 1; endspecify endmodule", .code = .E0245 },
        .{ .src = head ++ "specify (posedge clk + => (y : a)) = 1; endspecify endmodule", .code = .E0245 },
        // A.7.1: no other specify_item.
        .{ .src = head ++ "specify y = 1; endspecify endmodule", .code = .E0207 },
        .{ .src = head ++ "specify (a => y) = 1;", .code = .E0207 },
    }, false);

    const tc = "module m(input d, input clk, input en); reg notif; specify ";
    try expectFirstErrors(arena, &.{
        .{ .src = tc ++ "$setup(d, posedge clk &&& en, 1); $hold(posedge clk, d, 1, notif); endspecify endmodule", .code = null },
        // A.7.5.1 arities.
        .{ .src = tc ++ "$setup(d, clk); endspecify endmodule", .code = .E0207 },
        .{ .src = tc ++ "$setup(d, clk, 1, notif, 2); endspecify endmodule", .code = .E0207 },
        // A.7.5.3: a controlled_reference_event needs its event control.
        .{ .src = tc ++ "$width(clk, 1); endspecify endmodule", .code = .E0207 },
        // §15.3.4: no notifier without a non-null threshold.
        .{ .src = tc ++ "$width(negedge clk, 1, , notif); endspecify endmodule", .code = .E0207 },
        .{ .src = tc ++ "$width(negedge clk, 1, 0, notif); endspecify endmodule", .code = null },
        // A.7.5.2 `notifier ::= variable_identifier`.
        .{ .src = tc ++ "$hold(posedge clk, d, 1, 5); endspecify endmodule", .code = .E0207 },
        // Only the event arguments take an event control.
        .{ .src = tc ++ "$setup(d, posedge clk, posedge en); endspecify endmodule", .code = .E0207 },
        // A.7.1 admits A.7.5.1's twelve commands and no other system task.
        .{ .src = tc ++ "$foo(d); endspecify endmodule", .code = .E0207 },
        // A.7.5.3 edge descriptors, and the brackets edge needs.
        .{ .src = tc ++ "$period(edge [01, 1x] clk, 5); endspecify endmodule", .code = null },
        .{ .src = tc ++ "$period(edge [2x] clk, 5); endspecify endmodule", .code = .E0207 },
        .{ .src = tc ++ "$period(edge clk, 5); endspecify endmodule", .code = .E0207 },
    }, false);

    // The edge descriptors become the transition mask.
    const edge = try parseForTest(arena, tc ++ "$period(edge [01, 1x] clk, 5); endspecify endmodule");
    const mask = edge.file.modules[0].timing_checks[0].masks[0];
    try std.testing.expectEqual(Ast.TimingCheck.transition('0', '1') | Ast.TimingCheck.transition('1', 'x'), mask);

    // The analog solver evaluates no timing check, so an analog compile names each (W0251).
    const named = try parseForTest(arena, tc ++ "$setup(d, posedge clk, 1); $hold(posedge clk, d, 1); endspecify endmodule");
    var w0251: ?[]const u8 = null;
    for (0..named.count()) |i| if (named.code(i) == .W0251) {
        w0251 = named.msg(i);
    };
    try std.testing.expectEqualStrings("$setup, $hold never evaluated by the analog solver", w0251.?);

    // A.2.1.1 specparams become local constants; A.2.4's PATHPULSE$ declares none.
    const sp = try parseForTest(arena, "module m; specparam [3:0] s = 2, PATHPULSE$ = (1, 2); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(sp));
    const spp = sp.file.modules[0].params;
    try std.testing.expectEqual(@as(usize, 1), spp.len);
    try std.testing.expect(spp[0].is_spec and spp[0].is_local and spp[0].packed_range != null);
}

test "A.4.1/A.3 instances: connections, overrides, gates, pulls and switches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // §6.2.2: a blank ordered connection still holds its position, and a named
    // one may be empty; §9.18's `.$mfactor` is a parameter name.
    const inst = try parseForTest(arena, "module m; child #(.a(1), .$mfactor(2)) c1(, x, ), c2(.p(), .q(y)); child c3[3:0] (x); endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(inst));
    const is = inst.file.modules[0].instances;
    try std.testing.expectEqual(@as(usize, 3), is.len);
    try std.testing.expectEqual(@as(usize, 3), is[0].ports.len);
    try std.testing.expectEqual(Ast.ExprId.none, is[0].ports[0].expr);
    try std.testing.expect(is[0].ports[1].expr != .none);
    try std.testing.expectEqual(Ast.ExprId.none, is[0].ports[2].expr);
    try std.testing.expectEqualStrings("$mfactor", inst.file.str(is[0].params[1].name));
    // One parameter_value_assignment serves every instance of the statement.
    try std.testing.expectEqual(@as(usize, 2), is[1].params.len);
    try std.testing.expectEqual(Ast.ExprId.none, is[1].ports[0].expr);
    try std.testing.expect(is[2].range != null);

    try expectFirstErrors(arena, &.{
        // A.4.1: a nonempty list, entirely ordered or entirely named.
        .{ .src = "module m; child #(.a(1), 2) c(); endmodule", .code = .E0246 },
        .{ .src = "module m; child #() c(); endmodule", .code = .E0246 },
        // A.3.1 terminal counts and A.3.3's net_lvalue outputs.
        .{ .src = "module m; wire o; and (o); endmodule", .code = .E0209 },
        .{ .src = "module m; wire o, i; bufif0 (o, i); endmodule", .code = .E0209 },
        .{ .src = "module m; wire a, b; and (1, a, b); endmodule", .code = .E0207 },
        .{ .src = "module m; wire o, a; buf (o); endmodule", .code = .E0209 },
        // A.3.2: a single-strength pull names the side the gate pulls toward.
        .{ .src = "module m; wire w; pulldown (strong1) (w); endmodule", .code = .E0207 },
        // A.3.1: a pass switch takes no delay.
        .{ .src = "module m; wire a, b; tran #1 (a, b); endmodule", .code = .E0207 },
        .{ .src = "module m; wire o, i; nmos (o, i); endmodule", .code = .E0209 },
    }, false);

    const gates = try parseForTest(arena, "module m; wire o1, o2, i, o, a, b, w, en; buf b1(o1, o2, i); not (strong0, weak1) n1(o, a); and g[3:0] (o, a, b); pullup (strong1) (w); pullup (weak0, pull1) (w); pulldown (w); rtranif1 #(1, 2) (a, b, en); cmos (o, i, a, b); endmodule");
    // Outside a digital run every primitive warns W0252 and none errs.
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(gates));
    const gm = gates.file.modules[0];
    // buf/not: every terminal but the last is an output, each its own gate.
    try std.testing.expectEqual(@as(usize, 4), gm.gates.len);
    try std.testing.expect(gm.gates[0].out != gm.gates[1].out);
    try std.testing.expectEqual(gm.gates[0].ins[0], gm.gates[1].ins[0]);
    try std.testing.expectEqual(Ast.Strength.strong, gm.gates[2].strength0);
    try std.testing.expectEqual(Ast.Strength.weak, gm.gates[2].strength1);
    try std.testing.expect(gm.gates[3].range != null);
    // §7.8: pull strength by default, the pulled-toward side otherwise.
    try std.testing.expectEqual(Ast.Strength.strong, gm.pulls[0].strength);
    try std.testing.expect(gm.pulls[0].one);
    try std.testing.expectEqual(Ast.Strength.pull, gm.pulls[1].strength);
    try std.testing.expectEqual(Ast.Strength.pull, gm.pulls[2].strength);
    try std.testing.expect(!gm.pulls[2].one);
    try std.testing.expectEqual(Ast.SwitchKind.rtranif1, gm.switches[0].kind);
    try std.testing.expectEqual(@as(usize, 3), gm.switches[0].terms.len);
    try std.testing.expectEqual(@as(usize, 4), gm.switches[1].terms.len);
}

test "A.2.6/A.2.7 subroutines: analog formals, digital functions and tasks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // §4.7.1 Example 3: `inout [0:1] a; real a[0:1];`: the declaration types
    // the formal and leaves no local behind.
    const f = try parseForTest(arena,
        \\module m;
        \\  analog function integer g; input a; integer a; g = a; endfunction
        \\  analog function real f(input x); real x; f = x; endfunction
        \\  analog function real h; inout [0:1] a; real a[0:1]; h = a[0]; endfunction
        \\  function [7:0] dg; input a; dg = a; endfunction
        \\endmodule
    );
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(f));
    const fs = f.file.modules[0].functions;
    try std.testing.expectEqual(@as(usize, 4), fs.len);
    try std.testing.expectEqual(Ast.Type.integer, fs[0].ret_ty);
    try std.testing.expectEqual(Ast.Type.integer, fs[0].args[0].ty);
    try std.testing.expectEqual(@as(usize, 1), fs[1].args.len);
    try std.testing.expectEqual(Ast.Type.real, fs[1].args[0].ty);
    try std.testing.expectEqual(Ast.Direction.inout, fs[2].args[0].direction);
    try std.testing.expectEqual(@as(usize, 1), fs[2].args[0].dims.len);
    try std.testing.expectEqual(@as(usize, 0), fs[2].vars.len);
    // IEEE 1364-2005 A.2.7: an untyped digital formal is a 1-bit reg.
    try std.testing.expect(!fs[3].is_analog);
    try std.testing.expectEqual(Ast.Type.integer, fs[3].args[0].ty);

    // A digital parse reads A.2.7's task and function declarations whole.
    const t = try parseDigitalForTest(arena,
        \\module m;
        \\  task automatic t(input [3:0] a, output reg b); integer i; begin end endtask
        \\  function [7:0] f(input a); f = a; endfunction
        \\endmodule
    );
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(t));
    const ts = t.file.modules[0].tasks;
    try std.testing.expectEqual(@as(usize, 2), ts.len);
    try std.testing.expect(ts[0].automatic and !ts[0].is_function);
    try std.testing.expectEqual(@as(usize, 2), ts[0].ports.len);
    try std.testing.expectEqual(Ast.Direction.output, ts[0].ports[1].direction);
    try std.testing.expect(ts[0].ports[0].v.packed_range != null);
    try std.testing.expectEqual(@as(usize, 1), ts[0].vars.len);
    try std.testing.expect(ts[1].is_function and ts[1].result.packed_range != null);

    try expectFirstErrors(arena, &.{
        .{ .src = "module m; task t; begin end", .code = .E0207 },
    }, true);
}

test "A.1.6-A.1.9 natures, disciplines, paramsets and connectrules: each item and each refusal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectFirstErrors(arena, &.{
        // A.1.6 `parent_nature ::= ... | discipline_identifier . potential_or_flow`.
        .{ .src = "nature N : el.potential; endnature", .code = null },
        .{ .src = "nature N : el.foo; endnature", .code = .E0211 },
        .{ .src = "nature N; 5 = 1; endnature", .code = .E0208 },
        // A.1.7 domain_binding and discipline_item.
        .{ .src = "discipline d; domain foo; enddiscipline", .code = .E0212 },
        .{ .src = "discipline d; x; enddiscipline", .code = .E0213 },
        .{ .src = "discipline d; 5; enddiscipline", .code = .E0213 },
        .{ .src = "discipline d; flow.abstol = 1e-9; domain discrete; enddiscipline", .code = null },
        // A.1.9: at least one paramset_item_declaration.
        .{ .src = "paramset ps mo; endparamset", .code = .E0297 },
        // §6.4.1: no access function, named block or event control.
        .{ .src = "paramset ps mo; real o; o = V(p); endparamset", .code = .E0237 },
        .{ .src = "paramset ps mo; real o; begin : b o = 1; end endparamset", .code = .E0237 },
        .{ .src = "paramset ps mo; real o; garbage; endparamset", .code = .E0205 },
        // §10.6: outside a design element only.
        .{ .src = "paramset ps mo; real o;\n`begin_keywords \"1364-2005\"\nendparamset", .code = .E0202 },
        .{ .src = "connectrules c;\n`begin_keywords \"1364-2005\"\nendconnectrules", .code = .E0202 },
        // §7.8.3: connect_mode is `merged` or `split`.
        .{ .src = "connectrules c; connect a2d foo; endconnectrules", .code = .E0207 },
        .{ .src = "connectrules c; connect a2d output elec, output dig; endconnectrules", .code = .E0207 },
    }, false);

    const n = try parseForTest(arena, "nature N : el.potential; endnature discipline d; flow.abstol = 1e-9; enddiscipline");
    try std.testing.expect(n.file.natures[0].parent_access.? == .potential);
    try std.testing.expect(n.file.disciplines[0].overrides[0].which == .flow);

    const ps = try parseForTest(arena,
        \\module mo(p); inout p; electrical p; parameter real r = 1; real gm; analog I(p) <+ V(p) / r; endmodule
        \\paramset ps mo;
        \\  parameter real rr = 2;
        \\  (* desc = "out" *) real o;
        \\  .r = rr;
        \\  .$mfactor = 2;
        \\  o = .gm;
        \\endparamset
    );
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(ps));
    const p = ps.file.paramsets[0];
    try std.testing.expectEqual(@as(usize, 1), p.params.len);
    // §6.4.3: a described variable is an output variable.
    try std.testing.expect(p.vars[0].desc);
    try std.testing.expectEqual(@as(usize, 2), p.overrides.len);
    try std.testing.expect(p.overrides[0].kind == .module_param);
    try std.testing.expect(p.overrides[1].kind == .system_param);
    try std.testing.expectEqual(@as(usize, 1), p.body.len);
    // §6.4.3's `.module_output_variable_identifier`, interned with its period.
    const asg = ps.file.stmt(p.body[0]).assign;
    try std.testing.expectEqualStrings(".gm", ps.file.str(ps.file.exprs.strOf(asg.value)));
}

test "A.8.1 brace forms: holes, replications, real counts and digital grouping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // §3.6.3.2's bus nodeset hole, a constant-count pattern replication left
    // for lowering, and the empty pattern.
    const pat = try parseForTest(arena, "module m; parameter real d[0:3] = '{2.3, 4.5, , 6.0}; parameter real e[0:1] = '{N{0.5}}; parameter real z[0:0] = '{}; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(pat));
    const pp = pat.file.modules[0].params;
    const px = &pat.file.exprs;
    try std.testing.expectEqual(@as(usize, 4), px.args(pp[0].default).len);
    try std.testing.expectEqual(Ast.ExprId.none, px.args(pp[0].default)[2]);
    try std.testing.expectEqual(Ast.ExprTag.pattern_repl, px.tag(px.args(pp[1].default)[0]));
    try std.testing.expectEqual(@as(usize, 0), px.args(pp[2].default).len);

    // §4.2.1.1: a real replication count rounds, so {2.5{4'd3}} is three
    // copies of 0011: 0011_0011_0011 = 0x333 = 819 in 12 bits.
    const real = try parseForTest(arena, "module m; integer x; analog x = {2.5{4'd3}}; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(real));
    const lit = real.file.exprs.intLiteral(try analogRhs(real));
    try std.testing.expectEqual(@as(i64, 819), lit.value);
    try std.testing.expectEqual(@as(u32, 12), lit.width);

    // §4.2.13: a zero replication of something with effects is kept, ahead of
    // the folded value; a count past the unrolling guard stays a group.
    const zero = try parseForTest(arena, "module m; integer x, a; analog x = {{0{a}}, 4'b0101}; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(zero));
    const zx = &zero.file.exprs;
    const zc = try analogRhs(zero);
    try std.testing.expectEqual(Ast.ExprTag.concat, zx.tag(zc));
    try std.testing.expectEqual(@as(usize, 2), zx.args(zc).len);
    try std.testing.expectEqual(Ast.ExprTag.multi_concat, zx.tag(zx.args(zc)[0]));
    try std.testing.expectEqual(@as(i64, 5), zx.intValue(zx.args(zc)[1]));
    const big = try parseForTest(arena, "module m; integer x; analog x = {5000{1'b1}}; endmodule");
    try std.testing.expectEqual(Ast.ExprTag.multi_concat, big.file.exprs.tag(try analogRhs(big)));

    // A digital parse keeps every group and count as written.
    const dg = try parseDigitalForTest(arena, "module m; reg [7:0] x, a; initial begin x = {2{a}}; x = {a, {a, a}}; end endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(dg));
    const db = dg.file.stmt(dg.file.modules[0].discrete[0].body).block;
    const dx = &dg.file.exprs;
    try std.testing.expectEqual(Ast.ExprTag.multi_concat, dx.tag(dg.file.stmt(db.body[0]).assign.value));
    const grouped = dg.file.stmt(db.body[1]).assign.value;
    try std.testing.expectEqual(@as(usize, 2), dx.args(grouped).len);
    try std.testing.expectEqual(Ast.ExprTag.concat, dx.tag(dx.args(grouped)[1]));
}

test "IEEE 1364-2005 §12.5 instance selects in a digital parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try parseDigitalForTest(arena, "module m; integer x; initial x = g[1].y; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(r));
    const v = r.file.stmt(r.file.modules[0].discrete[0].body).assign.value;
    const parts = r.file.exprs.nameParts(v);
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("g[1]", r.file.str(parts[0]));
    // A.9.3's index is a constant_expression; one that does not fold here (a
    // genvar's, §12.4.1) is spelled `g[]` and kept for elaboration under the
    // name's main token, folded selects staying spelled out.
    const u = try parseDigitalForTest(arena, "module m; integer x; genvar k; initial x = h[0].g[k].y; endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(u));
    const w = u.file.stmt(u.file.modules[0].discrete[0].body).assign.value;
    const wparts = u.file.exprs.nameParts(w);
    try std.testing.expectEqualStrings("h[0]", u.file.str(wparts[0]));
    try std.testing.expectEqualStrings("g[]", u.file.str(wparts[1]));
    const idx = u.file.hierIndices(u.file.exprs.mainTok(w));
    try std.testing.expectEqual(@as(usize, 1), idx.len);
    try std.testing.expectEqual(Ast.ExprTag.ident, u.file.exprs.tag(idx[0]));
    try std.testing.expectEqual(@as(usize, 0), r.file.hierIndices(r.file.exprs.mainTok(v)).len);
}

// ---------------------------------------------------------------------------
// Known gaps: each test below states the clause's answer, which the parser
// did not give when it was written (see the commit that follows).
// ---------------------------------------------------------------------------

test "§6.6: a generate block may not contain port declarations, specify blocks or specparams (E0229)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // §6.6: "A generate block may not contain port declarations, parameter
    // declarations, specify blocks, or specparam declarations." Syntax 6-8's
    // module_or_generate_item has none of them, and a generate region holds
    // only module_or_generate_items, so the region refuses them too.
    try expectFirstErrors(arena, &.{
        .{ .src = "module m(input a, output y); generate if (1) begin specify (a => y) = 1; endspecify end endgenerate endmodule", .code = .E0229 },
        .{ .src = "module m; generate specparam s = 1; endgenerate endmodule", .code = .E0229 },
        .{ .src = "module m(a); generate input a; endgenerate endmodule", .code = .E0229 },
        .{ .src = "module m(a); input a; if (1) begin output a; end endmodule", .code = .E0229 },
        // Syntax 6-1 puts all three at module scope.
        .{ .src = "module m(input a, output y); specify (a => y) = 1; endspecify endmodule", .code = null },
        .{ .src = "module m; specparam s = 1; endmodule", .code = null },
        .{ .src = "module m(a); input a; endmodule", .code = null },
    }, false);
}

test "A.5.3 edge_indicator and current_state shapes the alphabet check alone admits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const seq = "primitive u(q, a); output q; reg q; input a; table ";
    const tail = " endtable endprimitive";
    try expectFirstErrors(arena, &.{
        // `edge_indicator ::= ( level_symbol level_symbol ) | edge_symbol`:
        // a parenthesis holds exactly two level symbols and closes.
        .{ .src = seq ++ "(01x) : ? : 1;" ++ tail, .code = .E0233 },
        .{ .src = seq ++ "(0) : ? : 1;" ++ tail, .code = .E0233 },
        .{ .src = seq ++ "0) : ? : 1;" ++ tail, .code = .E0233 },
        .{ .src = seq ++ "(01) : ? : 1;" ++ tail, .code = null },
        .{ .src = seq ++ "(?b) : ? : 1;" ++ tail, .code = null },
        // `current_state ::= level_symbol`: one symbol, not none or two.
        .{ .src = seq ++ "0 : 01 : 1;" ++ tail, .code = .E0233 },
        .{ .src = seq ++ "0 : : 1;" ++ tail, .code = .E0233 },
    }, false);
}

test "§14.2.5 path widths from 64-bit literal ranges: computed exactly, never trapped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // [2^63 : 2^63 - 1] is two bits wide: the unsigned literals' difference,
    // not an i64 subtraction that overflows.
    const wide = "module m(input [64'h8000000000000000:64'h7FFFFFFFFFFFFFFF] a, output y); specify (a => y) = 1; endspecify endmodule";
    const r = try parseForTest(arena, wide);
    try std.testing.expectEqual(@as(?diag.Code, .E0245), firstError(r));
    try std.testing.expectEqualStrings("a parallel path joins terminals of the same number of bits (§14.2.5), not 2 and 1", firstErrorMsg(r));
    // 4'shf is -1: a negative indexed width has no width to compare, and the
    // part-select's legality is elaboration's question.
    try expectFirstErrors(arena, &.{
        .{ .src = "module m(input [3:0] a, output y); specify (a[0 +: 4'shf] => y) = 1; endspecify endmodule", .code = null },
    }, false);
}

// ---------------------------------------------------------------------------
// Property: the parser's contract over seeded token-level mutations.
// ---------------------------------------------------------------------------

/// Sources that each reach many productions. They need not stay legal once
/// mutated: the property holds for every input.
const mutation_corpus = [_][]const u8{
    \\module res(p, n); inout p, n; electrical p, n;
    \\  parameter real r = 1k from (0:inf) exclude 0;
    \\  real g; branch (p, n) br;
    \\  analog begin : b
    \\    g = 1.0 / r;
    \\    if (V(br) > 0.0) g = g * 2; else g = g / 2;
    \\    @(cross(V(p, n), +1)) g = {2{1'b1}};
    \\    I(p, n) <+ g * V(p, n) + ddt(V(p, n)) - $temperature;
    \\  end
    \\endmodule
    ,
    \\module d(input clk, output reg [3:0] q);
    \\  wire w; reg [7:0] a = 8'hff;
    \\  assign #(1, 2) w = q[0];
    \\  task t(input [3:0] x); a = x; endtask
    \\  function [3:0] f(input [3:0] v); f = v + 1; endfunction
    \\  initial begin q = 0; #5 t(q); wait (w) q <= repeat (2) @(posedge clk) f(q); end
    \\  always @(posedge clk) case (q) 0, 1: q <= 2; default: q <= 0; endcase
    \\endmodule
    ,
    \\nature Volt; units = "V"; access = Pot; abstol = 1e-6; endnature
    \\discipline el; potential Volt; potential.abstol = 1e-9; domain continuous; enddiscipline
    \\module mo(p); inout p; el p; parameter real r = 1; real gm; analog Pot(p) <+ r; endmodule
    \\paramset ps mo; parameter real rr = 2; (* desc = "o" *) real o; .r = rr; o = .gm; endparamset
    \\connectrules cr; connect a2d split #(.tt(1)) input el, output logic; connect el, x resolveto el; endconnectrules
    ,
    \\primitive dff (output reg q, input clk, input d);
    \\  initial q = 1'b0;
    \\  table (01) 0 : ? : 0; (01) 1 : ? : 1; (0x) ? : ? : -; endtable
    \\endprimitive
    \\module g(o, a, b); output o; input a, b; wire n;
    \\  and #(1, 2) g1(o, a, b); not (strong0, weak1) (n, a); pullup (w);
    \\  tran (a, b); dff u1(o, a, b);
    \\endmodule
    ,
    \\module s(input a, input b, input clk, output y, output q); reg notif;
    \\  specparam d = 1;
    \\  specify
    \\    (a => y) = (1, 2); (a, b *> q) = d;
    \\    if (a) (b => y) = 1; ifnone (b => q) = 2;
    \\    (posedge clk => (q +: a)) = 1;
    \\    $setup(a, posedge clk &&& b, 1, notif); $width(negedge clk, 2);
    \\  endspecify
    \\endmodule
    ,
    \\config c; design work.top; default liblist work; endconfig
    \\module top #(parameter integer n = 2) (p); inout p; electrical p;
    \\  genvar i;
    \\  generate for (i = 0; i < n; i = i + 1) begin : blk end endgenerate
    \\  if (n > 1) begin : big localparam k = 1; end else if (n) begin end
    \\  case (n) 1: begin end default: ; endcase
    \\  child #(.a(1)) u[1:0] (.x(p), .y());
    \\  defparam u[0].a = 3;
    \\  analog function real h; input x; real x; h = x; endfunction
    \\  analog I(p) <+ h(V(p));
    \\endmodule
    ,
};

/// Tokens a mutation inserts: delimiters and keywords that open or close
/// the productions above, so a mutant reaches recovery paths.
const mutation_vocab = [_][]const u8{ "(", ")", "[", "]", "{", "}", ";", ",", ":", "=", "<+", "(*", "*)", "begin", "end", "module", "endmodule", "if", "else", "case", "endcase", "for", "generate", "endgenerate", "analog", "initial", "@", "#", "1", "1.5", "\"s\"", "x", "V", "$root", ".", "'{", "specify", "endspecify", "table", "endtable", "primitive", "endprimitive", "->", "?", "<=", "posedge", "function", "endfunction" };

/// `src` with one token edited: deleted, duplicated, swapped with the next,
/// or preceded by a `mutation_vocab` token. A token's span runs to the next
/// token's start, so the white space and comments after it travel with it.
fn mutateOnce(arena: std.mem.Allocator, src: []const u8, rand: std.Random) ![]const u8 {
    const list = try lexer.tokenize(arena, src, null);
    const starts = list.items(.start);
    const n = starts.len - 1; // the tokens before the final `.eof`
    if (n < 2) return src;
    const i = rand.uintLessThan(usize, n - 1);
    const a = src[starts[i]..starts[i + 1]];
    const b = src[starts[i + 1]..starts[i + 2]];
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, src[0..starts[i]]);
    switch (rand.uintLessThan(u8, 4)) {
        0 => {}, // delete token i
        1 => { // duplicate token i
            try out.appendSlice(arena, a);
            try out.append(arena, ' ');
            try out.appendSlice(arena, a);
        },
        2 => { // swap token i with token i + 1
            try out.appendSlice(arena, b);
            try out.append(arena, ' ');
            try out.appendSlice(arena, a);
            try out.append(arena, ' ');
            try out.appendSlice(arena, src[starts[i + 2]..]);
            return out.items;
        },
        else => { // insert a vocabulary token before token i
            try out.appendSlice(arena, mutation_vocab[rand.uintLessThan(usize, mutation_vocab.len)]);
            try out.append(arena, ' ');
            try out.appendSlice(arena, a);
        },
    }
    try out.appendSlice(arena, src[starts[i + 1]..]);
    return out.items;
}

/// Parses `src` and checks the contract every input must meet: no crash
/// (the test runs in a safety-checked build), the result is `ParseError`
/// exactly when `Parser.failed` is set and exactly when the bag holds an
/// error, and every save/restore flag and scratch stack is back at rest.
fn checkParserContract(arena: std.mem.Allocator, src: []const u8, digital: bool) !void {
    const list = try lexer.tokenize(arena, src, null);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);
    p.digital = digital;
    const refused = if (p.parseSourceFile()) |_| false else |e| switch (e) {
        error.ParseError => true,
        error.OutOfMemory => return e,
    };
    errdefer std.debug.print("mutant ({s} parse):\n{s}\n", .{ if (digital) "digital" else "analog", src });
    var errors: usize = 0;
    for (0..bag.count()) |i| {
        if (bag.at(i).severity == .err) errors += 1;
    }
    try std.testing.expectEqual(refused, p.failed);
    try std.testing.expectEqual(refused, errors != 0);
    try std.testing.expectEqual(@as(u16, 0), p.depth);
    try std.testing.expectEqual(@as(u32, 0), p.attr_depth);
    try std.testing.expectEqual(@as(u32, 0), p.gen_depth);
    try std.testing.expectEqual(@as(u32, 0), p.gen_construct_depth);
    try std.testing.expectEqual(@as(u32, 0), p.item_tok);
    try std.testing.expect(!p.in_discrete and !p.in_digital_delay and !p.analog_expr);
    try std.testing.expect(!p.in_analog_fn and !p.in_paramset and !p.in_connect_module);
    try std.testing.expect(!p.analog_event_block and !p.task_enable_head);
    try std.testing.expectEqual(@as(usize, 0), p.scratch_exprs.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.scratch_stmts.items.len);
    try checkAstShape(&p.file, @intCast(list.len));
    // Determinism: the same tokens give the same rows and ids.
    const again = try lexer.tokenize(arena, src, null);
    var q = Parser.init(arena, src, again.items(.tag), again.items(.start), try newBag(arena, src));
    q.digital = digital;
    _ = q.parseSourceFile() catch |e| if (e == error.OutOfMemory) return e;
    try std.testing.expectEqual(p.file.exprs.len(), q.file.exprs.len());
    try std.testing.expectEqual(p.file.stmts.items.len, q.file.stmts.items.len);
    inline for (.{ .tag, .main_tok, .lhs, .rhs, .extra, .str }) |col|
        try std.testing.expectEqualSlices(@FieldType(Ast.Node, @tagName(col)), p.file.exprs.nodes.items(col), q.file.exprs.nodes.items(col));
    try std.testing.expectEqualSlices(u32, p.file.stmt_toks.items, q.file.stmt_toks.items);
}

/// The AST invariants every later walk relies on, partial parses included:
/// every handle a row holds is `.none` or names an EARLIER row of its table
/// (children are built before their parent, so every walk ends), every list
/// offset and side-table index is in bounds, and every token index is a
/// token of the stream (`n_tokens` of them).
fn checkAstShape(file: *const Ast.SourceFile, n_tokens: u32) !void {
    const ex = &file.exprs;
    var buf: [3]Ast.ExprId = undefined;
    for (0..ex.len()) |i| {
        const id: Ast.ExprId = @fromBackingInt(@intCast(i));
        try std.testing.expect(ex.mainTok(id) < n_tokens);
        // `children` indexes `pool` itself, so an offset out of range trips
        // a safety check here.
        for (ex.children(id, &buf)) |c| if (c != .none) try std.testing.expect(@backingInt(c) < i);
        switch (ex.tag(id)) {
            .int_literal => _ = ex.intLiteral(id),
            .logic_literal => _ = ex.logicValue(id),
            .real_literal => _ = ex.realValue(id),
            .hier_ident, .event_initial_step, .event_final_step => for (ex.nameParts(id)) |s| {
                _ = file.str(s);
            },
            else => {}, // else: every other tag's ids were checked through `children`
        }
        if (ex.strOf(id) != .none) _ = file.str(ex.strOf(id));
    }
    const Edges = struct {
        file: *const Ast.SourceFile,
        parent: u32,
        pub fn expr(v: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) !void {
            if (e != .none) try std.testing.expect(@backingInt(e) < v.file.exprs.len());
        }
        pub fn stmt(v: @This(), s: Ast.StmtId) !void {
            if (s != .none) try std.testing.expect(@backingInt(s) < v.parent);
        }
    };
    for (0..file.stmts.items.len) |i| {
        const id: Ast.StmtId = @fromBackingInt(@intCast(i));
        try std.testing.expect(file.stmtTok(id) < n_tokens);
        try file.stmtEdges(id, Edges{ .file = file, .parent = @intCast(i) });
    }
    for (file.modules) |m| {
        for (m.analog) |a| try std.testing.expect(@backingInt(a.body) < file.stmts.items.len);
        for (m.params) |p| try std.testing.expect(@backingInt(p.default) < ex.len());
    }
}

test "every token-level mutation of the corpus parses without a crash and refuses exactly when it reports" {
    // Oracle: the parser's own contract (`checkParserContract`), not a
    // second parser. The corpus itself is checked first, unmutated.
    for (mutation_corpus) |src| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        try checkParserContract(arena_state.allocator(), src, false);
        try checkParserContract(arena_state.allocator(), src, true);
    }
    // A fixed seed: a failure replays exactly, and prints its mutant.
    var prng = std.Random.DefaultPrng.init(0x7e57_0a11_5eed);
    const rand = prng.random();
    for (mutation_corpus) |seed_src| {
        for (0..96) |_| {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var src = try mutateOnce(arena, seed_src, rand);
            // Up to three more edits, so mutants also stack (a swap after a delete).
            for (0..rand.uintLessThan(u8, 4)) |_| src = try mutateOnce(arena, src, rand);
            try checkParserContract(arena, src, false);
            try checkParserContract(arena, src, true);
        }
    }
}

/// Lexes and parses `src` with every allocation on `gpa`, the parser's arena
/// included, so each one is a point `checkAllAllocationFailures` can fail.
fn parseAllOn(gpa: std.mem.Allocator, src: []const u8, digital: bool) !void {
    const list = try lexer.tokenize(gpa, src, null);
    const bag = try newBag(gpa, src);
    var p = Parser.init(gpa, src, list.items(.tag), list.items(.start), bag);
    p.digital = digital;
    // A parse error is a result, not a failure: only OOM may escape.
    _ = p.parseSourceFile() catch |e| if (e == error.OutOfMemory) return e;
}

test "an allocation failure anywhere in a parse surfaces as OutOfMemory, never swallowed" {
    // `checkAllAllocationFailures` also wants every byte freed, and the
    // parser frees nothing (its arena does), so this is its loop without the
    // leak check: fail allocation k, for every k the parse makes.
    for (mutation_corpus) |src| for ([_]bool{ false, true }) |digital| {
        var k: usize = 0;
        while (true) : (k += 1) {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            var failing: std.testing.FailingAllocator = .init(arena_state.allocator(), .{ .fail_index = k });
            parseAllOn(failing.allocator(), src, digital) catch |e| {
                try std.testing.expectEqual(error.OutOfMemory, e);
                try std.testing.expect(failing.has_induced_failure);
                continue;
            };
            // A run that got past allocation k without failing made fewer
            // than k + 1 allocations: every point has been tried.
            try std.testing.expect(!failing.has_induced_failure);
            break;
        }
    };
}

test "IEEE 1364-2005 triage: pull arrays, event-array control, per-bit path drivers, block-name clashes, non-ANSI port types" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectFirstErrors(arena, &.{
        // A.3.1 name_of_gate_instance takes a range on a pull gate too.
        .{ .src = "module m; wire [7:0] n; pullup u [7:0] (n); endmodule", .code = null },
        // A.6.5 event control on one element of an event array: through
        // event_expression only, since A.9.3's final segment takes no index.
        .{ .src = "module m; event ev [0:1]; initial @(ev[0]) ; endmodule", .code = null },
        .{ .src = "module m; event ev [0:1]; initial @ev[0] ; endmodule", .code = .E0209 },
        // §14.2.1: one driver per destination bit, not per net ...
        .{ .src = "module m(a, p); input a; output [1:0] p; buf b0(p[0], a); buf b1(p[1], a); specify (a *> p) = 1; endspecify endmodule", .code = null },
        // ... so two on one bit, or one on a bit plus the whole, still clash.
        .{ .src = "module m(a, p); input a; output [1:0] p; buf b0(p[0], a); buf b1(p[0], a); specify (a *> p) = 1; endspecify endmodule", .code = .E0245 },
        .{ .src = "module m(a, p); input a; output [1:0] p; buf b0(p[0], a); assign p = 0; specify (a *> p) = 1; endspecify endmodule", .code = .E0245 },
        // §12.4.1: a generate block's name and a process's named block share the scope.
        .{ .src = "module m; if (1) begin : b end initial begin : b end endmodule", .code = .E0230 },
        // A.2.7: the first task port needs a direction.
        .{ .src = "module m; task t(a); begin end endtask endmodule", .code = .E0207 },
        .{ .src = "module m; task t(input a, b); begin end endtask endmodule", .code = null },
        // A.8.3 `unary_operator { attribute_instance } primary`.
        .{ .src = "module m; reg [3:0] i; reg r; initial r = ~ &i; endmodule", .code = .E0209 },
        .{ .src = "module m; reg r; initial r = !!r; endmodule", .code = .E0209 },
        .{ .src = "module m; reg r; initial r = !(!r) + - r - -r; endmodule", .code = null },
        // A.6.5: a bare delay is an unsigned_number, not a sized one.
        .{ .src = "module m; initial #4'd2 ; endmodule", .code = .E0207 },
        .{ .src = "module m; initial #(4'd2) ; endmodule", .code = null },
    }, true);

    // §12.3.3: `wire x;` completes port x, and a second `wire x;` is a net
    // of its own (the engine refuses the duplicate); a discipline after the
    // net type still completes it (VAMS §7.3.2's `wire dnet; ddiscrete dnet;`).
    const twice = try parseDigitalForTest(arena, "module m(x); input x; wire x; wire x; endmodule");
    try std.testing.expectEqual(@as(usize, 1), twice.file.modules[0].nets.len);
    const disc = try parseDigitalForTest(arena, "module m(x); input x; tri0 x; ddiscrete x; endmodule");
    try std.testing.expectEqual(@as(usize, 0), disc.file.modules[0].nets.len);
    try std.testing.expectEqualStrings("ddiscrete", disc.file.str(disc.file.modules[0].ports[0].discipline));
    try std.testing.expectEqual(Ast.NetKind.tri0, disc.file.modules[0].ports[0].kind);
    const dnet = try parseDigitalForTest(arena, "module m(dnet);\ninput dnet;\nwire dnet;\nddiscrete dnet;\nendmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(dnet));
    try std.testing.expectEqual(@as(usize, 0), dnet.file.modules[0].nets.len);
    try std.testing.expectEqualStrings("ddiscrete", dnet.file.str(dnet.file.modules[0].ports[0].discipline));

    // §10.2.1: `input x; real x;` is one formal, typed real.
    const r = try parseDigitalForTest(arena, "module m; task t; input x; real x; begin end endtask endmodule");
    try std.testing.expectEqual(@as(?diag.Code, null), firstError(r));
    const task = r.file.modules[0].tasks[0];
    try std.testing.expectEqual(@as(usize, 1), task.ports.len);
    try std.testing.expectEqual(@as(usize, 0), task.vars.len);
    try std.testing.expectEqual(Ast.Type.real, task.ports[0].v.ty);
}
