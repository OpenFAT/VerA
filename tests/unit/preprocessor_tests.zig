//! Preprocessor tests: source in, expanded text, directive events and
//! diagnostics checked out. Also the vector-scan differential tests, the
//! comment-stripping and line-contract properties, the allocation-failure
//! sweep and the prelude snapshot equivalence tests.
//! LRM §2.2, §2.4, §2.6.2, §2.7, §2.8, §9.15, §10; IEEE 1364 §13.4.1, §19.

const std = @import("std");
const frontend = @import("frontend");
const preprocessor = frontend.preprocessor;
const directive_events = frontend.directive_events;
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const lexer = @import("frontend").lexer;
const token = @import("frontend").token;
const Parser = @import("frontend").Parser;
const DefaultDiscipline = directive_events.DefaultDiscipline;
const DefaultTransition = directive_events.DefaultTransition;
const Timescale = directive_events.Timescale;
const NetType = directive_events.NetType;
const NetTypeRegion = directive_events.NetTypeRegion;
const CellRegion = directive_events.CellRegion;
const Drive = directive_events.Drive;
const DriveRegion = directive_events.DriveRegion;
const predefined_macros = preprocessor.predefined_macros;
const process = preprocessor.process;
const Pp = frontend.Pp;
const scan_stops = frontend.pp_scan.scan_stops;
const findStop = frontend.pp_scan.findStop;
const Qualifier = directive_events.Qualifier;
const vera = @import("vera");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub const testing = std.testing;

/// Preprocess without the std-def prelude, on an arena backed by the testing
/// allocator; the result is duped so the arena can be torn down (leak-checked).
/// Caller owns the returned text and must free it with `testing.allocator`.
fn runTest(src: []const u8) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    const text = (try process(arena_state.allocator(), src, .{ .std_defs = false, .bag = &bag })).text;
    return testing.allocator.dupe(u8, text);
}

/// Expects `src`, preprocessed without the prelude, to be exactly `expected`.
fn expectPp(expected: []const u8, src: []const u8) !void {
    const got = try runTest(src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// Expects `src` to keep its newline count through preprocessing, and the
/// output to contain every `present` string and no `absent` one.
fn expectPreserved(src: []const u8, present: []const []const u8, absent: []const []const u8) !void {
    const got = try runTest(src);
    defer testing.allocator.free(got);
    try testing.expectEqual(
        std.mem.countScalar(u8, src, '\n'),
        std.mem.countScalar(u8, got, '\n'),
    );
    for (present) |s| try testing.expect(std.mem.find(u8, got, s) != null);
    for (absent) |s| try testing.expect(std.mem.find(u8, got, s) == null);
}

/// Expects `src` to fail with exactly one `code` diagnostic whose span lies
/// inside the file it names.
fn expectFail(src: []const u8, code: diag.Code) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    try testing.expectError(error.PreprocessFailed, process(
        arena_state.allocator(),
        src,
        .{ .std_defs = false, .bag = &bag },
    ));
    try testing.expectEqual(@as(usize, 1), bag.count());
    const e = bag.at(0);
    try testing.expectEqual(code, e.code);
    try testing.expect(bag.failed());
    // A preprocess span is file-local: it must index the file it names.
    try testing.expect(e.file != .none);
    try testing.expect(e.span.end <= bag.fileText(e.file).len);
    // The title carries the condition; the message may not repeat it.
    try testing.expect(std.mem.find(u8, e.message, "LRM") == null);
}

test "findStop agrees with the scalar loop it replaced, at every tail boundary" {
    // The one-byte-at-a-time reference `findStop`'s vector block must match.
    const scalar = struct {
        fn find(text: []const u8, from: usize, comptime stops: []const u8) usize {
            var i = from;
            while (i < text.len) : (i += 1) {
                for (stops) |s| if (text[i] == s) return i;
            }
            return i;
        }
    }.find;

    const lanes = std.simd.suggestVectorLength(u8) orelse 16;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    // Every length from the empty slice through three full vectors, so both
    // tail boundaries and the no-vector-iteration case are covered.
    var buf: [3 * 64 + 1]u8 = undefined;
    for (0..3 * lanes + 1) |len| {
        for (0..64) |_| {
            // A byte set that hits the stops often enough to land one in every
            // lane position, and rarely enough to leave long ordinary runs.
            for (buf[0..len]) |*b| b.* = switch (rand.uintLessThan(u8, 10)) {
                0 => '"',
                1 => '\\',
                2 => '`',
                3 => '/',
                4 => '\n',
                else => 'a' + rand.uintLessThan(u8, 26),
            };
            const text = buf[0..len];
            // Sweep `from` too: `scan` never calls this at offset 0 only.
            for (0..len + 1) |from| {
                try testing.expectEqual(scalar(text, from, scan_stops), findStop(text, from, scan_stops));
                try testing.expectEqual(scalar(text, from, "\"\\/"), findStop(text, from, "\"\\/"));
            }
        }
    }
}

test "putNewlines emits exactly the newlines the byte loop it replaced did" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);

    var prng: std.Random.DefaultPrng = .init(0xf00d);
    const rand = prng.random();
    var buf: [200]u8 = undefined;
    for (0..buf.len + 1) |len| {
        for (buf[0..len]) |*b| b.* = if (rand.uintLessThan(u8, 4) == 0) '\n' else 'x';
        const span = buf[0..len];

        // The reference: `for (span) |c| if (c == '\n') append('\n');`
        var want: usize = 0;
        for (span) |c| want += @intFromBool(c == '\n');

        var pp: Pp = .{ .arena = arena, .scratch = arena, .opts = .{ .bag = &bag } };
        try pp.putNewlines(span);
        try testing.expectEqual(want, pp.out.items.len);
        for (pp.out.items) |c| try testing.expectEqual(@as(u8, '\n'), c);
    }
}

test "§2.4 comments vanish, newlines do not — but the separator survives" {
    try expectPp("a\n\nb\n", "a// gone\n/* two\n   lines */b\n");
    try expectPp("\"// not a comment\"\n", "\"// not a comment\"\n");
    // §2.4 block comments do not nest: the first `*/` closes it.
    try expectPp("x   y\n", "x /* a /* b */ y\n");
    try expectFail("x\n/* never closed\n", .E0102);

    // §2.2 makes a comment a token separator, so a comment with no newline in
    // it leaves one space; otherwise these lex as `12` and `<=`.
    try expectPp("1 2", "1/*c*/2");
    try expectPp("a < = b", "a </*c*/= b");
    // A multi-line comment already separates via its newlines; it must not gain
    // a spurious extra space.
    try expectPp("1\n2", "1/*\n*/2");
}

test "§10.4 object-like and function-like macros" {
    try expectPp("\n3.0*v", "`define GAIN 3.0\n`GAIN*v");
    try expectPp("\n((v)*(v))", "`define SQ(x) ((x)*(x))\n`SQ(v)");
    // Nested expansion (fixture ch10 07_nested_macros).
    try expectPp(
        "\n\n(((v)*(v)) + (v))",
        "`define I(x) ((x)*(x))\n`define O(x) (`I(x) + (x))\n`O(v)",
    );
    // Multi-line macro text (fixture ch10 06_define_multiline).
    try expectPp("\n\n(1 + 2)", "`define P (1 + \\\n2)\n`P");
    // A formal is only substituted as a whole identifier, and never inside a
    // string or after a '`'.
    try expectPp("\n\"x\" ax 1", "`define M(x) \"x\" ax x\n`M(1)");
    // Commas inside nested parens do not split arguments.
    try expectPp("\n(max(a,b))+(c)", "`define A(p,q) (p)+(q)\n`A(max(a,b), c)");
    try expectFail("`define SQ(x) x\n`SQ\n", .E0116);
    try expectFail("`define SQ(x) x\n`SQ(1,2)\n", .E0117);
    // A formal spelled inside a §2.8.1 escaped identifier is part of that
    // identifier, not a use of the formal.
    try expectPp("\nreal \\sig-x ;", "`define M(x) real \\sig-x ;\n`M(1)");
}

test "IEEE 1800-2017 §22.5.1 `\" `\\`\" and `` in macro text" {
    // Oracle: the clause's own examples, expanded as the LRM prints them
    // (and as `iverilog -E` does), under every standard; a 1364 unit warns.
    const Sv = struct {
        fn expect(expected: []const u8, src: []const u8) !void {
            try expectPp(expected, src);
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var bag: diag.Bag = .init(arena_state.allocator());
            const out = try process(arena_state.allocator(), src, .{ .std_defs = false, .bag = &bag, .std_1364 = true });
            try testing.expectEqualStrings(expected, out.text);
            try testing.expectEqual(@as(usize, 1), bag.count());
            try testing.expectEqual(diag.Code.W0151, bag.at(0).code);
            try testing.expect(!bag.failed());
        }
    };
    try Sv.expect(
        "\n$display(\"left side: \\\"right side\\\"\");",
        "`define msg(x,y) `\"x: `\\`\"y`\\`\"`\"\n$display(`msg(left side,right side));",
    );
    try Sv.expect("\nclock_master", "`define append(f) f``_master\n`append(clock)");
    // A plain string still keeps its formal; an object-like body works too.
    try Sv.expect("\n\"x\" \"1\"", "`define M(x) \"x\" `\"x`\"\n`M(1)");
    try Sv.expect("\n\"a b\"", "`define S `\"a b`\"\n`S");
    // Outside macro text `" is no token at all.
    try expectFail("`\"a`\"\n", .E0103);
}

test "IEEE 1364 §19.3.1: a `\\` ending a line inside a block comment continues `define text" {
    // Oracle: iverilog macro_comment_multiline (the comment is dropped, the
    // continuation is not). Outside a `define the comment keeps its newlines.
    try expectPp("\n\n(1 + 2)", "`define T(a,b) (a + /* x \\\n y */ b)\n`T(1,2)");
    try expectPp("a\n b", "a/* x \\\n y */ b");
}

test "IEEE 1364-2005 §28.4: protect metadata has no action outside an envelope" {
    // Oracle: §28.4 gives author, comment, encoding ... an action only
    // inside an envelope, and §19.10 makes a pragma without one no-effect.
    try expectPp("\nx", "`pragma protect author=\"a, b\", comment=\"c\"\nx");
    try expectPp("\n\n", "`pragma protect\n`pragma protect end\n");
    // An encryption envelope, a block outside an envelope and an envelope
    // with no end are refused.
    try expectFail("`pragma protect data_method=\"x\", begin_protected\n", .E0146);
    try expectFail("`pragma protect encoding=(enctype=\"raw\"), begin\n", .E0146);
    try expectFail("`pragma protect data_block\n", .E0146);
}

test "IEEE 1364-2005 §28.2: a decryption envelope is scanned as its cleartext" {
    // Oracle: openssl. `printf '`define IN 7\nwire [`OUT:0] w;\n' | openssl
    // enc -des-cbc -K 0123456789abcdef -iv 1234567890abcdef | base64` is
    // the data_block. A macro defined outside expands inside, and one
    // defined inside is in force after.
    const src =
        \\`define OUT 3
        \\`pragma protect data_keyowner="o", data_keyname="k", data_method="des-cbc", begin_protected
        \\`pragma protect encoding=(enctype="base64", bytes=32), data_block
        \\n1Wn+COi7/PUYfw8LBpbP5gnjLT1WISNkOj0IsRnLq0=
        \\`pragma protect end_protected
        \\`IN
    ;
    const keys: frontend.protect.Keys = .{
        .iv = .{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef },
        .keys = &.{.{ .owner = "o", .name = "k", .key = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef } }},
    };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    const out = try process(arena, src, .{ .std_defs = false, .bag = &bag, .protect_keys = keys });
    try testing.expectEqualStrings("\n\nwire [3:0] w;\n\n\n\n\n7", out.text);
    // No key of that owner and name: E0152; a wrong key: E0153.
    var bag2: diag.Bag = .init(arena);
    try testing.expectError(error.PreprocessFailed, process(arena, src, .{ .std_defs = false, .bag = &bag2 }));
    try testing.expectEqual(diag.Code.E0152, bag2.at(0).code);
    var wrong = keys;
    wrong.keys = &.{.{ .owner = "o", .name = "k", .key = @splat(0x13) }};
    var bag3: diag.Bag = .init(arena);
    try testing.expectError(error.PreprocessFailed, process(arena, src, .{ .std_defs = false, .bag = &bag3, .protect_keys = wrong }));
    try testing.expectEqual(diag.Code.E0153, bag3.at(0).code);
}

test "IEEE 1364-2005 §28.4.28.2/§28.4.29.2: a model that needs a license is refused" {
    // "If the application is not licensed ... no decryption shall be
    // performed / execution shall not begin, and the application shall
    // produce an error message": VerA loads no license library, so a
    // decrypt_license or runtime_license pragma in the cleartext is E0146.
    // Oracle: openssl. `printf '`pragma protect <L>_license=(library=
    // "none.so",entry="chk",feature="f",match=1)\nwire w;\n' | openssl enc
    // -des-cbc -K 0123456789abcdef -iv 1234567890abcdef | base64`.
    const blocks = [_][]const u8{
        "CEwlPH76i0/T4ErznDzLTXiO/fE6M6hG3GhSHNfS7/xDln8Ij9YhlGvDdSAiWfxQwSrnuASTQUpW74zwFRsSJn9W7P96MsHSpspQji6DPl8OZgiasP3VMkEDmOyydfAs",
        "CEwlPH76i0/T4ErznDzLTf2CoUC4gdarIYnP3ZIMKbeRxjsdv/x8HzRzbmiT/cbcKjOyXX+w/u5DBgRZCS+jhtg4w9j0XU9Yjek/BBdWArASDFx6mvaKTKeskF+d+fkK",
    };
    const keys: frontend.protect.Keys = .{
        .iv = .{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef },
        .keys = &.{.{ .owner = "o", .name = "k", .key = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef } }},
    };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (blocks) |blk| {
        const src = try std.fmt.allocPrint(arena,
            \\`pragma protect data_keyowner="o", data_keyname="k", data_method="des-cbc", begin_protected
            \\`pragma protect encoding=(enctype="base64", bytes=96), data_block
            \\{s}
            \\`pragma protect end_protected
            \\
        , .{blk});
        var bag: diag.Bag = .init(arena);
        try testing.expectError(error.PreprocessFailed, process(arena, src, .{ .std_defs = false, .bag = &bag, .protect_keys = keys }));
        try testing.expectEqual(diag.Code.E0146, bag.at(0).code);
    }
}

test "IEEE 1364-2005 §28.4.20: the digest key comes from the key_block, and each digest_block checks the block before it" {
    // The suite's protected_digest_decrypt_key.v (oracle: openssl, its
    // known_keys.json). The key_block decrypts to a data_decrypt_key
    // (0123456789abcdef) and a digest_decrypt_key (fedcba9876543210);
    // the first digest_block is the SHA-1 of the key_block's cleartext,
    // the second of the data_block's, both under the digest key.
    const src =
        \\`pragma protect begin_protected
        \\`pragma protect key_keyowner="VerAConformance"
        \\`pragma protect key_keyname="exchange-fixture"
        \\`pragma protect key_method="des-cbc"
        \\`pragma protect digest_method="sha1"
        \\`pragma protect encoding=(enctype="base64",line_length=64,bytes=312)
        \\`pragma protect key_block
        \\HmR1lmmwZqix46pT213GCLJGD4OtmME9U7vcCpo4YqZvYw+xhz92F0XGsaoWCFUk
        \\7XX/HumQ/bJdtzV3L+V4hQ3xGQyD7cLJLKoHdUxF8U7PIUJWgVCgCzSqfXu4TQP0
        \\iLgc2dAxR7SLK1htwsLXI/uy0zMeDaVolUPGaRbW/+aWxd3Tf1ZtBGXIMDkIJ0xS
        \\q3071/nhOjSo/9Eb2gv3e7HxFXrM4TS2SE15E0GD8JEcaC0iro6aKyrlkb4osjlQ
        \\b4UWhpuTdN04tYDnrbbrj+UtDTbDlXty+9kM7xnYQ8e7IPait0kqpDgelCW9YcAx
        \\UQvMAHXAkI9pyfRdE75E3rC1KrYcAB4wY24GIsz6NIe5XxgDVgpru2s2thawBglq
        \\X008Pg5N4cOU/N/X4jHd/rYLcmWvsCB/
        \\`pragma protect encoding=(enctype="base64",line_length=64,bytes=24)
        \\`pragma protect digest_block
        \\QcnzcPxM6OaQOKgXHWfiEaeS8KZi4LB2
        \\`pragma protect encoding=(enctype="base64",line_length=64,bytes=80)
        \\`pragma protect data_block
        \\gHbCKL32373t8sEGvD15nckvxrVeIl860S8eWw2QhIG1ZVCMR+++LjLuTsN2m/dY
        \\N3sNtdQRLWi/uhem7bk4Jp0vCWN1q5BIQ0GHXjC9v7s=
        \\`pragma protect encoding=(enctype="base64",line_length=64,bytes=24)
        \\`pragma protect digest_block
        \\iRM7BMo+TyISaFZ2SU/cwn3BCebCzX3m
        \\`pragma protect end_protected
    ;
    const keys: frontend.protect.Keys = .{
        .iv = .{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef },
        .keys = &.{.{ .owner = "VerAConformance", .name = "exchange-fixture", .key = .{ 0x13, 0x34, 0x57, 0x79, 0x9b, 0xbc, 0xdf, 0xf1 } }},
    };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    const out = try process(arena, "`define PROTECTED_VALUE 42\n" ++ src, .{ .std_defs = false, .bag = &bag, .protect_keys = keys });
    try testing.expect(std.mem.find(u8, out.text, "$display(\"decrypted=%0d\",42)") != null);
    // A key_block digest that is not the key_block's: E0153.
    const bad = try std.mem.replaceOwned(u8, arena, src, "QcnzcPxM6OaQOKgXHWfiEaeS8KZi4LB2", "iRM7BMo+TyISaFZ2SU/cwn3BCebCzX3m");
    var bag2: diag.Bag = .init(arena);
    try testing.expectError(error.PreprocessFailed, process(arena, bad, .{ .std_defs = false, .bag = &bag2, .protect_keys = keys }));
    try testing.expectEqual(diag.Code.E0153, bag2.at(0).code);
}

test "§10.4 macro argument brackets must match their openers" {
    // Matched nesting of all three bracket kinds is opaque to the comma split.
    try expectPp("\n{[(a)],b}", "`define SQ(x) x\n`SQ({[(a)],b})");
    // A closer that does not match its opener is E0120: the `(` it abandons
    // is unterminated.
    try expectFail("`define SQ(x) x\n`SQ(2.0]\n", .E0120);
    try expectFail("`define SQ(x) x\n`SQ({a)}\n", .E0120);
    try expectFail("`define SQ(x) x\n`SQ([1,2)]\n", .E0120);
}

test "§10.4 a nested invocation in an actual argument is not recursion" {
    // IEEE 1364's recursion rule is about the macro's text referring to
    // itself. `MAX`'s text refers only to its formals; the nested use sits in
    // the call, and arguments are fully expanded before substitution (fixture
    // ch10 49).
    try expectPp(
        "\n((((1.0)>(2.0)?(1.0):(2.0)))>(3.0)?(((1.0)>(2.0)?(1.0):(2.0))):(3.0))",
        "`define MAX(a,b) ((a)>(b)?(a):(b))\n`MAX(`MAX(1.0,2.0),3.0)",
    );
    // An object-like use inside an argument expands there too, and a
    // function-like macro nested in another macro's argument keeps working.
    try expectPp(
        "\n\n((7.0)>(2.0)?(7.0):(2.0))",
        "`define A 7.0\n`define MAX(a,b) ((a)>(b)?(a):(b))\n`MAX(`A,2.0)",
    );
    // Self-reference in the text is still E0118:
    // object-like, function-like, and mutual (indirect).
    try expectFail("`define R `R\n`R\n", .E0118);
    try expectFail("`define F(x) `F(x)\n`F(1)\n", .E0118);
    try expectFail("`define A(x) `B(x)\n`define B(y) `A(y)\n`A(1)\n", .E0118);

    // E0150: a macro that doubles its text 40 times expands to 2^40 tokens,
    // past what u32 offsets address. It is refused by name when the text
    // passes the bound; `text_limit` brings the bound to 1 MiB here so the
    // test does not build 4 GiB first.
    {
        var dbl: std.ArrayList(u8) = .empty;
        defer dbl.deinit(testing.allocator);
        try dbl.appendSlice(testing.allocator, "`define D0 x\n");
        for (1..41) |i| try dbl.print(testing.allocator, "`define D{d} `D{d} `D{d}\n", .{ i, i - 1, i - 1 });
        try dbl.appendSlice(testing.allocator, "`D40\n");
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        var bag: diag.Bag = .init(arena_state.allocator());
        try testing.expectError(error.PreprocessFailed, process(arena_state.allocator(), dbl.items, .{ .std_defs = false, .bag = &bag, .text_limit = 1 << 20 }));
        try testing.expectEqual(diag.Code.E0150, bag.at(0).code);
        // The same doubling 17 times is 2^17 `x`s, under the bound: expanded.
        var ok_bag: diag.Bag = .init(arena_state.allocator());
        const ok_src = try std.mem.replaceOwned(u8, arena_state.allocator(), dbl.items, "`D40\n", "`D17\n");
        const out = try process(arena_state.allocator(), ok_src, .{ .std_defs = false, .bag = &ok_bag, .text_limit = 1 << 20 });
        try testing.expectEqual(@as(usize, 1 << 17), std.mem.countScalar(u8, out.text, 'x'));
    }
    // The bound is on the whole text, whichever files make it: the annex D
    // prelude alone passes 64 bytes, though a one-line source is under it.
    {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        var bag: diag.Bag = .init(arena_state.allocator());
        try testing.expectError(error.PreprocessFailed, process(arena_state.allocator(), "module m; endmodule\n", .{ .bag = &bag, .text_limit = 64 }));
        try testing.expectEqual(diag.Code.E0150, bag.at(0).code);
    }
}

test "macro nesting has no depth bound: 100,000 nested uses and a 100,000-macro chain" {
    // `M(x)` is `(x)`, so n nested uses expand to n parentheses around 1 and
    // need n live expansions, argument pre-expansion included. 129 was one
    // past the old 128-level cap (E0119); 10,000 crosses many stack segments
    // (`preprocessor.segment_levels`). Each level copies the text inside it,
    // so the text built is quadratic: 10,000 levels is 50 MB of it.
    for ([_]usize{ 129, 10_000 }) |n| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(testing.allocator);
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(testing.allocator);
        try src.appendSlice(testing.allocator, "`define M(x) (x)\n");
        try want.append(testing.allocator, '\n');
        for (0..n) |_| try src.appendSlice(testing.allocator, "`M(");
        try want.appendNTimes(testing.allocator, '(', n);
        try src.append(testing.allocator, '1');
        try want.append(testing.allocator, '1');
        try src.appendNTimes(testing.allocator, ')', n);
        try want.appendNTimes(testing.allocator, ')', n);
        try expectPp(want.items, src.items);
    }
    // A chain: M<k> expands to M<k-1>, so the body rescan nests n deep with
    // n distinct names on the cycle guard.
    {
        const n = 100_000;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(testing.allocator);
        try src.appendSlice(testing.allocator, "`define M0 end\n");
        for (1..n) |k| try src.print(testing.allocator, "`define M{d} `M{d}\n", .{ k, k - 1 });
        try src.print(testing.allocator, "`M{d}\n", .{n - 1});
        const got = try runTest(src.items);
        defer testing.allocator.free(got);
        try testing.expect(std.mem.endsWith(u8, got, "end\n"));
    }
    // A cycle is still E0118, at any depth.
    try expectFail("`define A `B\n`define B `A\n`A\n", .E0118);
}

test "escaped identifiers reach `undef, the conditionals and `default_discipline" {
    // Syntax 10-3 / A.9.3: every directive whose operand is an `identifier`
    // takes the §2.8.1 spelling, not just `define (fixture ch10 50).
    try expectPreserved("`define \\M-X 1\n`ifdef \\M-X\nyes\n`else\nno\n`endif\n", &.{"yes"}, &.{"no"});
    try expectPreserved("`define \\M-X 1\n`undef \\M-X\n`ifndef \\M-X\nyes\n`endif\n", &.{"yes"}, &.{});
    try expectPreserved("`define \\M-X 1\n`ifdef NOPE\na\n`elsif \\M-X\nb\n`else\nc\n`endif\n", &.{"b"}, &.{ "a", "c" });

    // §10.2: annex D.1's `discipline \logic ;` is only nameable this way, and
    // §2.8.1 makes the recorded name the bare bytes between `\` and the space.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    const defs = (try process(arena_state.allocator(), "`default_discipline \\logic\n", .{
        .std_defs = false,
        .bag = &bag,
    })).directives.disciplines;
    try testing.expectEqual(@as(usize, 1), defs.len);
    try testing.expectEqualStrings("logic", defs[0].discipline);
}

test "IEEE 1364 §19.5: only white space or a comment follows an `include" {
    try expectFail("`include \"constants.vams\" x\n", .E0144);
    // The clause's own legal form: a comment after the name, either kind.
    testing.allocator.free(try runTest("`include \"constants.vams\" // why\n`include \"constants.vams\" /* why */\n"));
}

test "§2.8: a macro name does not start with $" {
    try expectFail("`define $X 1\n", .E0109);
    // Escaped, it is an identifier (§2.8.1) and a legal name.
    try expectPreserved("`define \\$X 1\n`\\$X \n", &.{"1"}, &.{});
}

test "IEEE 1364 §19.3.1: macro text does not split a string" {
    try expectFail("`define first_half \"start of string\n", .E0145);
    // A closed string, an escaped quote inside one, and a `"` inside an
    // escaped identifier are all whole tokens.
    try expectPreserved("`define S \"a \\\" b\"\n`S\n", &.{"b"}, &.{});
    try expectPreserved("`define E \\q\"x \n`E\n", &.{"q\"x"}, &.{});
}

test "IEEE 1364 §19.3.1: a compiler directive is not a macro name" {
    try expectFail("`define include 1\n", .E0143);
    try expectFail("`define __LINE__ 7\n", .E0143);
    try expectFail("`define resetall\n", .E0143);
    // A name that merely contains one is an ordinary macro.
    try expectPreserved("`define includes 1\n`includes\n", &.{"1"}, &.{});
}

test "§10.4 undef, and IEEE 1364 conditionals" {
    try expectPreserved(
        "`define A\n`undef A\n`ifdef A\ntaken\n`else\nother\n`endif\n",
        &.{"other"},
        &.{"taken"},
    );
    try expectPreserved(
        "`define S\n`ifdef F\n1\n`elsif S\n2\n`else\n3\n`endif\n",
        &.{"2"},
        &.{ "1", "3" },
    );
    try expectPreserved(
        "`define O\n`define I\n`ifdef O\n`ifdef I\nsix\n`else\ntwo\n`endif\n`else\none\n`endif\n",
        &.{"six"},
        &.{ "two", "one" },
    );
    try expectPreserved("`ifndef NOPE\nyes\n`else\nno\n`endif\n", &.{"yes"}, &.{"no"});
    // An undefined macro inside a dead arm is not an error.
    try expectPreserved("`ifdef NOPE\n`MISSING\n`endif\n", &.{}, &.{"MISSING"});
    try expectFail("`ifdef A\nx\n", .E0101);
    try expectFail("`endif\n", .E0108);
    try expectFail("`ifdef A\n`else\n`else\n`endif\n", .E0106);
}

test "§10.5 predefined macros survive undef and resetall" {
    try expectPreserved("`ifdef __VAMS_ENABLE__\nyes\n`endif\n", &.{"yes"}, &.{});
    try expectPreserved(
        "`undef __VAMS_ENABLE__\n`ifdef __VAMS_ENABLE__\nyes\n`endif\n",
        &.{"yes"},
        &.{},
    );
    // ... and so do user macros: IEEE 1364 §19.3 "The text macro facility is
    // not affected by the compiler directive `resetall" (fixture ch10
    // audit_macro_resetall_preserves_user).
    try expectPreserved("`define V 2.0\n`resetall\n`V\n", &.{"2.0"}, &.{});
    try expectPreserved("`resetall\n`ifdef __VAMS_ENABLE__\nyes\n`endif\n", &.{"yes"}, &.{});
}

test "§9.15 Table 9-27 reads `timescale back, in seconds" {
    const T = struct {
        /// The published timescale for `src`, which is the whole §9.15 surface:
        /// it contributes nothing to the output text (the first row pins that).
        fn ts(src: []const u8) !?Timescale {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var bag: diag.Bag = .init(arena_state.allocator());
            return (try process(arena_state.allocator(), src, .{
                .std_defs = false,
                .bag = &bag,
            })).directives.timescale();
        }
    };
    // Table 9-27's units column is "s", not ticks.
    const t = (try T.ts("`timescale 1ns/1ps\n")).?;
    try testing.expectEqual(@as(f64, 1e-9), t.unit);
    try testing.expectEqual(@as(f64, 1e-12), t.precision);
    // Every magnitude on IEEE 1364 Table 19-1's grid, and the coarsest unit.
    const t2 = (try T.ts("`timescale 100us / 10 ns\n")).?;
    try testing.expectEqual(@as(f64, 100e-6), t2.unit);
    try testing.expectEqual(@as(f64, 10e-9), t2.precision);
    // No directive is not a default: §9.15 says "as specified in `timescale",
    // and with nothing specified the parameter is not known (E0811).
    try testing.expectEqual(@as(?Timescale, null), try T.ts("module m; endmodule\n"));
    // §19.6 `resetall returns it to that state.
    try testing.expectEqual(@as(?Timescale, null), try T.ts("`timescale 1ns/1ps\n`resetall\n"));
    // Off Table 19-1 in each of the three ways, plus §19.8's ordering rule and
    // the two ways of writing the wrong number of operands: all E0142.
    for ([_][]const u8{
        "`timescale 2ns/1ps\n", // magnitude
        "`timescale 1sec/1ps\n", // unit name
        "`timescale 1ns 1ps\n", // no slash
        "`timescale 1ps/1ns\n", // precision coarser than the unit
        "`timescale 1ns/1ps junk\n", // §19.8 takes two operands and no more
        "`timescale\n", // and they are not optional
    }) |src| try expectFail(src, .E0142);
    // The last one in the stream is the one in force (one elaborated module).
    try testing.expectEqual(@as(f64, 1e-3), (try T.ts("`timescale 1ns/1ps\n`timescale 1ms/1us\n")).?.unit);
}

test "directives that contribute no text, and rejected ones" {
    try expectPp(
        "\n\n\n",
        "`timescale 1ns/1ps\n`celldefine\n`pragma f harmless\n",
    );
    // IEEE 1364 §19.2/§19.9: applied here, and the word alone passed through
    // for the parser to refuse inside a module.
    try expectPp("`default_nettype\n`unconnected_drive\n", "`default_nettype wire\n`unconnected_drive pull1\n");
    try expectFail("`pragma\n", .E0147);
    try expectFail("`line 3 \"f.v\" 0 // no\n", .E0128);
    // §10.3's word is passed through too (§10.3: only outside module
    // definitions), so the parser can refuse it there.
    try expectPp("\n`default_transition\n", "`default_discipline electrical\n`default_transition 1n\n");
    // §10.6 is the exception: passed through verbatim for the parser, which is
    // the only stage that knows where a design element starts.
    try expectPp(
        "`begin_keywords \"VAMS-2023\"\n`end_keywords\n",
        "`begin_keywords \"VAMS-2023\"\n`end_keywords\n",
    );
    // ... but still dies with an inactive `ifdef arm, like any other directive.
    try expectPp("\n\n\n", "`ifdef NOPE\n`begin_keywords \"VAMS-2.3\"\n`endif\n");
    try expectFail("`MISSING\n", .E0115); // fixture ch10 23
    try expectFail("`nosuchdirective_or_macro\n", .E0115);
    try expectFail("`define R `R\n`R\n", .E0118); // cycle guard
}

// ---------------------------------------------------------------------------
// The three IEEE 1364 directives that scope forward: §19.2 `default_nettype,
// §19.1 `celldefine, §19.9 `unconnected_drive. §10.1's scope sentence is the
// shared rule; `Region.inForce` is the shared reader.
// ---------------------------------------------------------------------------

/// Preprocess `src` and hand back the three region lists, which is the whole of
/// what these directives contribute to a compilation.
fn regionsOf(arena: Allocator, src: []const u8) !struct {
    nettypes: []const NetTypeRegion,
    cells: []const CellRegion,
    drives: []const DriveRegion,
} {
    var bag: diag.Bag = .init(arena);
    const d = (try process(arena, src, .{ .std_defs = false, .bag = &bag })).directives;
    return .{ .nettypes = d.nettypes, .cells = d.cells, .drives = d.drives };
}

test "§10.1 a region directive written as a macro actual opens its region where the expansion lands" {
    // Oracle: the same directive written in place of the call. IEEE 1364
    // §19.3.1 substitutes an actual literally, so both spellings give one
    // text and one set of region lists.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const head = "`define ID(x) x\nmodule a; endmodule\n";
    const tail = "\nmodule b; endmodule\n";
    for ([_][]const u8{
        "`timescale 1ns/1ps",       "`default_discipline electrical", "`default_transition 1n",
        "`default_nettype none",    "`celldefine",                    "`endcelldefine",
        "`unconnected_drive pull1", "`nounconnected_drive",           "`resetall",
    }) |d| {
        var bag: diag.Bag = .init(arena);
        const direct = try process(arena, try std.mem.concat(arena, u8, &.{ head, d, tail }), .{ .std_defs = false, .bag = &bag });
        const actual = try process(arena, try std.mem.concat(arena, u8, &.{ head, "`ID(", d, ")", tail }), .{ .std_defs = false, .bag = &bag });
        try testing.expectEqual(@as(usize, 0), bag.count());
        try testing.expectEqualStrings(direct.text, actual.text);
        try testing.expectEqualDeep(direct.directives, actual.directives);
    }
}

test "IEEE 1364 §19.2 `default_nettype publishes a region per directive" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every value on §19.2's closed list parses, `none` included. Eleven
    // directives, eleven events, in text-stream order.
    const all = try regionsOf(arena,
        \\`default_nettype wire
        \\`default_nettype tri
        \\`default_nettype tri0
        \\`default_nettype tri1
        \\`default_nettype wand
        \\`default_nettype triand
        \\`default_nettype wor
        \\`default_nettype trior
        \\`default_nettype trireg
        \\`default_nettype uwire
        \\`default_nettype none
        \\
    );
    try testing.expectEqual(@as(usize, 11), all.nettypes.len);
    try testing.expectEqual(NetType.wire, all.nettypes[0].value);
    try testing.expectEqual(NetType.uwire, all.nettypes[9].value);
    try testing.expectEqual(NetType.none, all.nettypes[10].value);

    // Syntax 19-2 has no line break between the word and its operand, so a
    // word alone on its line takes the next one, and the line count survives.
    const next = try regionsOf(arena, "`default_nettype\n\n  none\n`unconnected_drive\npull1\n");
    try testing.expectEqual(NetType.none, next.nettypes[0].value);
    try testing.expectEqual(Drive.pull1, next.drives[0].value);
    try expectPp("`default_nettype\n\n\n`unconnected_drive\n\n", "`default_nettype\n\n  none\n`unconnected_drive\npull1\n");

    // §19.2's list is closed, and it is not §10.2's: `reg`, `real` and
    // `supply0` are `default_discipline qualifiers and not net types.
    for ([_][]const u8{
        "`default_nettype reg\n",
        "`default_nettype real\n",
        "`default_nettype supply0\n",
        "`default_nettype wires\n", // a typo, not a twelfth type
        "`default_nettype\n", // no brackets in §19.2: mandatory
        "`default_nettype wire tri\n", // and exactly one
    }) |src| try expectFail(src, .E0140);

    // §10.1: a region runs from the directive to the next one. Before the first
    // there is no region, and §19.2 names the state there: wire.
    const r = try regionsOf(arena, "module a; endmodule\n`default_nettype none\nmodule b; endmodule\n");
    try testing.expectEqual(@as(usize, 1), r.nettypes.len);
    try testing.expectEqual(NetType.wire, NetTypeRegion.inForce(r.nettypes, 0, .default));
    try testing.expectEqual(NetType.none, NetTypeRegion.inForce(r.nettypes, r.nettypes[0].at, .default));
    try testing.expectEqual(NetType.none, NetTypeRegion.inForce(r.nettypes, r.nettypes[0].at + 1, .default));

    // IEEE 1364 §19.6, said twice: `resetall returns it to `wire`, and that is
    // an event and not an erasure: the region above the reset keeps its value.
    const reset = try regionsOf(arena, "`default_nettype none\n`resetall\n");
    try testing.expectEqual(@as(usize, 2), reset.nettypes.len);
    try testing.expectEqual(NetType.none, reset.nettypes[0].value);
    try testing.expectEqual(NetType.wire, reset.nettypes[1].value);
    try testing.expectEqual(NetType.none, NetTypeRegion.inForce(reset.nettypes, reset.nettypes[0].at, .default));
}

test "IEEE 1364 §19.1 `celldefine tags the modules between the pair" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The tag is a region, so what a consumer asks is "was this offset inside
    // one". Three modules, one of them a cell.
    const src =
        \\module outside_before; endmodule
        \\`celldefine
        \\module the_cell; endmodule
        \\`endcelldefine
        \\module outside_after; endmodule
        \\
    ;
    const r = try regionsOf(arena, src);
    try testing.expectEqual(@as(usize, 2), r.cells.len);
    try testing.expect(r.cells[0].value);
    try testing.expect(!r.cells[1].value);
    // Before the pair, inside it, after it.
    try testing.expect(!CellRegion.inForce(r.cells, 0, false));
    try testing.expect(CellRegion.inForce(r.cells, r.cells[0].at, false));
    try testing.expect(!CellRegion.inForce(r.cells, r.cells[1].at, false));

    // §19.6 again: the reset closes an open `celldefine.
    const reset = try regionsOf(arena, "`celldefine\n`resetall\n");
    try testing.expectEqual(@as(usize, 2), reset.cells.len);
    try testing.expect(!reset.cells[1].value);
}

test "IEEE 1364 §19.9 `unconnected_drive publishes pull0/pull1 regions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try regionsOf(arena,
        \\module before_any_directive; endmodule
        \\`unconnected_drive pull1
        \\`nounconnected_drive
        \\`unconnected_drive pull0
        \\
    );
    try testing.expectEqual(@as(usize, 3), r.drives.len);
    try testing.expectEqual(Drive.pull1, r.drives[0].value);
    try testing.expectEqual(Drive.float, r.drives[1].value);
    try testing.expectEqual(Drive.pull0, r.drives[2].value);
    // Above the first directive there is no region, and §19.9's state there is
    // "not pulled". A query at a directive's offset is inside its region (the
    // offset is where the directive's own collapsed text ends), which is what
    // makes a module declared on the next line the subject of it.
    try testing.expectEqual(Drive.float, DriveRegion.inForce(r.drives, 0, .default));
    try testing.expectEqual(Drive.pull1, DriveRegion.inForce(r.drives, r.drives[0].at, .default));

    // §19.9's operand is a two-way alternation and it is not optional: the
    // form that takes none is the separate directive `nounconnected_drive.
    for ([_][]const u8{
        "`unconnected_drive\n",
        "`unconnected_drive pull2\n",
        "`unconnected_drive float\n", // `.float` is the other directive's value
        "`unconnected_drive pull1 pull0\n",
    }) |src| try expectFail(src, .E0141);
    // The operand-less directives do not police their line: `nounconnected_drive
    // pull1` is accepted and the trailing word collapses with the directive,
    // exactly as it does after `celldefine` and (necessarily) after `pragma`.
    // ponytail: one more handler would catch the typo of writing the closing
    // directive with the opening one's operand. Worth it the day a model does.
    try testing.expectEqual(Drive.float, (try regionsOf(arena, "`nounconnected_drive pull1\n")).drives[0].value);

    const reset = try regionsOf(arena, "`unconnected_drive pull1\n`resetall\n");
    try testing.expectEqual(Drive.float, reset.drives[1].value);
}

test "§10.1 scopes a directive across a source file boundary" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // §10.1: "The scope of compiler directives extends from the point where it
    // is processed, across all files processed, to the point where another
    // compiler directive supersedes it or the processing completes." So an
    // `include neither opens nor closes a region. The annex D files are the
    // only ones this test can include without a filesystem, and they are enough
    // because what is being checked is that the boundary changes nothing.
    var bag: diag.Bag = .init(arena);
    const d = (try process(arena,
        \\`default_nettype none
        \\`celldefine
        \\`include "constants.vams"
        \\module after_the_include; endmodule
        \\
    , .{ .std_defs = false, .bag = &bag })).directives;
    const nettypes = d.nettypes;
    const cells = d.cells;

    // One event each (the included file wrote none), and both still in force
    // at the end of the stream, which is the far side of the boundary.
    try testing.expectEqual(@as(usize, 1), nettypes.len);
    try testing.expectEqual(@as(usize, 1), cells.len);
    const eof = std.math.maxInt(u32);
    try testing.expectEqual(NetType.none, NetTypeRegion.inForce(nettypes, eof, .default));
    try testing.expect(CellRegion.inForce(cells, eof, false));
}

test "§10.7 `__FILE__ and `__LINE__" {
    // fixtures ch10 21, 22. The default `Options.file_name` is "<source>".
    try expectPp("\"<source>\"\n", "`__FILE__\n");
    // physical lines, counted through the comment the stripper deleted and
    // through a directive that collapsed to its newline.
    try expectPp("\n\n\n4 4\n", "// c\n`define X 1\n\n`__LINE__ `__LINE__\n");
    // fixture ch10 44: IEEE 1364 §19.7 numbers the line after the directive.
    try expectPp("\n100\n101\n", "`line 100 \"virtual.va\" 0\n`__LINE__\n`__LINE__\n");
    try expectPp("\n\"virtual.va\"\n", "`line 100 \"virtual.va\" 0\n`__FILE__\n");
    try expectFail("`line\n", .E0128);
    try expectFail("`line nope\n", .E0128);
    // IEEE 1364 §19.7: "All parameters in the `line directive are required",
    // the number is positive, the level is 0, 1 or 2, and nothing follows.
    try expectFail("`line 5\n", .E0128);
    try expectFail("`line 5 \"f.va\"\n", .E0128);
    try expectFail("`line 0 \"f.va\" 0\n", .E0128);
    try expectFail("`line 5 \"f.va\" 3\n", .E0128);
    try expectFail("`line 5 \"f.va\" 1 x\n", .E0128);
    try expectPp("\n6\n", "`line 6 \"f.va\" 2\n`__LINE__\n");
}

test "§10.2 `default_discipline Syntax 10-1" {
    try expectPp("\n\n\n", "`default_discipline\n`default_discipline electrical\n`default_discipline electrical wire\n");
    // fixture ch10 45: a discipline name is not one of the fifteen qualifiers.
    try expectFail("`default_discipline electrical electrical\n", .E0127);
    try expectFail("`default_discipline electrical wire junk\n", .E0127);
}

test "§10.3 `default_transition Syntax 10-2" {
    // The published §10.3 events for `src`, which is the whole surface §4.5.8
    // consumes: the value, and the output offset it takes effect from.
    const T = struct {
        fn ev(src: []const u8) ![]const DefaultTransition {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var bag: diag.Bag = .init(arena_state.allocator());
            const out = (try process(arena_state.allocator(), src, .{
                .std_defs = false,
                .bag = &bag,
            })).directives.transitions;
            return testing.allocator.dupe(DefaultTransition, out);
        }
    };

    const one = try T.ev("`default_transition 4n\n");
    defer testing.allocator.free(one);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(f64, 4e-9), one[0].value.?);

    // §10.3's supersession sentence: both are published, in text order, so the
    // consumer can pick "the directive which immediately precedes" a call
    // rather than being handed one latched value.
    const two = try T.ev("`default_transition 8n\n`default_transition 4n\n");
    defer testing.allocator.free(two);
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqual(@as(f64, 8e-9), two[0].value.?);
    try testing.expectEqual(@as(f64, 4e-9), two[1].value.?);
    try testing.expect(two[0].at < two[1].at);

    // Every §2.6.2 spelling of the same time, since the operand is read in a
    // text stage and not by the number lexer proper.
    for ([_][]const u8{ "4n\n", "4e-9\n", "0.000000004\n", "4_000p\n" }) |t| {
        const src = try testing.allocator.print("`default_transition {s}", .{t});
        defer testing.allocator.free(src);
        const e = try T.ev(src);
        defer testing.allocator.free(e);
        try testing.expectEqual(@as(f64, 4e-9), e[0].value.?);
    }

    // IEEE 1364 §19.6: `resetall returns the directive to its default, which
    // §10.3 leaves to the simulator: a null event after the 4n.
    const reset = try T.ev("`default_transition 4n\n`resetall\n");
    defer testing.allocator.free(reset);
    try testing.expectEqual(@as(usize, 2), reset.len);
    try testing.expectEqual(@as(?f64, null), reset[1].value);

    // fixture ch10 48: the operand is not bracketed in Syntax 10-2, so it is
    // mandatory, and the bare form is not a request for the simulator default.
    try expectFail("`default_transition\n", .E0129);
    try expectFail("`default_transition    \n", .E0129);
    try expectFail("`default_transition electrical\n", .E0129);
    try expectFail("`default_transition -4n\n", .E0129);
    try expectFail("`default_transition 4n junk\n", .E0129);
}

test "`include resolves the built-in annex D files" {
    // fixture ch10 18_include_constants
    const got = try runTest("`include \"constants.vams\"\n`P_CELSIUS0 `P_K\n");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.find(u8, got, "273.15") != null);
    try testing.expect(std.mem.find(u8, got, "1.3806503e-23") != null);
    try expectFail("`include \"no_such_file.vams\"\n", .E0126);
    try expectFail("`include nonsense\n", .E0122);
    try expectFail("`include <constants.vams>\n", .E0122);

    // annex D.3 is shipped too, and is not preloaded: it has to be asked for.
    const d3 = try runTest("`include \"driver_access.vams\"\n`DRIVER_WAND\n");
    defer testing.allocator.free(d3);
    try testing.expect(std.mem.find(u8, d3, "32'b10000000000") != null);
}

test "IEEE 1364 §19.5 `include opens a full path name as written" {
    // A path is machine-specific, so no fixture can spell one; the file is
    // written here, and no include dir is given to join it onto.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "abs.vh", .data = "`define ABS_OK 7\n" });
    const abs = try tmp.dir.realPathFileAlloc(io, "abs.vh", testing.allocator);
    defer testing.allocator.free(abs);
    const src = try testing.allocator.print("`include \"{s}\"\n`ABS_OK\n", .{abs});
    defer testing.allocator.free(src);
    const got = try runTest(src);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.find(u8, got, "7") != null);
}

test "§10.4 the NAME may be escaped and the TEXT may not begin with __VAMS_" {
    // Syntax 10-3: text_macro_identifier ::= identifier, and A.9.3 makes that
    // simple OR escaped. §2.8.1 drops the `\` and the terminating white space,
    // so the definition and the use key on the same bytes.
    try expectPp("\n3.0 *v", "`define \\MY-GAIN 3.0\n`\\MY-GAIN *v");
    // An escaped name can only be object-like, and that falls out of the two
    // rules rather than being a restriction of its own: §2.8.1 ends the name at
    // the first white space, while §10.4 requires the formal list's `(` to
    // touch the name, so `\SQ!(x)` is one nine-character name, not a call.
    try expectPp("\n1", "`define \\SQ!(x) 1\n`\\SQ!(x)");
    // §10.4: the macro text shall not begin with __VAMS_ ...
    try expectFail("`define MY_ENABLE __VAMS_ENABLE__\n", .E0139);
    // ... and the name is unrestricted, which is the other half of the pair.
    try expectPp("\n7.0", "`define __VAMS_USER 7.0\n`__VAMS_USER");
}

test "annex D prelude is deterministic and self-guarded" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = "`include \"disciplines.vams\"\nmodule m; endmodule\n";
    // One bag per run: the compilation unit must be the first file registered.
    var bag1: diag.Bag = .init(arena);
    var bag2: diag.Bag = .init(arena);
    const out_a = try process(arena, src, .{ .bag = &bag1 });
    const out_b = try process(arena, src, .{ .bag = &bag2 });
    const a = out_a.text;
    const b = out_b.text;
    try testing.expectEqualStrings(a, b);

    // annex D.1 reached the output exactly once, annex D.2 defined its macros.
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, a, "discipline electrical;"),
    );
    // The replayed prelude is the snapshot's text, byte for byte.
    const n1 = (try frontend.prelude.preludeSnapshot()).text.len;
    try testing.expect(std.mem.find(u8, a[0..n1], "nature Voltage;") != null);
    // The re-`include collapses to just the newlines it consumed (line numbers
    // inside an included file are preserved even when its guard empties it).
    try testing.expectEqualStrings(
        "module m; endmodule\n",
        std.mem.trimStart(u8, a[n1..], "\n"),
    );
}

// The snapshot's correctness condition: replaying it must leave `Pp` in the
// state `runStdDefs` leaves it in. Compares everything `Prelude` carries, so a
// prelude write `Prelude` does not capture fails here.
test "the prelude snapshot replays exactly what running annex D.2/D.1/E.1 produces" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Same starting state `process` and `buildPrelude` both establish.
    var bag: diag.Bag = .init(arena);
    var pp: Pp = .{ .arena = arena, .scratch = arena, .opts = .{ .bag = &bag } };
    _ = try bag.addFile("<source>", "");
    for (predefined_macros) |name| {
        try pp.macros.put(arena, name, .{ .body = "1", .predefined = true });
    }
    try pp.runStdDefs();

    const p = try frontend.prelude.preludeSnapshot();
    try testing.expectEqualStrings(pp.out.items, p.text);
    try testing.expectEqual(pp.segs.items.len, p.segs.len);
    for (pp.segs.items, p.segs) |a, b| {
        try testing.expectEqual(a.out_start, b.out_start);
        try testing.expectEqual(a.in_start, b.in_start);
        try testing.expectEqual(a.file, b.file);
    }
    // The macro sets agree, both ways. The difference is exactly §10.5's
    // predefined set, which the snapshot deliberately does not carry. Taken
    // from the array rather than written as a number, so adding one is not a
    // test edit.
    try testing.expectEqual(pp.macros.count(), p.macros.len + predefined_macros.len);
    for (p.macros) |d| {
        const live = pp.macros.get(d.name) orelse return error.MissingMacro;
        try testing.expectEqualStrings(live.body, d.macro.body);
        try testing.expectEqual(live.is_func, d.macro.is_func);
        try testing.expectEqual(live.params.len, d.macro.params.len);
    }
    // And the three file registrations the segments index by position, their
    // strip marks included, or a replayed file renders columns differently
    // from a freshly run one.
    for (p.files, 1..) |f, id| {
        try testing.expectEqualStrings(f.name, bag.fileName(@fromBackingInt(@intCast(id))));
        try testing.expectEqualStrings(f.stripped, bag.fileText(@fromBackingInt(@intCast(id))));
        try testing.expectEqualSlices(diag.StripMark, f.marks, bag.fileMarks(@fromBackingInt(@intCast(id))));
    }
}

// The token snapshot's correctness condition: lexing the whole text from
// offset 0, with no snapshot, matches the seeded result token for token.
// Two inputs, because with an annex E.2 netlist the prelude is followed by
// synthesized modules and the seed must still cover only the std-defs prefix.
test "the prelude token snapshot lexes exactly what lexing the whole text produces" {
    const cases = [_][]const u8{ "", ".MODEL nn npn\n.SUBCKT amp in out\nR1 in out 1k\n.ENDS\n" };
    for (cases) |netlist| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var bag: diag.Bag = .init(arena);
        const text = (try process(arena,
            \\module res(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  parameter real r = 1000.0 from (0.0:inf);
            \\  analog I(p, n) <+ V(p, n) / r;
            \\endmodule
        , .{ .bag = &bag, .spice_netlist = netlist })).text;

        // The long way: no seed, one scan of the whole buffer.
        const long = try lexer.tokenize(arena, text, null);
        const seeded = try lexer.tokenize(arena, text, try frontend.prelude.preludeTokens(true));

        try testing.expectEqual(long.len, seeded.len);
        try testing.expectEqualSlices(token.Tag, long.items(.tag), seeded.items(.tag));
        try testing.expectEqualSlices(u32, long.items(.start), seeded.items(.start));

        // The premise the seam rests on, checked rather than asserted in prose:
        // the snapshot's bytes are a prefix of the text, at offset 0.
        const p = try frontend.prelude.preludeSnapshot();
        try testing.expect(std.mem.startsWith(u8, text, p.text));
        // ...and the snapshot stops one token short of `.eof`, which belongs to
        // whatever buffer is actually being lexed.
        try testing.expect(p.tags.len != 0 and p.tags[p.tags.len - 1] != .eof);
    }
}

test "`--no-std-defs` gets no seed, and lexes the same either way" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    const text = (try process(arena, "module m; endmodule\n", .{ .std_defs = false, .bag = &bag })).text;

    try testing.expectEqual(@as(?lexer.Seed, null), try frontend.prelude.preludeTokens(false));
    try testing.expectEqual(@as(?*const Parser.Parser.Seed, null), try frontend.prelude.preludeAst(false));
    const long = try lexer.tokenize(arena, text, null);
    const seeded = try lexer.tokenize(arena, text, try frontend.prelude.preludeTokens(false));
    try testing.expectEqualSlices(token.Tag, long.items(.tag), seeded.items(.tag));
    try testing.expectEqualSlices(u32, long.items(.start), seeded.items(.start));
}

/// Expects `a` and `b` to be structurally equal, by reflection so a new AST
/// field is compared without a test edit. `[]u8` compares by content: the
/// snapshot's names and a fresh parse's borrow different copies of the text.
fn expectDeepEqual(comptime T: type, a: T, b: T) !void {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .one) return expectDeepEqual(p.child, a.*, b.*);
            comptime std.debug.assert(p.size == .slice);
            if (p.child == u8) return testing.expectEqualStrings(a, b);
            try testing.expectEqual(a.len, b.len);
            for (a, b) |x, y| try expectDeepEqual(p.child, x, y);
        },
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, F| {
            try expectDeepEqual(F, @field(a, name), @field(b, name));
        },
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            try testing.expectEqual(@as(Tag, a), @as(Tag, b));
            inline for (u.field_names, u.field_types) |name, F| {
                if (@as(Tag, a) == @field(Tag, name))
                    try expectDeepEqual(F, @field(a, name), @field(b, name));
            }
        },
        .optional => |o| {
            try testing.expectEqual(a == null, b == null);
            if (a) |x| try expectDeepEqual(o.child, x, b.?);
        },
        else => try testing.expectEqual(a, b),
    }
}

// The AST snapshot's correctness condition. The determinism test cannot grade
// it, since both of its runs take the cached path. So this parses the whole
// text from token 0 with no seed and compares against the seeded parse in
// full: the interner (contents, ids, map), every `ExprStore` column, the
// statement pool, all four declaration arrays, and the parser state outside
// `SourceFile` (`access_names`, `pos`, `gen_construct`). Two inputs, as for
// the token test.
test "the prelude AST snapshot parses exactly what parsing the whole text produces" {
    const cases = [_][]const u8{ "", ".MODEL nn npn\n.SUBCKT amp in out\nR1 in out 1k\n.ENDS\n" };
    for (cases) |netlist| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var bag: diag.Bag = .init(arena);
        const text = (try process(arena,
            \\nature Pressure;
            \\  units = "Pa"; access = Pr; abstol = 1e-6;
            \\endnature
            \\discipline fluid; potential Pressure; enddiscipline
            \\module res(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  parameter real r = 1000.0 from (0.0:inf);
            \\  real acc[0:2];
            \\  analog begin : body
            \\    integer k;
            \\    for (k = 0; k < 3; k = k + 1) acc[k] = k * 2.0;
            \\    I(p, n) <+ V(p, n) / r + acc[1];
            \\  end
            \\endmodule
        , .{ .bag = &bag, .spice_netlist = netlist })).text;

        var toks = try lexer.tokenize(arena, text, null);
        const tags = toks.items(.tag);
        const starts = toks.items(.start);

        // The long way: no seed, one parse of every token from 0.
        var lbag: diag.Bag = .init(arena);
        var lp = Parser.Parser.init(arena, text, tags, starts, &lbag);
        const long = try lp.parseSourceFile();

        var sbag: diag.Bag = .init(arena);
        const seed = (try frontend.prelude.preludeAst(true)).?;
        var sp = try Parser.Parser.initSeeded(arena, text, tags, starts, &sbag, seed);
        // The seed is doing something: the resumed parse starts deep in the file.
        try testing.expect(sp.pos > 2000 and sp.pos < tags.len - 1);
        const seeded = try sp.parseSourceFile();

        // --- the interner: same strings, at the same ids, and the same map ---
        try testing.expectEqual(long.strings.texts.items.len, seeded.strings.texts.items.len);
        try testing.expectEqual(long.strings.map.size, seeded.strings.map.size);
        for (long.strings.texts.items, seeded.strings.texts.items, 0..) |x, y, i| {
            try testing.expectEqualStrings(x, y);
            // The id is the claim, not just the membership: everything below the
            // parser addresses a name by its `StrId`.
            const id = seeded.strings.find(y) orelse return error.NameNotInMap;
            try testing.expectEqual(i, @backingInt(id));
        }

        // --- the expression store: every column of every row, and the three
        // side tables the rows index ---
        try testing.expectEqual(long.exprs.nodes.len, seeded.exprs.nodes.len);
        for (0..long.exprs.nodes.len) |i| {
            try expectDeepEqual(
                @TypeOf(long.exprs.nodes.get(0)),
                long.exprs.nodes.get(i),
                seeded.exprs.nodes.get(i),
            );
        }
        try testing.expectEqualSlices(u32, long.exprs.pool.items, seeded.exprs.pool.items);
        try testing.expectEqualSlices(f64, long.exprs.reals.items, seeded.exprs.reals.items);
        try testing.expectEqualDeep(long.exprs.ints.items, seeded.exprs.ints.items);

        // --- statements ---
        try testing.expectEqualSlices(u32, long.stmt_toks.items, seeded.stmt_toks.items);
        try expectDeepEqual(@TypeOf(long.stmts.items), long.stmts.items, seeded.stmts.items);
        try expectDeepEqual(@TypeOf(long.attributes.items), long.attributes.items, seeded.attributes.items);

        // --- all four declaration arrays, to their leaves ---
        try expectDeepEqual(@TypeOf(long.modules), long.modules, seeded.modules);
        try expectDeepEqual(@TypeOf(long.disciplines), long.disciplines, seeded.disciplines);
        try expectDeepEqual(@TypeOf(long.natures), long.natures, seeded.natures);
        try expectDeepEqual(@TypeOf(long.paramsets), long.paramsets, seeded.paramsets);

        // --- the parser state that is not in the SourceFile ---
        // A dropped access name turns a §4.4.1 branch probe into a §4.7 function
        // call silently, so the set is compared both ways.
        try testing.expectEqual(lp.access_names.size, sp.access_names.size);
        var it = lp.access_names.keyIterator();
        while (it.next()) |k| try testing.expect(sp.access_names.contains(k.*));
        try testing.expectEqual(lp.pos, sp.pos);
        try testing.expectEqual(lp.gen_construct, sp.gen_construct);
        try testing.expectEqual(lp.failed, sp.failed);
        try testing.expectEqual(@as(usize, 0), lbag.count() + sbag.count());
    }
}

test "an ABSTOL override reaches annex D.1" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    const text = (try process(
        arena_state.allocator(),
        "`define CURRENT_ABSTOL 1e-15\n`include \"disciplines.vams\"\n",
        .{ .std_defs = false, .bag = &bag },
    )).text;
    try testing.expect(std.mem.find(u8, text, "abstol      = 1e-15;") != null);
    try testing.expect(std.mem.find(u8, text, "abstol      = 1e-12;") == null);
}

test "a span inside an `include resolves to the included file's own line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag: diag.Bag = .init(arena);
    const src = "module m;\n`include \"disciplines.vams\"\nendmodule\n";
    const out = (try process(arena, src, .{ .std_defs = false, .bag = &bag })).text;

    // A byte that came from the included file.
    const needle = "discipline electrical;";
    const at: u32 = @intCast(std.mem.find(u8, out, needle).?);
    const r = bag.map.resolve(at);
    try testing.expectEqualStrings("disciplines.vams", bag.fileName(r.file));
    try testing.expect(r.file != .root);

    // ... at its line number, not one measured in the preprocessed text.
    const want = std.mem.countScalar(
        u8,
        frontend.annex_d.disciplines_vams[0..std.mem.find(u8, frontend.annex_d.disciplines_vams, needle).?],
        '\n',
    ) + 1;
    const idx = try diag.LineIndex.build(arena, bag.fileText(r.file));
    try testing.expectEqual(@as(u32, @intCast(want)), idx.loc(r.offset).line);
    try testing.expectEqualStrings(
        needle,
        bag.fileText(r.file)[r.offset..][0..needle.len],
    );

    // ... while the top-level file still resolves to itself, at line 1.
    const top = bag.map.resolve(@intCast(std.mem.find(u8, out, "module m;").?));
    try testing.expectEqual(diag.FileId.root, top.file);
    try testing.expectEqual(@as(u32, 0), top.offset);
    // ... and so does what follows the `include, despite the splice.
    const after = bag.map.resolve(@intCast(std.mem.find(u8, out, "endmodule").?));
    try testing.expectEqual(diag.FileId.root, after.file);
    try testing.expectEqualStrings("endmodule\n", src[after.offset..]);
}

test "a diagnostic after a comment renders the ORIGINAL line at the ORIGINAL column" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);

    // The error token sits after a block comment on its line. Its span indexes
    // the stripped text (the '`' is at stripped column 3); the strip marks put
    // the caret on the line the user wrote, at column 25.
    const src = "/* a leading comment */ `NOPE\n";
    try testing.expectError(
        error.PreprocessFailed,
        process(arena, src, .{ .std_defs = false, .bag = &bag }),
    );
    try testing.expectEqual(@as(usize, 1), bag.count());
    try testing.expectEqual(diag.Code.E0115, bag.at(0).code);

    var buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
    defer buf = aw.toArrayList();
    try diag.render(&bag, &aw.writer, .{ .explain_hint = false, .summary = false });
    const out = aw.writer.buffered();

    // The line drawn is the user's, comment included ...
    try testing.expect(std.mem.find(u8, out, "| /* a leading comment */ `NOPE") != null);
    // ... the column is measured in it: the '`' is byte 24, column 25 ...
    try testing.expect(std.mem.find(u8, out, ":1:25") != null);
    // ... and the caret row is indented to match: 24 spaces, then the span.
    try testing.expect(std.mem.find(u8, out, "|                         ^^^^^") != null);
}

test "a span inside a macro expansion resolves to the invocation site" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag: diag.Bag = .init(arena);
    const src = "`define SQ(x) ((x)*(x))\ny = `SQ(v) + 1;\n";
    const out = (try process(arena, src, .{ .std_defs = false, .bag = &bag })).text;

    // Bytes that exist only in the expansion have no counterpart in the file;
    // the honest answer is the `SQ that produced them.
    const inside: u32 = @intCast(std.mem.findScalar(u8, out, '*').?);
    const r = bag.map.resolve(inside);
    try testing.expectEqual(diag.FileId.root, r.file);
    try testing.expect(std.mem.startsWith(u8, src[r.offset..], "`SQ(v)"));
    try testing.expectEqualStrings("SQ", bag.map.segs[r.seg].macro);

    // ... and the text after the expansion is verbatim again.
    const after = bag.map.resolve(@intCast(std.mem.find(u8, out, "+ 1").?));
    try testing.expectEqualStrings("+ 1;\n", src[after.offset..]);
}

test "IEEE 1364 §19.3.1: an escaped-identifier actual keeps its terminator" {
    // §2.8.1: white space ends an escaped identifier. `macroArgs` trims the
    // actual, so substitution puts one space back after it.
    try expectPreserved("`define ID(A) (A)\n`ID(\\a.b )\n", &.{"(\\a.b )"}, &.{});
    // A string's escape sequence is not an escaped identifier.
    try expectPreserved("`define ID(A) (A)\n`ID(\"x\\n\")\n", &.{"(\"x\\n\")"}, &.{});
}

test "§2.9 attribute owners survive a seeded parse and later attribute lists" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const prefix = "(* module_attr = 3 *) module first; (* item_attr *) integer x; endmodule\n";
    const source = prefix ++ "(* module_attr = 4 *) module second; analog (* stmt_attr *) begin end endmodule\n";
    var pt = try lexer.tokenize(arena, prefix, null);
    var pb: diag.Bag = .init(arena);
    var pp = Parser.Parser.init(arena, prefix, pt.items(.tag), pt.items(.start), &pb);
    const seed: Parser.Parser.Seed = .{
        .file = try pp.parseSourceFile(),
        .access_names = &.{},
        .pos = pp.pos,
        .gen_construct = pp.gen_construct,
    };
    var tokens = try lexer.tokenize(arena, source, null);
    var sb: diag.Bag = .init(arena);
    var sp = try Parser.Parser.initSeeded(arena, source, tokens.items(.tag), tokens.items(.start), &sb, &seed);
    const resumed = try sp.parseSourceFile();
    var lb: diag.Bag = .init(arena);
    var lp = Parser.Parser.init(arena, source, tokens.items(.tag), tokens.items(.start), &lb);
    const whole = try lp.parseSourceFile();
    try testing.expect(!pp.failed and !sp.failed and !lp.failed);
    try testing.expect(whole.attributes.items.len > seed.file.attributes.items.len);
    try expectDeepEqual(@TypeOf(whole.attributes.items), whole.attributes.items, resumed.attributes.items);
    try expectDeepEqual(@TypeOf(whole.modules), whole.modules, resumed.modules);
}

// ---------------------------------------------------------------------------
// Unit test plan. Each bug class, the oracle that sees it, and where it runs.
//
//   text wrong but plausible (a formal substituted into a string or a number,
//   a comment surviving, an arm taken that should not be)
//       -> the expected text derived by hand from the clause (`expectPp`)
//   line contract broken (output newlines != input newlines)
//       -> the newline counts compared, on hand cases and on every input of
//          the snippet generator ("every successful run keeps ...")
//   provenance corrupt (segments out of order, a span naming the wrong file)
//       -> segments sorted by `out_start`; every preprocess span inside the
//          file it names (`expectFail`, `expectSortedMap`)
//   strip marks wrong (a caret in the wrong column)
//       -> every kept byte equals the raw byte its mark maps to; stripping a
//          stripped text changes nothing (seeded property)
//   a refusal missing or spurious
//       -> one case per named code, each with a legal neighbour
//   a limit off by one (E0119, E0125)
//       -> the case at the limit and the case one past it
//   vector scan differs from scalar -> the scalar loop (differential, above)
//   region lookup wrong -> a forward scan, exhaustive over small lists
//   allocation failure swallowed or leaked -> `checkAllAllocationFailures`
//
// The generators are seeded `DefaultPrng` loops, so `zig build test` runs
// them in full and a failure replays.
// ---------------------------------------------------------------------------

/// Expects the source map's segments in `out_start` order, which
/// `SourceMap.resolve`'s binary search requires.
fn expectSortedMap(bag: *const diag.Bag) !void {
    const segs = bag.map.segs;
    for (segs[0..segs.len -| 1], segs[@min(1, segs.len)..]) |a, b| {
        try testing.expect(a.out_start <= b.out_start);
    }
}

/// Expects every published event list in text-stream order and inside `text`.
fn expectSortedEvents(d: directive_events.Directives, text: []const u8) !void {
    inline for (@typeInfo(directive_events.Directives).@"struct".field_names) |name| {
        const list = @field(d, name);
        for (list, 0..) |e, k| {
            try testing.expect(e.at <= text.len);
            if (k > 0) try testing.expect(list[k - 1].at <= e.at);
        }
    }
}

/// The `timescale in force at the end of `src`, preprocessed without the prelude.
fn timescaleOf(src: []const u8) !?Timescale {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    return (try process(arena_state.allocator(), src, .{ .std_defs = false, .bag = &bag })).directives.timescale();
}

test "§2.4 comment corners: end of file, `/*/`, and markers inside opaque tokens" {
    // A `//` comment may end the file.
    try expectPp("a", "a// x");
    // `/*/` opens a comment and does not close it: the `*` a close needs is
    // the opener's own (§2.4: "begin with /* and end with */").
    try expectFail("/*/", .E0102);
    // The shortest block comment is four bytes and leaves its separator (§2.2).
    try expectPp("a b", "a/**/b");
    // §2.8.1: an escaped identifier runs to white space, so a `//` inside one
    // is part of the name.
    try expectPp("\\a//b c", "\\a//b c");
    // §2.7: an escaped quote does not end a string, so the `//` after it is
    // still inside the literal.
    try expectPp("\"a\\\"//b\"", "\"a\\\"//b\"");
    // A `//` comment runs to the LF, so the CR of a CRLF line goes with it.
    try expectPp("a\nb", "a//c\r\nb");
    // An unterminated string ends at its line (the lexer reports it), and the
    // comment on the next line is still stripped.
    try expectPp("\"abc\n\nx", "\"abc\n// c\nx");
    // IEEE 1364 §19.3.1: a `//` comment in macro text is dropped, but the `\`
    // ending it still continues the macro. Outside a `define the `\` goes with
    // the comment.
    try expectPp("\n\na b\n", "`define M a // c \\\n  b\n`M\n");
    try expectPp("\n\n\na b\n", "`define M \\\n  a // c \\\n  b\n`M\n");
    try expectPp("a \nb", "a // c \\\nb");
}

test "stripComments: every kept byte maps back to itself, and stripping twice changes nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // By hand first. `ab/*c*/d`: the comment becomes one space at stripped
    // offset 2, and from stripped offset 3 the texts run in lockstep with the
    // raw text from offset 7, which is one mark. `x//c\ny`: the line comment
    // leaves nothing, and stripped 1 (the LF) is raw 4.
    {
        var bag: diag.Bag = .init(arena);
        var pp: Pp = .{ .arena = arena, .scratch = arena, .opts = .{ .bag = &bag } };
        _ = try bag.addFile("<source>", "ab/*c*/d");
        const s = try frontend.pp_comments.stripComments(&pp, "ab/*c*/d");
        try testing.expectEqualStrings("ab d", s.text);
        try testing.expectEqualSlices(diag.StripMark, &.{.{ .out = 3, .src = 7 }}, s.marks);
        const l = try frontend.pp_comments.stripComments(&pp, "x//c\ny");
        try testing.expectEqualStrings("x\ny", l.text);
        try testing.expectEqualSlices(diag.StripMark, &.{.{ .out = 1, .src = 4 }}, l.marks);
    }

    // Then every short text over the bytes the stripper branches on.
    var prng: std.Random.DefaultPrng = .init(0xc0ffee);
    const rand = prng.random();
    const alphabet = "a /*\n\"\\";
    var buf: [48]u8 = undefined;
    for (0..4000) |_| {
        const raw = buf[0..rand.uintAtMost(usize, buf.len)];
        for (raw) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];

        var bag: diag.Bag = .init(arena);
        var pp: Pp = .{ .arena = arena, .scratch = arena, .opts = .{ .bag = &bag } };
        const id = try bag.addFile("<source>", raw);
        const s = frontend.pp_comments.stripComments(&pp, raw) catch |e| switch (e) {
            error.PreprocessFailed => continue, // E0102, an unclosed `/*`
            error.OutOfMemory => return e,
        };
        bag.setStrippedText(id, s.text, s.marks);

        // §2.4 keeps a comment's newlines, and nothing grows.
        try testing.expectEqual(std.mem.countScalar(u8, raw, '\n'), std.mem.countScalar(u8, s.text, '\n'));
        try testing.expect(s.text.len <= raw.len);
        // A comment's replacement is a space or newlines; every other byte is a
        // verbatim copy, found where the marks say.
        for (s.text, 0..) |c, k| {
            if (c == ' ' or c == '\n') continue;
            try testing.expectEqual(c, raw[bag.toSourceOffset(id, @intCast(k))]);
        }
        // No comment survives, and none is made: a kept `/` was not followed by
        // `/` or `*` (it would have opened a comment), and a replacement is
        // white space.
        var bag2: diag.Bag = .init(arena);
        var pp2: Pp = .{ .arena = arena, .scratch = arena, .opts = .{ .bag = &bag2 } };
        _ = try bag2.addFile("<source>", s.text);
        const again = try frontend.pp_comments.stripComments(&pp2, s.text);
        try testing.expectEqualStrings(s.text, again.text);
        try testing.expectEqual(@as(usize, 0), again.marks.len);
    }
}

test "§2.7 strings and §2.8.1 escaped identifiers are opaque to the scan" {
    // A live unterminated string is the lexer's to report; the preprocessor
    // passes it through.
    try expectPp("\"abc\nx", "\"abc\nx");
    // A backtick inside either is not a macro use.
    try expectPp("\"`NOPE\" \\a`b c", "\"`NOPE\" \\a`b c");
    // IEEE 1364 §19.4: an ignored group still follows the lexical rules, so an
    // unterminated string inside one is E0138 ...
    try expectFail("`ifdef N\n\"abc\n`endif\n", .E0138);
    // ... and a string continued with `\`+newline is one token, whose newline
    // the dead arm keeps.
    try expectPreserved("`ifdef N\n\"a\\\nb\"\n`endif\n", &.{}, &.{ "a", "b" });
}

test "a grave accent needs a name, except inside an inactive arm" {
    try expectFail("`\n", .E0103);
    try expectFail("` x\n", .E0103);
    // A backslash with no body is no escaped name either (§2.8.1).
    try expectFail("`\\ x\n", .E0103);
    try expectPp("\n\n\n", "`ifdef N\n` x\n`endif\n");
}

test "IEEE 1364 §19.4: the first true arm wins, a dead parent kills every arm, and text may follow the operand" {
    try expectPreserved("`define A\n`define B\n`ifdef A\na\n`elsif B\nb\n`else\nc\n`endif\n", &.{"a"}, &.{ "b", "c" });
    try expectPreserved("`ifdef N\n`ifdef M\nx\n`else\ny\n`endif\n`endif\n", &.{}, &.{ "x", "y" });
    try expectPreserved("`ifdef N\n`elsif N\nx\n`elsif __VERA__\ny\n`endif\n", &.{"y"}, &.{"x"});
    // Syntax 19-5 ends a conditional directive with its operand; the rest of
    // the line is source in the arm it opens.
    try expectPp("\n x\n\n", "`define A\n`ifdef A x\n`endif\n");
    // `else takes no operand, so the rest of its line is source.
    try expectPreserved("`ifdef N\n`else junk\n`endif\n", &.{"junk"}, &.{});
    try expectFail("`else\n", .E0105);
    try expectFail("`elsif A\n", .E0105);
    try expectFail("`ifdef A\n`elsif\n`endif\n", .E0107);
    try expectFail("`ifdef A\n`else\n`elsif B\n`endif\n", .E0106);
    try expectFail("`ifndef\n", .E0104);
    // A `define in a dead arm defines nothing.
    try expectPreserved("`ifdef N\n`define X\n`endif\n`ifdef X\nyes\n`endif\n", &.{}, &.{"yes"});
}

test "E0101 points at the end of the file and labels the `ifdef it leaves open" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    const src = "x\n`ifdef A\ny\n";
    try testing.expectError(error.PreprocessFailed, process(arena, src, .{ .std_defs = false, .bag = &bag }));
    const e = bag.at(0);
    try testing.expectEqual(diag.Code.E0101, e.code);
    try testing.expectEqual(@as(u32, src.len), e.span.start);
    var buf: [diag.max_children]diag.Label = undefined;
    const labels = bag.labels(e, &buf);
    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings("`ifdef", src[labels[0].span.start..labels[0].span.end]);
}

test "two directives with no text between them publish at one offset, and the later is in force" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const r = try regionsOf(arena_state.allocator(), "`celldefine`endcelldefine\n");
    try testing.expectEqual(@as(usize, 2), r.cells.len);
    try testing.expectEqual(r.cells[0].at, r.cells[1].at);
    try testing.expect(!CellRegion.inForce(r.cells, r.cells[0].at, false));
}

test "§10.4 definitions: redefinition, empty text, empty lists and the formal list's grammar" {
    // §10.4: a redefinition replaces.
    try expectPp("\n\n2", "`define A 1\n`define A 2\n`A");
    try expectPp("\n[]", "`define E\n[`E]");
    // `Z()` has a formal list with nothing in it: `Z()` uses it, `Z` and
    // `Z(1)` do not.
    try expectPp("\nz", "`define Z() z\n`Z()");
    try expectFail("`define Z() z\n`Z\n", .E0116);
    try expectFail("`define Z() z\n`Z(1)\n", .E0117);
    // One formal, one empty actual.
    try expectPp("\n[]", "`define I(x) [x]\n`I()");
    // Syntax 10-3's list_of_formal_arguments, one code per way to break it.
    try expectFail("`define M(\n", .E0110);
    try expectFail("`define M(1) x\n", .E0110);
    try expectFail("`define M(a\n", .E0111);
    try expectFail("`define M(a b) x\n", .E0112);
    // formal_argument_identifier is a simple_identifier, whose first character
    // is not `$` (§2.8), and `{ , formal_argument_identifier }` needs a formal
    // after every comma.
    try expectFail("`define M($x) $x\n", .E0110);
    try expectFail("`define M(a,) a\n", .E0110);
    try expectFail("`define M(,a) a\n", .E0110);
    // The text continues across `\`+newline as one space, the continuation's
    // indentation and a CR before the newline included.
    try expectPp("\n\na b", "`define P a \\\n   b\n`P");
    try expectPp("\n\na b", "`define P a\\\r\nb\n`P");
    // `undef of a name never defined is not an error: §10.4 sets no rule.
    try expectPp("\nx", "`undef NOPE\nx");
    try expectFail("`undef\n", .E0113);
    try expectFail("`define\n", .E0109);
}

test "IEEE 1364 §19.3.1 substitution: what a formal is not" {
    // The name after a '`' is a macro use, never a formal.
    try expectPp("\n\n9", "`define x 9\n`define M(x) `x\n`M(1)");
    // A number is one token, so its exponent letter is no formal.
    try expectPp("\n1e-3+2", "`define M(e) 1e-3+e\n`M(2)");
    // A comma or parenthesis inside a string actual does not split it.
    try expectPp("\n\"a,b)\"|c", "`define A(p,q) p|q\n`A(\"a,b)\", c)");
    // A directive in macro text runs when the text is rescanned.
    try expectPp("\n\n7\n", "`define D `define X 7\n`D\n`X\n");
}

test "IEEE 1364 §19.3.1: an actual that spans lines keeps the output's line count" {
    // The invocation re-emits the newlines of its whole span after the
    // expansion, so a newline inside an actual is white space between tokens
    // (a space), or it would be emitted twice.
    try expectPp("\n[a +b]\n\nz\n", "`define M(x) [x]\n`M(a\n+b)\nz\n");
    // The same through a nested use, whose span is inside the outer one's.
    try expectPp("\n\n[1+2]\n\n", "`define N(a,b) a+b\n`define M(x) [x]\n`M(`N(1,\n2))\n");
}

test "§10.7 `__LINE__ in macro text and arguments is the invocation's line, `__FILE__ a string literal" {
    try expectPp("\n\n3\n", "`define L `__LINE__\n\n`L\n");
    try expectPp("\n2\n\n", "`define I(x) x\n`I(\n`__LINE__)\n");
    // Neither name is in the macro table, so `undef changes nothing.
    try expectPp("\n2", "`undef __LINE__\n`__LINE__");
    // §2.7 escapes the two bytes a file name may hold that a string literal
    // cannot hold bare.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    const out = try process(arena, "`__FILE__", .{ .std_defs = false, .bag = &bag, .file_name = "a\"b\\c.va" });
    try testing.expectEqualStrings("\"a\\\"b\\\\c.va\"", out.text);
}

test "IEEE 1364 §19.7: only white space shares a `line directive's line" {
    // "However, only white space may appear on the same line as the `line
    // directive. Comments are not allowed on the same line as a `line
    // directive." Legal: indentation before it, comments on the lines around.
    try expectPp("  \n3\n", "  `line 3 \"f\" 0\n`__LINE__\n");
    try expectPp("\n\n3\n", "// c\n`line 3 \"f\" 0\n`__LINE__\n");
    try expectPp("\n\n\n3\n", "/* a\n b */\n`line 3 \"f\" 0\n`__LINE__\n");
    // Refused: a comment that ends where the line starts, one that opens
    // after the level and runs on, and other text before the directive.
    try expectFail("/* a\n*/`line 3 \"f\" 0\n", .E0128);
    try expectFail("`line 3 \"f\" 0 /* a\nb */\n", .E0128);
    try expectFail("x `line 3 \"f\" 0\n", .E0128);
    // The number is a positive integer that fits, and the name is closed.
    try expectFail("`line 4294967296 \"f\" 0\n", .E0128);
    try expectFail("`line 3 \"f 0\n", .E0128);
}

test "IEEE 1364 §19.5 `include operand errors, and the annex D files by basename" {
    try expectFail("`include\n", .E0121);
    try expectFail("`include \"abc\n", .E0123);
    try expectFail("`include \"\"\n", .E0124);
    // VD-091: a built-in is found by its basename wherever the name points.
    const got = try runTest("`include \"no/such/dir/constants.vams\"\n`M_PI\n");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.find(u8, got, "3.14159265358979323846") != null);

    // VD-096: only annex D.1, under either name, is the source asking for
    // annex D's natures.
    const cases = [_]struct { name: []const u8, d1: bool }{
        .{ .name = "disciplines.vams", .d1 = true },
        .{ .name = "discipline.h", .d1 = true },
        .{ .name = "constants.vams", .d1 = false },
        .{ .name = "constants.h", .d1 = false },
    };
    for (cases) |c| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var bag: diag.Bag = .init(arena);
        const src = try arena.print("`include \"{s}\"\n", .{c.name});
        const out = try process(arena, src, .{ .std_defs = false, .bag = &bag });
        try testing.expectEqual(c.d1, out.annex_d_included);
    }
}

test "IEEE 1364 §19.5: include nesting is unbounded; only a repeating cycle is E0125" {
    // A chain of 40 files (past the old cap of 32), each including the
    // next; then one file including itself under a guard that defines one
    // more macro each time, 301 deep, which a cap on the path alone would
    // call a cycle; then a file including itself unchanged, the one nesting
    // that never ends.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var name_buf: [16]u8 = undefined;
    var data_buf: [32]u8 = undefined;
    const chain = 40;
    for (0..chain) |k| {
        const name = try std.mem.print(&name_buf, "a{d}.vh", .{k});
        const data = if (k + 1 == chain) "deepest\n" else try std.mem.print(&data_buf, "`include \"a{d}.vh\"\n", .{k + 1});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
    }
    var guard: std.ArrayList(u8) = .empty;
    defer guard.deinit(testing.allocator);
    const depth = 300;
    for (0..depth) |k| try guard.print(testing.allocator, "`ifndef L{d}\n`define L{d}\n`else\n", .{ k, k });
    try guard.appendSlice(testing.allocator, "bottom\n`define DONE\n");
    for (0..depth) |_| try guard.appendSlice(testing.allocator, "`endif\n");
    try guard.appendSlice(testing.allocator, "`ifndef DONE\n`include \"self.vh\"\n`endif\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "self.vh", .data = guard.items });
    try tmp.dir.writeFile(io, .{ .sub_path = "loop.vh", .data = "x\n`include \"loop.vh\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "p.vh", .data = "`include \"q.vh\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "q.vh", .data = "`include \"p.vh\"\n" });
    const first = try tmp.dir.realPathFileAlloc(io, "a0.vh", testing.allocator);
    defer testing.allocator.free(first);
    const dirs: []const []const u8 = &.{std.fs.path.dirname(first).?};

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ok_bag: diag.Bag = .init(arena);
    const out = try process(arena, "`include \"a0.vh\"\n", .{ .std_defs = false, .bag = &ok_bag, .include_dirs = dirs });
    try testing.expect(std.mem.find(u8, out.text, "deepest") != null);
    var self_bag: diag.Bag = .init(arena);
    const self_out = try process(arena, "`include \"self.vh\"\n", .{ .std_defs = false, .bag = &self_bag, .include_dirs = dirs });
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, self_out.text, "bottom"));

    for ([_][]const u8{ "loop.vh", "p.vh" }) |f| {
        var bag: diag.Bag = .init(arena);
        const src = try arena.print("`include \"{s}\"\n", .{f});
        try testing.expectError(error.PreprocessFailed, process(arena, src, .{ .std_defs = false, .bag = &bag, .include_dirs = dirs }));
        try testing.expectEqual(@as(usize, 1), bag.count());
        try testing.expectEqual(diag.Code.E0125, bag.at(0).code);
    }
}

// Left out of a Windows build: the test makes a sparse file past 4 GiB,
// and NTFS would allocate it.
comptime {
    if (@import("builtin").os.tag != .windows) _ = sparse_files;
}
const sparse_files = struct {
    test "IEEE 1364 §19.5: an `include past the u32 text bound is E1013, known from the file's size" {
        // A sparse file one byte past `max_text_bytes`: its size is read, not
        // its bytes, so the test allocates nothing large.
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        {
            var f = try tmp.dir.createFile(io, "huge.vh", .{});
            defer f.close(io);
            try f.setLength(io, preprocessor.max_text_bytes + 1);
        }
        try tmp.dir.writeFile(io, .{ .sub_path = "big.vh", .data = "" });
        const any = try tmp.dir.realPathFileAlloc(io, "big.vh", testing.allocator);
        defer testing.allocator.free(any);
        const dirs: []const []const u8 = &.{std.fs.path.dirname(any).?};
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        var bag: diag.Bag = .init(arena_state.allocator());
        try testing.expectError(error.PreprocessFailed, process(arena_state.allocator(), "`include \"huge.vh\"\n", .{ .std_defs = false, .bag = &bag, .include_dirs = dirs }));
        try testing.expectEqual(diag.Code.E1013, bag.at(0).code);
        // 17 MiB, past the old 16 MiB `include cap, reads.
        {
            var f = try tmp.dir.createFile(io, "big.vh", .{});
            defer f.close(io);
            try f.setLength(io, 17 << 20);
        }
        var ok_bag: diag.Bag = .init(arena_state.allocator());
        const out = try process(arena_state.allocator(), "`include \"big.vh\"\n", .{ .std_defs = false, .bag = &ok_bag, .include_dirs = dirs });
        try testing.expect(out.text.len >= 17 << 20);
    }
};

test "§10.7: a file included through a macro numbers its own lines and owns its diagnostics" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines.vh", .data = "`define FROM_INC 5\n\n`__LINE__\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.vh", .data = "\n\n`NOPE\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "word.vh", .data = "wire_from_inc\n" });
    const any = try tmp.dir.realPathFileAlloc(io, "lines.vh", testing.allocator);
    defer testing.allocator.free(any);
    const dirs: []const []const u8 = &.{std.fs.path.dirname(any).?};

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // "An `include directive changes the expansions of `__FILE__ and `__LINE__
    // to correspond to the included file": the `__LINE__ on line 3 of
    // lines.vh is 3, wherever the `include was written.
    {
        var bag: diag.Bag = .init(arena);
        const out = try process(arena, "`define INC `include \"lines.vh\"\n`INC\n`FROM_INC\n", .{ .std_defs = false, .bag = &bag, .include_dirs = dirs });
        try testing.expectEqualStrings("\n\n\n3\n\n5\n", out.text);
        try expectSortedMap(&bag);
    }
    // A diagnostic raised inside that file is in that file, on its own line.
    {
        var bag: diag.Bag = .init(arena);
        try testing.expectError(error.PreprocessFailed, process(arena, "`define INC `include \"bad.vh\"\n`INC\n", .{ .std_defs = false, .bag = &bag, .include_dirs = dirs }));
        const e = bag.at(0);
        try testing.expectEqual(diag.Code.E0115, e.code);
        try testing.expectEqualStrings("bad.vh", std.fs.path.basename(bag.fileName(e.file)));
        const text = bag.fileText(e.file);
        try testing.expect(e.span.end <= text.len);
        try testing.expectEqualStrings("`NOPE", text[e.span.start..e.span.end]);
    }
    // Through an actual, the included text is part of the expansion: it maps
    // to the invocation like every other expanded byte, and the map stays
    // sorted.
    {
        var bag: diag.Bag = .init(arena);
        const src = "`define INC `include \"word.vh\"\n`define ID(x) x\n`ID(`INC) tail\n";
        const out = try process(arena, src, .{ .std_defs = false, .bag = &bag, .include_dirs = dirs });
        try expectSortedMap(&bag);
        const r = bag.map.resolve(@intCast(std.mem.find(u8, out.text, "wire_from_inc").?));
        try testing.expectEqual(diag.FileId.root, r.file);
        try testing.expect(std.mem.startsWith(u8, src[r.offset..], "`ID("));
        const tail = bag.map.resolve(@intCast(std.mem.find(u8, out.text, "tail").?));
        try testing.expectEqualStrings("tail\n", src[tail.offset..]);
    }
}

test "every successful run keeps the line count and leaves sorted provenance" {
    // Swarm-style: random sequences of whole-line snippets. Sequences that
    // break a rule (an `else with no `ifdef, an unclosed string actual) fail
    // with a diagnostic and are skipped. Every one that succeeds must give the
    // output exactly the newlines of the files it read (the unit and each
    // `include, a re-read one again) and publish sorted segments and events.
    const snippets = [_][]const u8{
        "`define A 1\n",
        "`define F(x) [x]\n",
        "`define G(y) `F(y)\n",
        "`define B \\\n 2\n",
        "`A\n",
        "`B\n",
        "`F(a)\n",
        "`F(a\nb)\n",
        "`G(b\nc)\n",
        "`F(`A\n)\n",
        "`F(`F(\nz))\n",
        "`F(\"s\n",
        "/* c\n */\n",
        "// c\n",
        "x y\n",
        "\"s\"\n",
        "`ifdef A\n",
        "`ifndef A\n",
        "`else\n",
        "`endif\n",
        "`undef A\n",
        "`timescale 1ns/1ps\n",
        "`celldefine\n",
        "`endcelldefine\n",
        "`default_nettype none\n",
        "`resetall\n",
        "`__LINE__\n",
        "`include \"constants.vams\"\n",
    };
    var prng: std.Random.DefaultPrng = .init(0x11e5);
    const rand = prng.random();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (0..3000) |_| {
        src.clearRetainingCapacity();
        for (0..rand.uintAtMost(usize, 12)) |_| {
            try src.appendSlice(testing.allocator, snippets[rand.uintLessThan(usize, snippets.len)]);
        }
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var bag: diag.Bag = .init(arena);
        const out = process(arena, src.items, .{ .std_defs = false, .bag = &bag }) catch |e| switch (e) {
            error.PreprocessFailed => continue,
            error.OutOfMemory => return e,
        };
        var want: usize = 0;
        for (bag.files.items) |f| want += std.mem.countScalar(u8, f.text, '\n');
        try testing.expectEqual(want, std.mem.countScalar(u8, out.text, '\n'));
        try expectSortedMap(&bag);
        try expectSortedEvents(out.directives, out.text);
    }
}

test "IEEE 1364 §19.3.1: every directive name is refused as a macro name, escaped or not" {
    // §2.8.1: `\include` is the identifier `include`.
    for (frontend.pp_directive.directive_map.keys()) |name| {
        for ([_][]const u8{ "", "\\" }) |prefix| {
            const src = try testing.allocator.print("`define {s}{s} 1\n", .{ prefix, name });
            defer testing.allocator.free(src);
            try expectFail(src, .E0143);
        }
    }
}

test "IEEE 1364 §19.8 Table 19-1: every magnitude and unit reads back as its exact decimal" {
    // The oracle is the literal `1e<n>` read by `std.fmt.parseFloat`, which
    // rounds correctly; the code under test reads a table instead.
    const mags = [_]struct { text: []const u8, exp: i32 }{
        .{ .text = "1", .exp = 0 },
        .{ .text = "10", .exp = 1 },
        .{ .text = "100", .exp = 2 },
    };
    const units = [_]struct { text: []const u8, exp: i32 }{
        .{ .text = "s", .exp = 0 },
        .{ .text = "ms", .exp = -3 },
        .{ .text = "us", .exp = -6 },
        .{ .text = "ns", .exp = -9 },
        .{ .text = "ps", .exp = -12 },
        .{ .text = "fs", .exp = -15 },
    };
    var buf: [16]u8 = undefined;
    for (mags) |m| {
        for (units) |u| {
            const want = try std.fmt.parseFloat(f64, try std.mem.print(&buf, "1e{d}", .{m.exp + u.exp}));
            // 1 fs is the finest precision, so it is never coarser than the unit.
            const src = try testing.allocator.print("`timescale {s}{s}/1fs\n", .{ m.text, u.text });
            defer testing.allocator.free(src);
            const t = (try timescaleOf(src)).?;
            try testing.expectEqual(want, t.unit);
            try testing.expectEqual(@as(f64, 1e-15), t.precision);
        }
    }
    // Equal unit and precision is "at least as precise".
    try testing.expectEqual(@as(f64, 1e-9), (try timescaleOf("`timescale 1ns/1ns\n")).?.precision);
    // A leading zero is not on the grid.
    try expectFail("`timescale 01ns/1ps\n", .E0142);
}

test "E0142's notes cite IEEE 1364-2005 §19.8, the `timescale clause" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "`timescale 2ns/1ps\n", "`timescale 1ps/1ns\n" }) |src| {
        var bag: diag.Bag = .init(arena);
        try testing.expectError(error.PreprocessFailed, process(arena, src, .{ .std_defs = false, .bag = &bag }));
        var buf: [diag.max_children]diag.Note = undefined;
        const notes = bag.notes(bag.at(0), &buf);
        try testing.expect(notes.len != 0);
        try testing.expect(std.mem.find(u8, notes[0].text, "§19.8") != null);
        for (notes) |n| try testing.expect(std.mem.find(u8, n.text, "§19.9") == null);
    }
}

test "§10.2 `default_discipline publishes its name and qualifier, and `resetall withdraws it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    const d = (try process(arena, "`default_discipline \\logic wreal\n`default_discipline\n`resetall\n", .{
        .std_defs = false,
        .bag = &bag,
    })).directives.disciplines;
    try testing.expectEqual(@as(usize, 3), d.len);
    try testing.expectEqualStrings("logic", d[0].discipline);
    try testing.expectEqual(@as(?Qualifier, .wreal), d[0].qualifier);
    try testing.expectEqualStrings("", d[1].discipline);
    try testing.expectEqual(@as(?Qualifier, null), d[1].qualifier);
    try testing.expectEqualStrings("", d[2].discipline);
    // Each at the output offset where its directive's text ended: the two
    // collapsed lines leave one newline each before the next.
    try testing.expectEqual(@as(u32, 0), d[0].at);
    try testing.expectEqual(@as(u32, 1), d[1].at);
    try testing.expectEqual(@as(u32, 2), d[2].at);
}

test "IEEE 1364 §19.6: `resetall writes one default event to every list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    const out = try process(arena, "`resetall\n", .{ .std_defs = false, .bag = &bag });
    // The word itself is passed through for the parser (§19.6 refuses it
    // inside a module).
    try testing.expectEqualStrings("`resetall\n", out.text);
    const d = out.directives;
    inline for (@typeInfo(directive_events.Directives).@"struct".field_names) |name| {
        try testing.expectEqual(@as(usize, 1), @field(d, name).len);
    }
    try testing.expectEqual(NetType.wire, d.nettypes[0].value);
    try testing.expect(!d.cells[0].value);
    try testing.expectEqual(Drive.float, d.drives[0].value);
    try testing.expectEqual(@as(?f64, null), d.transitions[0].value);
    try testing.expectEqual(@as(?Timescale, null), d.timescales[0].value);
    try testing.expectEqualStrings("", d.disciplines[0].discipline);
}

test "§10.3: zero is a transition time, infinity and NaN are not" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    const t = (try process(arena, "`default_transition 0\n", .{ .std_defs = false, .bag = &bag })).directives.transitions;
    try testing.expectEqual(@as(?f64, 0.0), t[0].value);
    try expectFail("`default_transition 1e400\n", .E0129);
    try expectFail("`default_transition inf\n", .E0129);
    try expectFail("`default_transition nan\n", .E0129);
    // §2.6: the operand is one Verilog number. `std.fmt.parseFloat` also
    // reads C's hex floats and a point with no digit after it (§2.6.2 wants
    // one on each side), and drops a leading `_` (§2.6.1 forbids it first).
    for ([_][]const u8{ "0x10", "1.", ".5", "_1", "1e", "-", "4n4" }) |op| {
        const src = try testing.allocator.print("`default_transition {s}\n", .{op});
        defer testing.allocator.free(src);
        try expectFail(src, .E0129);
    }
    // A sign is a unary operator on the number, so `+4n` is a time.
    const plus = (try process(arena, "`default_transition +4n\n", .{ .std_defs = false, .bag = &bag })).directives.transitions;
    try testing.expectEqual(@as(?f64, 4e-9), plus[0].value);
}

test "IEEE 1364-2005 §13.4.1: files given together are one text stream" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    // A macro and an open `ifdef cross into the next file, `__FILE__ names
    // that file, and a newline keeps `a` and `2` two tokens.
    const out = try process(arena, "`define W 2\n`ifdef W\na", .{
        .std_defs = false,
        .bag = &bag,
        .more = &.{.{ .name = "b.v", .text = "`W `__FILE__\n`endif\n" }},
    });
    try testing.expectEqualStrings("\n\na\n2 \"b.v\"\n\n", out.text);
    try testing.expectEqualSlices(u32, &.{4}, out.more_starts);
}

test "E0115 suggests the nearest defined macro, backtick restored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    const src = "`define GAIN 1\n`GAN\n";
    try testing.expectError(error.PreprocessFailed, process(arena, src, .{ .std_defs = false, .bag = &bag }));
    var buf: [diag.max_children]diag.Note = undefined;
    const notes = bag.notes(bag.at(0), &buf);
    try testing.expectEqual(@as(usize, 1), notes.len);
    const fix = notes[0].fix.?;
    try testing.expectEqualStrings("`GAIN", fix.replacement);
    try testing.expectEqualStrings("`GAN", src[fix.span.start..fix.span.end]);
}

// `require_std_includes`, the conformance suite's convention and `vera`'s:
// the prelude is still prepended, but a source reaches annex D only by
// including it.
const std_model =
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0.0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
;
/// `std_model` reading annex D.2's `M_PI.
const pi_model =
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 * `M_PI from (0.0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
;
const std_includes = "`include \"disciplines.vams\"\n`include \"constants.vams\"\n";

/// Whether a `.lint` of `src` fails with a `code` diagnostic.
fn lintReports(src: []const u8, opts: vera.Settings, code: diag.Code) !bool {
    var bag: diag.Bag = .init(testing.allocator);
    defer bag.deinit(testing.allocator);
    try testing.expectError(error.CompileFailed, vera.analyze(testing.allocator, src, opts, &bag));
    for (0..bag.count()) |i| if (bag.at(i).code == code) return true;
    return false;
}

test "require_std_includes: annex D reaches a source that includes it, under --sim=verilogA too" {
    const gpa = testing.allocator;
    // Annex C.17: disciplines.vams's discrete `logic` and `ddiscrete` are
    // ignored, with the prelude (the include is then guarded empty) or
    // without it (the include splices the header itself).
    for ([_]vera.Sim{ .verilog_ams, .verilog_a }) |sim| for ([_]bool{ true, false }) |std_defs| {
        var res = try vera.analyze(gpa, std_includes ++ std_model, .{ .require_std_includes = true, .sim = sim, .std_defs = std_defs }, null);
        res.deinit(gpa);
    };
    var pi = try vera.analyze(gpa, std_includes ++ pi_model, .{ .require_std_includes = true }, null);
    pi.deinit(gpa);
}

test "require_std_includes: annex D without its include is E0371 or E0115, and is not without the option" {
    // A D.1 discipline without disciplines.vams.
    try testing.expect(try lintReports(std_model, .{ .require_std_includes = true }, .E0371));
    var res = try vera.analyze(testing.allocator, std_model, .{}, null);
    res.deinit(testing.allocator);
    // A D.2 macro without constants.vams.
    const pi = "`include \"disciplines.vams\"\n" ++ pi_model;
    try testing.expect(try lintReports(pi, .{ .require_std_includes = true }, .E0115));
    var res2 = try vera.analyze(testing.allocator, pi, .{}, null);
    res2.deinit(testing.allocator);
}

test "require_std_includes: annex D's own guards read as undefined until the file is included" {
    // A header that includes D.1 only when nothing has yet (the suite's
    // check.vh): the prelude's `DISCIPLINES_VAMS` must not hide the include.
    const guarded = "`ifndef DISCIPLINES_VAMS\n`include \"disciplines.vams\"\n`endif\n" ++
        "`ifndef CONSTANTS_VAMS\n`include \"constants.vams\"\n`endif\n";
    var res = try vera.analyze(testing.allocator, guarded ++ pi_model, .{ .require_std_includes = true }, null);
    res.deinit(testing.allocator);
    // A source that declares its own base natures defines the guard first,
    // and the header then leaves annex D's out (no E0335 on access `V`).
    const own = "`define DISCIPLINES_VAMS 1\n" ++ guarded ++
        \\nature own_v; units = "V"; access = V; abstol = 1m; endnature
        \\nature own_i; units = "A"; access = I; abstol = 1n; endnature
        \\discipline own_e; domain continuous; potential own_v; flow own_i; enddiscipline
        \\module m(p); inout p; own_e p; analog I(p) <+ V(p); endmodule
        \\
    ;
    var res2 = try vera.analyze(testing.allocator, own, .{ .require_std_includes = true }, null);
    res2.deinit(testing.allocator);
    // Without the option the guards are the prelude's, as before.
    var res3 = try vera.analyze(testing.allocator, guarded ++ std_model, .{}, null);
    res3.deinit(testing.allocator);
}

test "--sim=verilogA: a user's discrete discipline is E0250 where a net uses it (annex C.4)" {
    // C.17 ignores the definition itself; C.4's error is the domain
    // binding a net or port takes from it.
    const src = std_includes ++
        \\discipline d; domain discrete; enddiscipline
        \\module m(a); inout a; d a; endmodule
        \\
    ;
    try testing.expect(try lintReports(src, .{ .require_std_includes = true, .sim = .verilog_a }, .E0250));
}

/// Preprocesses `src` with every allocation on `gpa`, for
/// `checkAllAllocationFailures`.
fn preprocessAll(gpa: Allocator, src: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    _ = try process(arena, src, .{ .std_defs = false, .bag = &bag });
}

test "process reports every allocation failure as OutOfMemory and leaks nothing" {
    // One source through every allocating path: a function-like macro with a
    // pre-expanded actual, a built-in `include, a conditional, two event
    // lists, a comment's strip mark, `__LINE__ and `__FILE__.
    try testing.checkAllAllocationFailures(testing.allocator, preprocessAll, .{
        "`define F(x) [x]\n`include \"constants.vams\"\n`ifdef M_PI\n`F(`M_PI)\n`endif\n" ++
            "`timescale 1ns/1ps\n`default_discipline electrical\n/* c */ `__LINE__ `__FILE__\n",
    });
}

test "isIdentStart admits exactly §2.8's letters, `_`, and `$`" {
    for (0..256) |c| {
        const b: u8 = @intCast(c);
        const want = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or b == '_' or b == '$';
        try testing.expectEqual(want, frontend.pp_scan.isIdentStart(b));
    }
}

test "stringStop ends at the closing quote, an unescaped newline, or the end" {
    const cases = [_]struct { text: []const u8, want: usize }{
        .{ .text = "\"ab\"x", .want = 3 },
        .{ .text = "\"a\\\"b\"", .want = 5 },
        .{ .text = "\"ab\ncd\"", .want = 3 },
        .{ .text = "\"ab", .want = 3 },
        .{ .text = "\"a\\", .want = 3 },
        .{ .text = "\"a\\\nb\"", .want = 5 },
    };
    for (cases) |c| try testing.expectEqual(c.want, frontend.pp_scan.stringStop(c.text, 0));

    // Oracle: the per-byte loop `stringStop` replaced, on random text dense in
    // the three bytes it branches on, from the empty body past three vectors.
    const scalar = struct {
        fn stop(text: []const u8, start: usize) usize {
            var i = start + 1;
            while (i < text.len and text[i] != '"' and text[i] != '\n') {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
                i += 1;
            }
            return i;
        }
    }.stop;
    var prng: std.Random.DefaultPrng = .init(0x57a1);
    const rand = prng.random();
    var buf: [200]u8 = undefined;
    for (1..buf.len + 1) |len| {
        for (0..32) |_| {
            for (buf[0..len]) |*b| b.* = switch (rand.uintLessThan(u8, 40)) {
                0 => '"',
                1, 2 => '\\',
                3 => '\n',
                else => 'a',
            };
            for (0..@min(len, 4)) |start| {
                buf[start] = '"';
                try testing.expectEqual(scalar(buf[0..len], start), frontend.pp_scan.stringStop(buf[0..len], start));
            }
        }
    }
}

test "Rest reads identifiers and escaped identifiers where the lexer splits them" {
    var r: frontend.pp_scan.Rest = .{ .s = "  a$1_ \\b-c d" };
    try testing.expectEqualStrings("a$1_", r.ident().?);
    // A backslash starts no simple identifier, and a letter no escaped one.
    try testing.expect(r.ident() == null);
    try testing.expectEqualStrings("b-c", r.escapedIdent().?);
    try testing.expect(r.escapedIdent() == null);
    try testing.expectEqualStrings("d", r.ident().?);
    try testing.expect(r.peek() == null);
}

test "joinChain spells an include or expansion chain" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    var pp: Pp = .{ .arena = arena, .scratch = arena, .opts = .{ .bag = &bag } };
    try testing.expectEqualStrings("A -> B -> C", try pp.joinChain(&.{ "A", "B" }, "C"));
    try testing.expectEqualStrings("C", try pp.joinChain(&.{}, "C"));
}
