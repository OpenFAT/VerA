//! Tests for the diagnostic system: hand-derived cases and seeded properties
//! (`Levels`, `Bag`/`Builder`, `LineIndex`, `SourceMap`, `didYouMean`, the
//! text and JSON renderers) -> pass or fail, on std.testing.allocator.

const std = @import("std");
const diag = @import("diag");
const Severity = diag.Severity;
const Level = diag.Level;
const Levels = diag.Levels;

test "edit distance and suggestion" {
    try std.testing.expectEqual(@as(usize, 0), diag.editDistance("abc", "abc", 4));
    try std.testing.expectEqual(@as(usize, 1), diag.editDistance("abc", "abd", 4));
    // Transposition is one edit, not two.
    try std.testing.expectEqual(@as(usize, 1), diag.editDistance("abc", "acb", 4));
    try std.testing.expect(diag.editDistance("abc", "zzzzzz", 2) > 2);

    // The `u8` rows, at the widest input `cap` admits: 64 characters against 64
    // different ones is distance 64, the saturating case, and the whole proof a
    // byte holds every cell. One character more and the guard fires first.
    const wide_a = &@as([64]u8, @splat('a'));
    const wide_b = &@as([64]u8, @splat('b'));
    try std.testing.expectEqual(@as(usize, 64), diag.editDistance(wide_a, wide_b, 64));
    try std.testing.expectEqual(@as(usize, 0), diag.editDistance(wide_a, wide_a, 64));
    try std.testing.expect(diag.editDistance(&@as([65]u8, @splat('a')), wide_b, 64) > 64);

    const cands = [_][]const u8{ "vds", "vgs", "temp" };
    try std.testing.expectEqualStrings("vds", diag.didYouMean("vdss", &cands).?);
    try std.testing.expect(diag.didYouMean("completely_different", &cands) == null);
}

test "suggestion ties break lexicographically, not by input order" {
    // "vas" is one edit from both. Whichever order the candidates arrive in,
    // the answer must be the same.
    const a = [_][]const u8{ "vbs", "vas_" };
    const b = [_][]const u8{ "vas_", "vbs" };
    try std.testing.expectEqualStrings(diag.didYouMean("vas", &a).?, diag.didYouMean("vas", &b).?);
}

test "lint levels" {
    var levels: Levels = .empty;

    try std.testing.expectEqual(Level.warn, levels.get(.W0650));
    try std.testing.expectEqual(Level.deny, levels.get(.E0601));

    try levels.set(.W0650, .allow);
    try std.testing.expectEqual(Level.allow, levels.get(.W0650));

    // An error cannot be allowed away.
    try std.testing.expectError(error.CannotAllowError, levels.set(.E0601, .allow));

    // forbid is a one-way door.
    try levels.set(.W0651, .forbid);
    try std.testing.expectError(error.Forbidden, levels.set(.W0651, .allow));

    try std.testing.expect(try levels.parseFlag("deny=W0650"));
    try std.testing.expectEqual(Level.deny, levels.get(.W0650));
    try std.testing.expect(!try levels.parseFlag("not-a-flag"));
}

test "bag: dedupe keys on the file of a preprocessor span" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());

    // Offset 0 in two different headers is two places.
    for ([_]u16{ 1, 2, 2 }) |f| {
        var b = bag.build(.preprocess, .E0101, .at(0));
        b.inFile(@fromBackingInt(@intCast(f)));
        try b.emit();
    }
    try std.testing.expectEqual(@as(usize, 2), bag.count());
    try std.testing.expectEqual(@as(u32, 1), bag.deduped);
}

test "bag: dedupe, cap, level promotion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());

    try bag.add(.lower, .E0313, .{ .start = 10, .end = 13 }, "unknown variable {s}", .{"vd"});
    // Same code, same start ⇒ deduped.
    try bag.add(.lower, .E0313, .{ .start = 10, .end = 13 }, "unknown variable {s}", .{"vd"});
    try std.testing.expectEqual(@as(usize, 1), bag.count());
    try std.testing.expectEqual(@as(u32, 1), bag.deduped);
    try std.testing.expectEqual(@as(u32, 1), bag.err_count);
    try std.testing.expect(bag.failed());

    // A warning does not fail the compilation.
    try bag.add(.proof, .W0650, .{ .start = 20, .end = 24 }, "", .{});
    try std.testing.expectEqual(@as(u32, 1), bag.warn_count);
    try std.testing.expectEqual(@as(u32, 1), bag.err_count);

    // ...until it is denied.
    try bag.levels.set(.W0650, .deny);
    try bag.add(.proof, .W0650, .{ .start = 30, .end = 34 }, "", .{});
    try std.testing.expectEqual(@as(u32, 2), bag.err_count);

    // ...or allowed, in which case it is not collected at all.
    try bag.levels.set(.W0650, .allow);
    const before = bag.count();
    try bag.add(.proof, .W0650, .{ .start = 40, .end = 44 }, "", .{});
    try std.testing.expectEqual(before, bag.count());
}

test "bag: cap counts what it drops" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());

    for (0..diag.max_entries + 10) |i| {
        try bag.add(.lower, .E0313, .{ .start = @intCast(i * 4), .end = @intCast(i * 4 + 2) }, "x", .{});
    }
    try std.testing.expectEqual(@as(usize, diag.max_entries), bag.count());
    try std.testing.expectEqual(@as(u32, 10), bag.suppressed);
}

test "bag: the flat records survive a round trip, in order, through a sort" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());

    // Emitted out of source order, so `sort` has something to do and the
    // labels and notes have to move with their row.
    var b = bag.build(.lower, .E0313, .{ .start = 50, .end = 52 });
    b.msg("second", .{});
    b.label(.{ .start = 51, .end = 53 }, "one", .{});
    b.label(.{ .start = 54, .end = 55 }, "two", .{});
    // An EMPTY replacement is a deletion, not "no fix": the two must not
    // collapse, which is the whole reason `String` 0 is reserved.
    b.suggest(.{ .span = .{ .start = 50, .end = 52 }, .replacement = "" }, "drop it", .{});
    b.note("plain", .{});
    try b.emit();

    try bag.add(.parse, .E0207, .{ .start = 10, .end = 12 }, "first", .{});
    bag.sort();

    try std.testing.expectEqualStrings("first", bag.at(0).message);

    const e = bag.at(1);
    try std.testing.expectEqualStrings("second", e.message);
    // No `point` was set: `String` 0 decodes to the empty string.
    try std.testing.expectEqualStrings("", e.point);
    try std.testing.expectEqual(diag.Stage.lower, e.stage);
    try std.testing.expectEqual(Severity.err, e.severity);
    try std.testing.expectEqual(@as(u32, 50), e.span.start);
    try std.testing.expectEqual(diag.FileId.none, e.file);

    var lbuf: [diag.max_children]diag.Label = undefined;
    const ls = bag.labels(e, &lbuf);
    try std.testing.expectEqual(@as(usize, 2), ls.len);
    try std.testing.expectEqualStrings("one", ls[0].text);
    try std.testing.expectEqualStrings("two", ls[1].text);
    try std.testing.expectEqual(@as(u32, 55), ls[1].span.end);

    var nbuf: [diag.max_children]diag.Note = undefined;
    const ns = bag.notes(e, &nbuf);
    try std.testing.expectEqual(@as(usize, 2), ns.len);
    try std.testing.expectEqual(diag.Note.Kind.help, ns[0].kind);
    try std.testing.expectEqualStrings("", ns[0].fix.?.replacement);
    try std.testing.expectEqual(@as(u32, 52), ns[0].fix.?.span.end);
    try std.testing.expectEqual(diag.Note.Kind.note, ns[1].kind);
    try std.testing.expect(ns[1].fix == null);
}

test "line index" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = "aaa\nbbbb\n\nccc";
    const idx = try diag.LineIndex.build(arena_state.allocator(), text);

    try std.testing.expectEqual(diag.Loc{ .line = 1, .col = 1 }, idx.loc(0));
    try std.testing.expectEqual(diag.Loc{ .line = 1, .col = 3 }, idx.loc(2));
    try std.testing.expectEqual(diag.Loc{ .line = 2, .col = 1 }, idx.loc(4));
    try std.testing.expectEqual(diag.Loc{ .line = 4, .col = 2 }, idx.loc(11));
    try std.testing.expectEqualStrings("bbbb", idx.lineText(text, 2));
    try std.testing.expectEqualStrings("", idx.lineText(text, 3));
    try std.testing.expectEqualStrings("ccc", idx.lineText(text, 4));
}

/// Renders a bag to an arena-owned string. Test helper, and the shape a host
/// that wants the text rather than a writer would use.
fn renderToString(bag: *diag.Bag, opts: diag.RenderOptions) ![]const u8 {
    // ponytail: the arena owns the result; transfer ownership only if it must outlive it.
    var aw: std.Io.Writer.Allocating = .init(bag.arena);
    try diag.render(bag, &aw.writer, opts);
    return aw.writer.buffered();
}

test "render: full diagnostic with label, note, suggestion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module r(a, b);
        \\  parameter real k = 1.0;
        \\  analog I(a, b) <+ V(a, b) / k;
        \\endmodule
        \\
    ;
    var bag = diag.Bag.init(arena);
    try bag.setSingleFile("res.va", src);

    const k_decl = @as(u32, @intCast(std.mem.find(u8, src, "k = 1.0").?));
    const divisor = @as(u32, @intCast(std.mem.findScalarLast(u8, src, 'k').?));

    var b = bag.build(.proof, .E0601, .{ .start = divisor, .end = divisor + 1 });
    b.msg("divisor is parameter `k`", .{});
    b.point("divisor", .{});
    b.label(.{ .start = k_decl, .end = k_decl + 1 }, "`k` is unconstrained: (-inf, inf)", .{});
    b.suggest(
        .{ .span = diag.Span.at(k_decl + 7), .replacement = " from (0:inf)" },
        "constrain the parameter so zero is excluded",
        .{},
    );
    try b.emit();

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });

    // Headline carries severity, code and the catalogue title.
    try std.testing.expect(std.mem.startsWith(u8, out, "error[E0601]: zero divisor: divisor is parameter `k`\n"));
    // Location resolves to the right line and column.
    try std.testing.expect(std.mem.find(u8, out, "--> res.va:3:31\n") != null);
    // Both the primary caret and the secondary label are drawn.
    try std.testing.expect(std.mem.find(u8, out, "^ divisor") != null);
    try std.testing.expect(std.mem.find(u8, out, "- `k` is unconstrained") != null);
    // The LRM citation comes from the code table, not from the message.
    try std.testing.expect(std.mem.find(u8, out, "= note: LRM 4.2.4") != null);
    // The suggestion renders as a patched line plus an insertion ruler.
    try std.testing.expect(std.mem.find(u8, out, "= help: constrain the parameter") != null);
    try std.testing.expect(std.mem.find(u8, out, "parameter real k = 1.0 from (0:inf);") != null);
    try std.testing.expect(std.mem.find(u8, out, "+++++++++++++") != null);
    // Lines 2 and 3 are adjacent, so nothing is elided.
    try std.testing.expect(std.mem.find(u8, out, "...") == null);
}

test "render: a gap between labelled lines is elided" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\parameter real k = 1.0;
        \\real filler_a;
        \\real filler_b;
        \\analog I(a, b) <+ V(a, b) / k;
        \\
    ;
    var bag = diag.Bag.init(arena);
    try bag.setSingleFile("gap.va", src);
    const k_decl = @as(u32, @intCast(std.mem.find(u8, src, "k = 1.0").?));
    const divisor = @as(u32, @intCast(std.mem.findScalarLast(u8, src, 'k').?));

    var b = bag.build(.proof, .E0601, .{ .start = divisor, .end = divisor + 1 });
    b.label(.{ .start = k_decl, .end = k_decl + 1 }, "declared here", .{});
    try b.emit();

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    // Lines 1 and 4 are shown; 2 and 3 collapse to `...`.
    try std.testing.expect(std.mem.find(u8, out, "...") != null);
    try std.testing.expect(std.mem.find(u8, out, "filler_a") == null);
}

test "render: colour is opt-in and structural" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag = diag.Bag.init(arena);
    try bag.setSingleFile("x.va", "analog begin\n  x = 1;\nend\n");
    try bag.add(.lower, .E0313, .{ .start = 15, .end = 16 }, "no variable `x`", .{});
    try bag.add(.proof, .W0650, .{ .start = 15, .end = 16 }, "", .{});

    const plain = try renderToString(&bag, .{});
    try std.testing.expect(std.mem.findScalar(u8, plain, 0x1b) == null);

    var bag2 = diag.Bag.init(arena);
    try bag2.setSingleFile("x.va", "analog begin\n  x = 1;\nend\n");
    try bag2.add(.lower, .E0313, .{ .start = 15, .end = 16 }, "no variable `x`", .{});
    try bag2.add(.proof, .W0650, .{ .start = 15, .end = 16 }, "", .{});
    const coloured = try renderToString(&bag2, .{ .palette = .on });

    // Error red and warning yellow are distinct, and both appear.
    try std.testing.expect(std.mem.find(u8, coloured, "\x1b[1;31merror[E0601") == null);
    try std.testing.expect(std.mem.find(u8, coloured, "\x1b[1;31merror[E0313]") != null);
    try std.testing.expect(std.mem.find(u8, coloured, "\x1b[1;33mwarning[W0650]") != null);
    // A warning alone does not fail the compilation.
    try std.testing.expectEqual(@as(u32, 1), bag2.err_count);
    try std.testing.expectEqual(@as(u32, 1), bag2.warn_count);
}

test "render: tabs expand so carets line up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "module m;\n\t\tbadtok\nendmodule\n";
    var bag = diag.Bag.init(arena);
    try bag.setSingleFile("t.va", src);
    const at = @as(u32, @intCast(std.mem.find(u8, src, "badtok").?));
    try bag.add(.parse, .E0207, .{ .start = at, .end = at + 6 }, "", .{});

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    // Two tabs become eight spaces in the source line AND in the caret row, so
    // the six carets sit under the six characters of `badtok`.
    try std.testing.expect(std.mem.find(u8, out, "|         badtok") != null);
    try std.testing.expect(std.mem.find(u8, out, "|         ^^^^^^") != null);
    // The reported column is the display column, not the byte column.
    try std.testing.expect(std.mem.find(u8, out, "t.va:2:9") != null);
}

test "render: multi-byte UTF-8 counts codepoints, not bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Eight two-byte µ before the token: sixteen bytes, eight columns.
    const src = "µµµµµµµµbadtok\n";
    var bag = diag.Bag.init(arena);
    try bag.setSingleFile("u.va", src);
    const at = @as(u32, @intCast(std.mem.find(u8, src, "badtok").?));
    try bag.add(.parse, .E0207, .{ .start = at, .end = at + 6 }, "", .{});

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    try std.testing.expect(std.mem.find(u8, out, "| µµµµµµµµbadtok") != null);
    // Eight spaces of caret indent — one per µ — exactly as the tab test's
    // eight-space indent above, and the reported column is 9, not 17.
    try std.testing.expect(std.mem.find(u8, out, "|         ^^^^^^") != null);
    try std.testing.expect(std.mem.find(u8, out, "u.va:1:9") != null);
}

test "strip marks map span offsets back into the original text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag = diag.Bag.init(arena);
    // Original: `abc /* c */ def` — the preprocessor strips to `abc   def`
    // (block comment → one space, `stripComments`) and leaves one mark: from
    // stripped offset 5 on, original = 11 + (stripped − 5). Before the first
    // mark: identity.
    _ = try bag.addFile("m.va", "abc /* c */ def\n");
    bag.setStrippedText(.root, "abc   def\n", &.{.{ .out = 5, .src = 11 }});

    try std.testing.expectEqualStrings("abc   def\n", bag.fileText(.root));
    try std.testing.expectEqualStrings("abc /* c */ def\n", bag.sourceText(.root));
    try std.testing.expectEqual(@as(u32, 0), bag.toSourceOffset(.root, 0)); // 'a'
    try std.testing.expectEqual(@as(u32, 3), bag.toSourceOffset(.root, 3)); // pre-mark space
    try std.testing.expectEqual(@as(u32, 12), bag.toSourceOffset(.root, 6)); // 'd'
    try std.testing.expectEqual(@as(u32, 15), bag.toSourceOffset(.root, 9)); // '\n'
    // A file registered without stripping maps as identity.
    const other = try bag.addFile("p.va", "xyz\n");
    try std.testing.expectEqual(@as(u32, 2), bag.toSourceOffset(other, 2));
    try std.testing.expectEqualStrings("xyz\n", bag.sourceText(other));
}

test "render: json is one object per line and escapes properly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag = diag.Bag.init(arena);
    try bag.setSingleFile("j.va", "analog x;\n");
    var b = bag.build(.lower, .E0313, .{ .start = 7, .end = 8 });
    b.msg("quote \" and \\ and newline", .{});
    b.help("try `y`", .{});
    try b.emit();

    var buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
    try diag.renderJson(&bag, &aw.writer);
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.find(u8, out, "\"code\":\"E0313\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"level\":\"error\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "\\\" and \\\\ and") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"line\":1,\"col\":8") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"kind\":\"help\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
}

test "explain prints the catalogue entry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena_state.allocator(), &buf);
    try diag.explain(.W0650, &aw.writer, .off);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "W0650: unit is not provably finite"));
    try std.testing.expect(std.mem.find(u8, out, "@setFloatMode(.optimized)") != null);
    try std.testing.expect(std.mem.find(u8, out, "--allow=W0650") != null);
}

test "detach survives the compilation arena, and deinit is leak-free" {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = undefined;

    // Everything below is allocated from an arena that dies before we render,
    // which is exactly the failed-compilation shape.
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        bag = diag.Bag.init(arena);
        const src = "module m;\n  analog x = 1;\nendmodule\n";
        try bag.setSingleFile("owned.va", src);

        // Offset 19 is the `x` in `analog x = 1;`.
        var b = bag.build(.lower, .E0313, .{ .start = 19, .end = 20 });
        b.msg("`{s}`", .{"x"});
        b.point("not declared", .{});
        b.label(.{ .start = 12, .end = 18 }, "in this block", .{});
        b.suggest(.{ .span = diag.Span.at(12), .replacement = "real x; " }, "declare it", .{});
        try b.emit();

        try bag.detach(gpa);
    }
    defer bag.deinit(gpa);

    // The arena is gone. Rendering must still work off gpa-owned bytes.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = aw.toArrayList();
    try diag.render(&bag, &aw.writer, .{ .explain_hint = false, .summary = false });
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.find(u8, out, "error[E0313]") != null);
    try std.testing.expect(std.mem.find(u8, out, "owned.va:2:10") != null);
    try std.testing.expect(std.mem.find(u8, out, "^ not declared") != null);
    try std.testing.expect(std.mem.find(u8, out, "- in this block") != null);
    try std.testing.expect(std.mem.find(u8, out, "real x; analog x = 1;") != null);
}

test "detach on a clean bag allocates nothing" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    var bag = diag.Bag.init(arena_state.allocator());
    try bag.setSingleFile("clean.va", "module m; endmodule\n");
    try bag.detach(gpa);
    arena_state.deinit();
    defer bag.deinit(gpa);
    try std.testing.expect(bag.isEmpty());
    try std.testing.expect(!bag.failed());
}

test "source map resolves includes and macro expansions" {
    const segs = [_]diag.Segment{
        .{ .out_start = 0, .in_start = 0, .file = .root, .kind = .verbatim },
        .{ .out_start = 5, .in_start = 0, .file = @fromBackingInt(@intCast(1)), .kind = .verbatim },
        .{ .out_start = 10, .in_start = 5, .file = .root, .kind = .verbatim },
        .{ .out_start = 14, .in_start = 0, .file = .root, .kind = .macro, .parent = 2, .macro = "FOO" },
    };
    const map: diag.SourceMap = .{ .segs = &segs };

    const a = map.resolve(2);
    try std.testing.expectEqual(diag.FileId.root, a.file);
    try std.testing.expectEqual(@as(u32, 2), a.offset);

    const b = map.resolve(6);
    try std.testing.expectEqual(@as(diag.FileId, @fromBackingInt(@intCast(1))), b.file);
    try std.testing.expectEqual(@as(u32, 1), b.offset);

    // Inside an expansion: report the invocation site, not a phantom offset.
    const c = map.resolve(16);
    try std.testing.expectEqual(diag.FileId.root, c.file);
    try std.testing.expectEqual(@as(u32, 5), c.offset);
    try std.testing.expectEqualStrings("FOO", segs[c.seg].macro);

    // An empty map is the identity.
    const none: diag.SourceMap = .empty;
    try std.testing.expectEqual(@as(u32, 99), none.resolve(99).offset);
}

// ---------------------------------------------------------------------------
// Levels
// ---------------------------------------------------------------------------

test "severity comes from the code's first letter" {
    try std.testing.expectEqual(Severity.err, diag.severityOf(.E0313));
    try std.testing.expectEqual(Severity.warning, diag.severityOf(.W0650));
    try std.testing.expectEqualStrings("error", Severity.err.word());
    try std.testing.expectEqualStrings("warning", Severity.warning.word());
}

test "levels: refusals leave the levels unchanged, overrides replace" {
    var levels: Levels = .empty;

    // An error may be denied or forbidden, never warned or allowed.
    try std.testing.expectError(error.CannotAllowError, levels.set(.E0601, .warn));
    try std.testing.expectEqual(Level.deny, levels.get(.E0601));
    try levels.set(.E0601, .forbid);
    try std.testing.expectEqual(Level.forbid, levels.get(.E0601));

    // A warning's level is whatever was set last, in one row per code.
    try levels.set(.W0650, .deny);
    try levels.set(.W0650, .warn);
    try std.testing.expectEqual(Level.warn, levels.get(.W0650));
    // One slot per code: the two set, every other code untouched.
    var want: Levels = .empty;
    try want.set(.E0601, .forbid);
    try want.set(.W0650, .warn);
    try std.testing.expectEqual(want, levels);

    // `forbid` refuses every later level but itself, `deny` included.
    try levels.set(.W0651, .forbid);
    try std.testing.expectError(error.Forbidden, levels.set(.W0651, .deny));
    try std.testing.expectError(error.Forbidden, levels.set(.W0651, .warn));
    try levels.set(.W0651, .forbid);
    try std.testing.expectEqual(Level.forbid, levels.get(.W0651));
}

test "levels: parseFlag reads only exact level=code directives" {
    var levels: Levels = .empty;

    const not_directives = [_][]const u8{
        "allow",       "=W0650",        "allow=",       "Allow=W0650",
        "allow=w0650", "allow=W0650=x", "allow= W0650", "allow=W9999",
    };
    for (not_directives) |t| try std.testing.expect(!try levels.parseFlag(t));
    try std.testing.expectEqual(Levels.empty, levels);

    try std.testing.expect(try levels.parseFlag("forbid=E0101"));
    try std.testing.expectEqual(Level.forbid, levels.get(.E0101));
    try std.testing.expectError(error.CannotAllowError, levels.parseFlag("warn=E0313"));
}

/// How many codes `levels` holds at other than their default level.
fn overridden(levels: Levels) usize {
    var n: usize = 0;
    for (0..@typeInfo(diag.Code).@"enum".field_names.len) |i| {
        const c: diag.Code = @fromBackingInt(@intCast(i));
        n += @intFromBool(levels.get(c) != Levels.empty.get(c));
    }
    return n;
}

test "levels: setting and parsing levels takes no allocator, and a copy is a snapshot" {
    // `Levels` is one byte a code: no allocator to fail, nothing to free,
    // and `bag.levels = lint` copies rather than shares.
    try std.testing.expectEqual(@typeInfo(diag.Code).@"enum".field_names.len, @sizeOf(Levels));
    var levels: Levels = .empty;
    try levels.set(.W0650, .allow);
    try std.testing.expect(try levels.parseFlag("deny=W0651"));
    const snapshot = levels;
    try levels.set(.W0650, .deny);
    try std.testing.expectEqual(Level.deny, levels.get(.W0650));
    try std.testing.expectEqual(Level.allow, snapshot.get(.W0650));
    try std.testing.expectEqual(Level.deny, snapshot.get(.W0651));
    try std.testing.expectEqual(@as(usize, 2), overridden(snapshot));
}

// ---------------------------------------------------------------------------
// Locations
// ---------------------------------------------------------------------------

test "span: zero width, inverted, and none" {
    const S = diag.Span;
    try std.testing.expectEqual(@as(u32, 0), S.at(7).len());
    try std.testing.expectEqual(@as(u32, 3), (S{ .start = 4, .end = 7 }).len());
    // Inverted saturates rather than wrapping.
    try std.testing.expectEqual(@as(u32, 0), (S{ .start = 7, .end = 4 }).len());
    try std.testing.expect(S.none.isNone());
    // The documented collision: a caret at byte 0 is "no location".
    try std.testing.expect(S.at(0).isNone());
    try std.testing.expect(!S.at(1).isNone());
    try std.testing.expect(!(S{ .start = 0, .end = 1 }).isNone());
}

test "line index: empty text, CRLF, and offsets past the end" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Loc = diag.Loc;

    const empty = try diag.LineIndex.build(arena, "");
    try std.testing.expectEqual(@as(usize, 1), empty.starts.len);
    try std.testing.expectEqual(Loc{ .line = 1, .col = 1 }, empty.loc(0));
    try std.testing.expectEqualStrings("", empty.lineText("", 0));
    try std.testing.expectEqualStrings("", empty.lineText("", 1));
    try std.testing.expectEqualStrings("", empty.lineText("", 2));

    // Line starts 0, 4, 8: two lines and the empty one after the last '\n'.
    const crlf = "ab\r\ncd\r\n";
    const idx = try diag.LineIndex.build(arena, crlf);
    try std.testing.expectEqual(@as(usize, 3), idx.starts.len);
    try std.testing.expectEqualStrings("ab", idx.lineText(crlf, 1));
    try std.testing.expectEqualStrings("cd", idx.lineText(crlf, 2));
    try std.testing.expectEqualStrings("", idx.lineText(crlf, 3));
    // The '\n' of line 1 is its byte column 4, though the line text is "ab".
    try std.testing.expectEqual(Loc{ .line = 1, .col = 4 }, idx.loc(3));
    // Past the end: the last line (start 8), column 10 - 8 + 1.
    try std.testing.expectEqual(Loc{ .line = 3, .col = 3 }, idx.loc(10));
}

/// `LineIndex` against a byte-at-a-time walk: every offset up to three past
/// the end, and every line's text against `splitScalar` with one '\r' cut.
fn lineIndexOne(_: void, s: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [256]u8 = undefined;
    const text = buf[0..s.slice(&buf)];
    const idx = try diag.LineIndex.build(arena_state.allocator(), text);

    var line: u32 = 1;
    var line_start: u32 = 0;
    for (0..text.len + 3) |o| {
        const off: u32 = @intCast(o);
        try std.testing.expectEqual(diag.Loc{ .line = line, .col = off - line_start + 1 }, idx.loc(off));
        if (o < text.len and text[o] == '\n') {
            line += 1;
            line_start = off + 1;
        }
    }
    try std.testing.expectEqual(@as(usize, line), idx.starts.len);

    var it = std.mem.splitScalar(u8, text, '\n');
    var k: u32 = 1;
    while (it.next()) |raw| : (k += 1) {
        const want = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        try std.testing.expectEqualStrings(want, idx.lineText(text, k));
    }
    try std.testing.expectEqualStrings("", idx.lineText(text, k));
}

test "line index agrees with a byte-at-a-time count" {
    try std.testing.fuzz({}, lineIndexOne, .{ .corpus = &.{ "", "\n", "a\r\nb", "\r\r\n\n", "x\ty\nµ\n" } });
}

test "source map: boundaries, nested expansions, and an offset before the first segment" {
    const f1: diag.FileId = @fromBackingInt(@intCast(1));
    const segs = [_]diag.Segment{
        .{ .out_start = 4, .in_start = 2, .file = .root, .kind = .verbatim },
        // The preprocessor's pair at an outermost expansion: a zero-width
        // verbatim pin at the invocation (root offset 30), then the macro.
        .{ .out_start = 10, .in_start = 30, .file = .root, .kind = .verbatim },
        .{ .out_start = 10, .in_start = 30, .file = .root, .kind = .macro, .parent = 1, .macro = "OUTER" },
        // A macro whose parent is a macro: the walk continues to the pin.
        .{ .out_start = 15, .in_start = 0, .file = f1, .kind = .macro, .parent = 2, .macro = "INNER" },
        // A macro with no verbatim ancestor reports its own start.
        .{ .out_start = 20, .in_start = 7, .file = f1, .kind = .macro, .macro = "ORPHAN" },
        .{ .out_start = 25, .in_start = 40, .file = .root, .kind = .verbatim },
    };
    const map: diag.SourceMap = .{ .segs = &segs };
    const R = diag.SourceMap.Resolved;

    // Before the first segment: that segment's start, not an underflow.
    try std.testing.expectEqual(R{ .file = .root, .offset = 2, .seg = 0 }, map.resolve(1));
    try std.testing.expectEqual(R{ .file = .root, .offset = 2, .seg = 0 }, map.resolve(4));
    try std.testing.expectEqual(R{ .file = .root, .offset = 7, .seg = 0 }, map.resolve(9));
    // Two segments start at 10; the later (the macro) wins and walks to the pin.
    try std.testing.expectEqual(R{ .file = .root, .offset = 30, .seg = 2 }, map.resolve(10));
    try std.testing.expectEqual(R{ .file = .root, .offset = 30, .seg = 3 }, map.resolve(17));
    try std.testing.expectEqual(R{ .file = f1, .offset = 7, .seg = 4 }, map.resolve(22));
    try std.testing.expectEqual(R{ .file = .root, .offset = 40, .seg = 5 }, map.resolve(25));
    try std.testing.expectEqual(R{ .file = .root, .offset = 114, .seg = 5 }, map.resolve(99));
}

// ---------------------------------------------------------------------------
// The bag and its builder
// ---------------------------------------------------------------------------

test "bag: a clean compilation allocates nothing" {
    var levels: Levels = .empty;
    try levels.set(.W0650, .allow);

    // Every allocation fails, so anything below that allocates is an error.
    var bag = diag.Bag.init(std.testing.failing_allocator);
    bag.levels = levels;
    try std.testing.expect(bag.isEmpty());
    try std.testing.expect(!bag.failed());
    try std.testing.expect(!bag.enabled(.W0650));
    try std.testing.expect(bag.enabled(.W0651));
    try std.testing.expectEqualStrings("", bag.str(.none));
    try std.testing.expectEqualStrings("<source>", bag.fileName(.root));
    try std.testing.expectEqualStrings("", bag.fileText(.root));
    try std.testing.expectEqualStrings("", bag.sourceText(.root));
    try std.testing.expectEqual(@as(usize, 0), bag.fileMarks(.root).len);
    try std.testing.expectEqual(@as(u32, 5), bag.toSourceOffset(.root, 5));
    // An allowed lint formats nothing, so it allocates nothing either.
    try bag.add(.proof, .W0650, .at(3), "{s}", .{"never formatted"});
    try std.testing.expect(bag.isEmpty());

    var out: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try diag.render(&bag, &w, .{});
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "bag: the pool's first string pays for the sentinel" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());

    var b = bag.build(.lower, .E0313, .at(5));
    b.msg("ab", .{});
    b.point("", .{});
    try b.emit();
    // Sentinel at 0, "ab" at 1 with its NUL at 3, the empty point at 4.
    try std.testing.expectEqualStrings("\x00ab\x00\x00", bag.strings.items);
    try std.testing.expectEqual(@as(u32, 1), @backingInt(bag.rows.items(.message)[0]));
    try std.testing.expectEqual(@as(u32, 4), @backingInt(bag.rows.items(.point)[0]));
    try std.testing.expectEqualStrings("ab", bag.at(0).message);
    try std.testing.expectEqualStrings("", bag.at(0).point);
}

test "bag: a diagnostic known to be dropped interns nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);

    try bag.levels.set(.W0650, .allow);
    var b = bag.build(.proof, .W0650, .at(3));
    b.msg("x", .{});
    b.point("p", .{});
    b.label(.at(4), "l", .{});
    b.help("h", .{});
    b.suggestHere("y");
    try b.emit();
    try std.testing.expectEqual(@as(usize, 0), bag.strings.items.len);
    try std.testing.expect(bag.isEmpty());
    // Allowed is not suppressed: the trailer counts only the cap.
    try std.testing.expectEqual(@as(u32, 0), bag.suppressed);

    for (0..diag.max_entries) |i| try bag.add(.lower, .E0313, .at(@intCast(i + 1)), "", .{});
    const pool = bag.strings.items.len;
    try bag.add(.lower, .E0313, .at(1000), "{s}", .{"never formatted"});
    try std.testing.expectEqual(pool, bag.strings.items.len);
    try std.testing.expectEqual(@as(u32, 1), bag.suppressed);
    // Counted, though dropped unformatted.
    try std.testing.expectEqual(@as(u32, diag.max_entries + 1), bag.err_count);
}

test "bag: dedupe keys on code and start only, and the first one stays" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());

    try bag.add(.lower, .E0313, .{ .start = 5, .end = 6 }, "a", .{});
    try bag.add(.lower, .E0313, .{ .start = 5, .end = 9 }, "b", .{}); // same code and start
    try bag.add(.lower, .E0207, .{ .start = 5, .end = 6 }, "c", .{}); // another code
    try bag.add(.lower, .E0313, .{ .start = 6, .end = 7 }, "d", .{}); // another start
    try std.testing.expectEqual(@as(usize, 3), bag.count());
    try std.testing.expectEqual(@as(u32, 1), bag.deduped);
    try std.testing.expectEqualStrings("a", bag.at(0).message);
    try std.testing.expectEqual(@as(u32, 6), bag.at(0).span.end);
}

test "bag: sort is by start, then end, then code" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());

    try bag.add(.lower, .E0313, .{ .start = 5, .end = 9 }, "d", .{});
    try bag.add(.lower, .E0101, .{ .start = 5, .end = 9 }, "c", .{});
    try bag.add(.lower, .E0601, .{ .start = 5, .end = 6 }, "b", .{});
    try bag.add(.lower, .E0207, .{ .start = 2, .end = 20 }, "a", .{});
    bag.sort();
    for ([_][]const u8{ "a", "b", "c", "d" }, 0..) |want, i| {
        try std.testing.expectEqualStrings(want, bag.at(i).message);
    }
}

test "builder: children past max_children are dropped, in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());

    var b = bag.build(.lower, .E0313, .at(5));
    for (0..diag.max_children + 2) |i| b.label(.at(@intCast(i + 1)), "l{d}", .{i});
    for (0..diag.max_children + 2) |i| b.note("n{d}", .{i});
    b.help("late", .{});
    try b.emit();

    const e = bag.at(0);
    try std.testing.expectEqual(diag.max_children, e.label_count);
    var lbuf: [diag.max_children]diag.Label = undefined;
    const ls = bag.labels(e, &lbuf);
    try std.testing.expectEqualStrings("l0", ls[0].text);
    try std.testing.expectEqualStrings("l3", ls[3].text);
    var nbuf: [diag.max_children]diag.Note = undefined;
    const ns = bag.notes(e, &nbuf);
    try std.testing.expectEqual(@as(usize, diag.max_children), ns.len);
    for (ns, 0..) |n, i| {
        try std.testing.expectEqual(diag.Note.Kind.note, n.kind);
        try std.testing.expectEqual(@as(u8, '0' + @as(u8, @intCast(i))), n.text[1]);
    }
}

test "builder: suggestHere rewrites the primary span" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());

    var b = bag.build(.lower, .E0313, .{ .start = 3, .end = 5 });
    b.suggestHere("vds");
    try b.emit();
    var nbuf: [diag.max_children]diag.Note = undefined;
    const ns = bag.notes(bag.at(0), &nbuf);
    try std.testing.expectEqual(@as(usize, 1), ns.len);
    try std.testing.expectEqual(diag.Note.Kind.help, ns[0].kind);
    try std.testing.expectEqualStrings("did you mean `vds`?", ns[0].text);
    try std.testing.expectEqual(diag.Span{ .start = 3, .end = 5 }, ns[0].fix.?.span);
    try std.testing.expectEqualStrings("vds", ns[0].fix.?.replacement);
}

test "builder: an allocation failure is latched and reported by emit" {
    var bag = diag.Bag.init(std.testing.failing_allocator);
    var b = bag.build(.lower, .E0313, .at(5));
    b.msg("x", .{});
    b.note("y", .{});
    try std.testing.expectError(error.OutOfMemory, b.emit());
    try std.testing.expect(bag.isEmpty());
    try std.testing.expect(!bag.failed());
}

/// Builds and renders one full diagnostic on `gpa`: the shape a failing
/// compilation takes, for the allocation-failure sweep below. The writer is
/// fixed, so every failure it can see is the bag's or the renderer's.
fn buildAndRender(gpa: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    try bag.setSingleFile("o.va", "module m;\n  x = 1;\nendmodule\n");
    var b = bag.build(.lower, .E0313, .{ .start = 12, .end = 13 });
    b.msg("`{s}`", .{"x"});
    b.label(.{ .start = 0, .end = 6 }, "here", .{});
    b.suggestHere("y");
    try b.emit();
    var out: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try diag.render(&bag, &w, .{});
    try diag.renderJson(&bag, &w);
}

test "every allocation failure while building and rendering propagates" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildAndRender, .{});
}

/// Detaches a bag holding a stripped file and a macro segment onto `gpa`.
fn detachOnce(gpa: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    _ = try bag.addFile("m.va", "abc /* c */ def\n");
    bag.setStrippedText(.root, "abc   def\n", &.{.{ .out = 5, .src = 11 }});
    bag.map = .{ .segs = &[_]diag.Segment{
        .{ .out_start = 0, .in_start = 0, .file = .root, .kind = .verbatim },
        .{ .out_start = 3, .in_start = 3, .file = .root, .kind = .macro, .parent = 0, .macro = "M" },
    } };
    try bag.add(.lower, .E0313, .at(6), "m", .{});

    bag.detach(gpa) catch |err| {
        // Unchanged, still on its arena.
        try std.testing.expectEqual(@as(usize, 1), bag.count());
        try std.testing.expectEqualStrings("m", bag.at(0).message);
        try std.testing.expectEqual(@as(usize, 0), bag.detached_bytes.len);
        return err;
    };
    defer bag.deinit(gpa);
    try std.testing.expectEqualStrings("abc /* c */ def\n", bag.sourceText(.root));
    try std.testing.expectEqualStrings("abc   def\n", bag.fileText(.root));
    try std.testing.expectEqualStrings("M", bag.map.segs[1].macro);
    try std.testing.expectEqual(@as(u32, 12), bag.toSourceOffset(.root, 6));
}

test "detach: every allocation failure leaves the bag on its arena and leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, detachOnce, .{});
}

test "detach: a detached bag keeps collecting on gpa, and deinit frees it all" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    var bag = diag.Bag.init(arena_state.allocator());
    try bag.setSingleFile("late.va", "module m;\nendmodule\n");
    try bag.detach(gpa);
    arena_state.deinit();
    defer bag.deinit(gpa);

    // Codegen reports after the detach (E0515's path): the first string pays
    // for the sentinel, and the rows regrow, on gpa.
    try bag.add(.codegen, .E0313, .{ .start = 10, .end = 19 }, "late {d}", .{1});
    try std.testing.expectEqualStrings("late 1", bag.at(0).message);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try diag.render(&bag, &aw.writer, .{ .explain_hint = false, .summary = false });
    // Offset 10 is the `e` that starts line 2.
    try std.testing.expect(std.mem.find(u8, aw.writer.buffered(), "late.va:2:1") != null);
}

test "strip marks: several marks, a span at a mark, and locate's file short-circuit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());

    // `a/*1*/b/*22*/c` strips to `a b c`: 'b' (stripped 2) is original 6 and
    // 'c' (stripped 4) is original 13, one mark each.
    _ = try bag.addFile("s.va", "a/*1*/b/*22*/c\n");
    bag.setStrippedText(.root, "a b c\n", &.{ .{ .out = 2, .src = 6 }, .{ .out = 4, .src = 13 } });
    try std.testing.expectEqual(@as(u32, 0), bag.toSourceOffset(.root, 0));
    try std.testing.expectEqual(@as(u32, 1), bag.toSourceOffset(.root, 1));
    try std.testing.expectEqual(@as(u32, 6), bag.toSourceOffset(.root, 2));
    try std.testing.expectEqual(@as(u32, 7), bag.toSourceOffset(.root, 3));
    try std.testing.expectEqual(@as(u32, 13), bag.toSourceOffset(.root, 4));
    try std.testing.expectEqual(@as(u32, 14), bag.toSourceOffset(.root, 5));

    const f1: diag.FileId = @fromBackingInt(@intCast(1));
    const r = bag.locate(.{ .start = 7, .end = 9 }, f1);
    try std.testing.expectEqual(f1, r.file);
    try std.testing.expectEqual(@as(u32, 7), r.offset);
    try std.testing.expectEqual(diag.Segment.no_parent, r.seg);
}

test "strip marks: the free function maps through any mark list, saturating" {
    // `a/*1*/b` strips to `a b`: 'b' (stripped 2) is original 6.
    const marks = [_]diag.StripMark{.{ .out = 2, .src = 6 }};
    try std.testing.expectEqual(@as(u32, 1), diag.toSourceOffset(&marks, 1));
    try std.testing.expectEqual(@as(u32, 6), diag.toSourceOffset(&marks, 2));
    try std.testing.expectEqual(@as(u32, 9), diag.toSourceOffset(&.{}, 9));
    const max = std.math.maxInt(u32);
    try std.testing.expectEqual(@as(u32, max), diag.toSourceOffset(&marks, max));
}

test "bag: the file table refuses a file past files_max, and the bag is unchanged" {
    // An `include tree is input: its size is an error return, never the
    // panic a `FileId` overflow was.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    try bag.files.ensureTotalCapacity(bag.arena, diag.files_max);
    for (0..diag.files_max) |i| {
        const id = try bag.addFile("f.vh", "");
        try std.testing.expectEqual(@as(u16, @intCast(i)), @backingInt(id));
    }
    try std.testing.expectError(error.TooManyFiles, bag.addFile("one.vh", "too many"));
    try std.testing.expectEqual(@as(usize, diag.files_max), bag.files.items.len);
    // The sentinel is no file: it reads as unknown.
    try std.testing.expectEqualStrings("<source>", bag.fileName(.none));
}

test "strip marks: a second strip of the same file keeps the original" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());

    _ = try bag.addFile("m.va", "a /*x*/ b\n");
    bag.setStrippedText(.root, "a   b\n", &.{});
    bag.setStrippedText(.root, "a   b\n", &.{});
    try std.testing.expectEqualStrings("a /*x*/ b\n", bag.sourceText(.root));
    try std.testing.expectEqualStrings("a   b\n", bag.fileText(.root));

    // An unknown id is ignored, and reads as no file.
    const nine: diag.FileId = @fromBackingInt(@intCast(9));
    bag.setStrippedText(nine, "zzz", &.{});
    try std.testing.expectEqualStrings("<source>", bag.fileName(nine));
    try std.testing.expectEqualStrings("", bag.fileText(nine));
}

/// The bag's counters against a model written from `Builder.emit`'s
/// contract: an allowed code is never counted, a full bag counts the rest as
/// suppressed, and otherwise (code, start) dedupes.
fn bagModelOne(_: void, s: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);

    const codes = [_]diag.Code{ .E0313, .W0650, .W0651 };
    const warning_levels = [_]Level{ .allow, .warn, .deny, .forbid };
    var level: [codes.len]Level = .{ .deny, .warn, .warn };
    for (1..codes.len) |c| {
        level[c] = warning_levels[s.index(warning_levels.len)];
        try bag.levels.set(codes[c], level[c]);
    }

    var seen = std.mem.zeroes([codes.len][32]bool);
    var kept: usize = 0;
    var errs: u32 = 0;
    var warns: u32 = 0;
    var dups: u32 = 0;
    var supp: u32 = 0;
    var n: usize = 0;
    while (n < 200 and !s.eos()) : (n += 1) {
        const c = s.index(codes.len);
        const start = s.index(32);
        try bag.add(.lower, codes[c], .{ .start = @intCast(start), .end = @intCast(start + 1) }, "", .{});
        if (level[c] == .allow) continue;
        if (seen[c][start]) {
            dups += 1;
            continue;
        }
        // Counted whether the cap keeps the row or drops it.
        if (level[c] == .warn) warns += 1 else errs += 1;
        if (kept >= diag.max_entries) {
            supp += 1;
            continue;
        }
        seen[c][start] = true;
        kept += 1;
    }
    try std.testing.expectEqual(kept, bag.count());
    try std.testing.expectEqual(supp, bag.suppressed);
    try std.testing.expectEqual(dups, bag.deduped);
    try std.testing.expectEqual(errs, bag.err_count);
    try std.testing.expectEqual(warns, bag.warn_count);
    try std.testing.expectEqual(errs != 0, bag.failed());
}

test "bag counters agree with a model of emit" {
    try std.testing.fuzz({}, bagModelOne, .{});
}

// ---------------------------------------------------------------------------
// Suggestions
// ---------------------------------------------------------------------------

test "edit distance: empty inputs, the limit, and the OSA restriction" {
    const d = diag.editDistance;
    try std.testing.expectEqual(@as(usize, 0), d("", "", 2));
    try std.testing.expectEqual(@as(usize, 3), d("abc", "", 5));
    try std.testing.expect(d("", "abc", 1) > 1);
    // Levenshtein's own example: substitute k, substitute e, insert g.
    try std.testing.expectEqual(@as(usize, 3), d("kitten", "sitting", 3));
    try std.testing.expect(d("kitten", "sitting", 2) > 2);
    // Lengths 2 and 6 differ by more than the limit: no table at all.
    try std.testing.expect(d("ab", "abcdef", 2) > 2);
    // OSA, not full Damerau-Levenshtein: CA -> ABC is 3 (it may not edit
    // the transposed pair again), where unrestricted DL says 2.
    try std.testing.expectEqual(@as(usize, 3), d("ca", "abc", 5));
}

/// Textbook optimal string alignment, the full matrix with no cap: the
/// oracle for `editDistance`'s rolling, early-exiting rows.
fn naiveOsa(a: []const u8, b: []const u8) usize {
    var t: [8][8]usize = undefined;
    for (0..a.len + 1) |i| t[i][0] = i;
    for (0..b.len + 1) |j| t[0][j] = j;
    for (1..a.len + 1) |i| {
        for (1..b.len + 1) |j| {
            const cost: usize = @intFromBool(a[i - 1] != b[j - 1]);
            var v = @min(t[i - 1][j] + 1, t[i][j - 1] + 1, t[i - 1][j - 1] + cost);
            if (i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1])
                v = @min(v, t[i - 2][j - 2] + 1);
            t[i][j] = v;
        }
    }
    return t[a.len][b.len];
}

test "edit distance equals the full matrix wherever it is within the limit" {
    // Every word over {a, b, c} of length 0 to 4: 1 + 3 + 9 + 27 + 81 = 121.
    var words: [121][4]u8 = undefined;
    var lens: [121]u8 = undefined;
    var n: usize = 0;
    for (0..5) |len| {
        var total: usize = 1;
        for (0..len) |_| total *= 3;
        for (0..total) |k| {
            var x = k;
            for (0..len) |p| {
                words[n][p] = "abc"[x % 3];
                x /= 3;
            }
            lens[n] = @intCast(len);
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 121), n);

    for (0..n) |i| {
        for (0..n) |j| {
            const a = words[i][0..lens[i]];
            const b = words[j][0..lens[j]];
            const want = naiveOsa(a, b);
            for (0..6) |limit| {
                const got = diag.editDistance(a, b, limit);
                if (want <= limit) {
                    try std.testing.expectEqual(want, got);
                } else {
                    try std.testing.expect(got > limit);
                }
            }
        }
    }
}

test "did you mean: exact names, distance before spelling, and maps" {
    const dym = diag.didYouMean;
    try std.testing.expect(dym("vds", &.{"vds"}) == null);
    try std.testing.expect(dym("vds", &.{}) == null);
    // "temperate" sorts first but is 2 edits away; the transposition is 1.
    try std.testing.expectEqualStrings("temperatrue", dym("temperature", &.{ "temperate", "temperatrue" }).?);
    // A tie goes to the lexicographically smaller name: 'a' < 'b'.
    try std.testing.expectEqualStrings("vas_", dym("vas", &.{ "vbs", "vas_" }).?);

    const gpa = std.testing.allocator;
    var map: std.StringHashMapUnmanaged(void) = .empty;
    defer map.deinit(gpa);
    for ([_][]const u8{ "vds", "vgs", "temp", "vas_", "vbs" }) |k| try map.put(gpa, k, {});
    try std.testing.expectEqualStrings("vds", diag.didYouMeanMap(void, "vdss", map).?);
    try std.testing.expectEqualStrings("vas_", diag.didYouMeanMap(void, "vas", map).?);
    try std.testing.expect(diag.didYouMeanMap(void, "completely_different", map) == null);
}

test "did you mean: every order of the candidates gives one answer" {
    // Against "vds" (limit 1) three are one edit away; "vd" is the smallest.
    const pool = [_][]const u8{ "vgs", "vdx", "vds", "vd" };
    var order: [4][]const u8 = undefined;
    var perms: usize = 0;
    for (0..4) |a| {
        for (0..4) |b| {
            for (0..4) |c| {
                for (0..4) |d| {
                    if (a == b or a == c or a == d or b == c or b == d or c == d) continue;
                    order = .{ pool[a], pool[b], pool[c], pool[d] };
                    try std.testing.expectEqualStrings("vd", diag.didYouMean("vds", &order).?);
                    perms += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 24), perms);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

test "render: an exact transcript, label above the primary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    // Line starts 0, 10, 19, 29; the `x` at 12 is line 2, column 3.
    try bag.setSingleFile("t.va", "module m;\n  x = 1;\nendmodule\n");

    var b = bag.build(.lower, .E0313, .{ .start = 12, .end = 13 });
    b.msg("`x`", .{});
    b.point("not declared", .{});
    b.label(.{ .start = 0, .end = 6 }, "in here", .{});
    b.note("n", .{});
    b.help("h", .{});
    try b.emit();

    try std.testing.expectEqualStrings(
        "error[E0313]: unknown variable: `x`\n" ++
            " --> t.va:2:3\n" ++
            "  |\n" ++
            "1 | module m;\n" ++
            "  | ------ in here\n" ++
            "2 |   x = 1;\n" ++
            "  |   ^ not declared\n" ++
            "  |\n" ++
            "  = note: LRM 6.8\n" ++
            "  = note: n\n" ++
            "  = help: h\n" ++
            "  = help: run `vera --explain E0313` for a detailed explanation\n" ++
            "\n" ++
            "error: could not compile due to 1 previous error(s)\n",
        try renderToString(&bag, .{}),
    );
}

test "render: a two-digit line widens the gutter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    // Ten one-letter lines: line k starts at 2(k - 1), so `j` is 18, `i` 16.
    try bag.setSingleFile("g.va", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n");

    var b = bag.build(.parse, .E0207, .{ .start = 18, .end = 19 });
    b.label(.{ .start = 16, .end = 17 }, "prev", .{});
    try b.emit();

    try std.testing.expectEqualStrings(
        "error[E0207]: unexpected token\n" ++
            "  --> g.va:10:1\n" ++
            "   |\n" ++
            "9  | i\n" ++
            "   | - prev\n" ++
            "10 | j\n" ++
            "   | ^\n" ++
            "   |\n" ++
            "   = note: LRM annex A.1.2\n" ++
            "\n",
        try renderToString(&bag, .{ .explain_hint = false, .summary = false }),
    );
}

test "render: no span means no location and no snippet" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    try bag.add(.lower, .E0313, diag.Span.none, "m", .{});
    try std.testing.expectEqualStrings(
        "error[E0313]: unknown variable: m\n  = note: LRM 6.8\n\n",
        try renderToString(&bag, .{ .explain_hint = false, .summary = false }),
    );
}

test "render: citations name annexes and IEEE 1364 clauses as written" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    try bag.add(.parse, .E0207, diag.Span.none, "", .{});
    try bag.add(.preprocess, .E0146, diag.Span.none, "", .{});
    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    try std.testing.expect(std.mem.find(u8, out, "= note: LRM annex A.1.2\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "= note: LRM IEEE 1364-2005 28\n") != null);
}

test "render: the summary line counts errors and warnings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var errs = diag.Bag.init(arena);
    try errs.add(.lower, .E0313, diag.Span.none, "", .{});
    try std.testing.expect(std.mem.endsWith(u8, try renderToString(&errs, .{}), "\nerror: could not compile due to 1 previous error(s)\n"));
    try errs.add(.proof, .W0650, diag.Span.none, "", .{});
    try std.testing.expect(std.mem.endsWith(u8, try renderToString(&errs, .{}), "\nerror: could not compile due to 1 previous error(s); 1 warning(s) emitted\n"));
    try std.testing.expect(std.mem.find(u8, try renderToString(&errs, .{ .summary = false }), "could not compile") == null);

    var warns = diag.Bag.init(arena);
    try warns.add(.proof, .W0650, .at(1), "", .{});
    try warns.add(.proof, .W0651, .at(2), "", .{});
    try std.testing.expect(std.mem.endsWith(u8, try renderToString(&warns, .{}), "\nwarning: 2 warning(s) emitted\n"));
}

test "render: a run-time error is no compile failure (#72)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Only `.run` errors: the error lines alone, as the native runtime prints.
    var ran = diag.Bag.init(arena);
    try ran.add(.run, .E1100, diag.Span.none, "", .{});
    const out = try renderToString(&ran, .{});
    try std.testing.expect(std.mem.find(u8, out, "could not compile") == null);
    try std.testing.expect(std.mem.startsWith(u8, out, "error[E1100]"));
    try std.testing.expect(ran.failed());
    // A warning beside it is still counted; a compile error still is too.
    try ran.add(.lower, .W1150, .at(1), "", .{});
    try std.testing.expect(std.mem.endsWith(u8, try renderToString(&ran, .{}), "\nwarning: 1 warning(s) emitted\n"));
    try ran.add(.lower, .E1100, .at(2), "", .{});
    try std.testing.expect(std.mem.endsWith(u8, try renderToString(&ran, .{}), "\nerror: could not compile due to 1 previous error(s); 1 warning(s) emitted\n"));
}

test "render: a capped bag says how many it dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    for (0..diag.max_entries + 2) |i| try bag.add(.lower, .E0313, .at(@intCast(i + 1)), "", .{});
    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    try std.testing.expect(std.mem.endsWith(u8, out, "\nwarning: 2 further diagnostic(s) not shown (limit 64)\n"));
}

test "render: the explain hint follows the first diagnostic of each code only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    try bag.add(.lower, .E0313, .at(1), "", .{});
    try bag.add(.lower, .E0313, .at(2), "", .{});
    try bag.add(.proof, .W0650, .at(3), "", .{});
    const out = try renderToString(&bag, .{ .summary = false });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "--explain E0313"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "--explain W0650"));
    const quiet = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, quiet, "--explain"));
}

test "render: a replacement is drawn with ~, a deletion with one ~" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    try bag.setSingleFile("f.va", "real vds;\n");

    var b = bag.build(.lower, .E0313, .{ .start = 5, .end = 8 });
    b.suggestHere("vgs");
    try b.emit();
    var c = bag.build(.lower, .E0207, .{ .start = 4, .end = 8 });
    c.suggest(.{ .span = .{ .start = 4, .end = 8 }, .replacement = "" }, "drop it", .{});
    try c.emit();

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    // `vds` (bytes 5..8) becomes `vgs`, ruled under its three columns.
    try std.testing.expect(std.mem.find(u8, out, "1 | real vgs;\n  |      ~~~\n") != null);
    // ` vds` (4..8) removed; the ruler is one `~` where it was.
    try std.testing.expect(std.mem.find(u8, out, "1 | real;\n  |     ~\n") != null);
}

test "render: a fix's ruler counts the replacement's columns, not bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    try bag.setSingleFile("f.va", "real vds;\n");

    var b = bag.build(.lower, .E0313, .{ .start = 5, .end = 8 });
    b.suggest(.{ .span = diag.Span.at(5), .replacement = "µ" }, "prefix it", .{});
    try b.emit();
    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    // `µ` is two bytes and one column: one `+`, as a caret counts it.
    try std.testing.expect(std.mem.find(u8, out, "1 | real µvds;\n  |      +\n") != null);
}

test "render: a span at a CRLF newline or past the end clamps to its line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Offset 3 is the '\n' of "ab\r\n": byte column 4 of a line whose text,
    // without "\r\n", is two columns wide. The caret goes after `ab`.
    var crlf = diag.Bag.init(arena);
    try crlf.setSingleFile("c.va", "ab\r\ncd\r\n");
    try crlf.add(.parse, .E0207, .{ .start = 3, .end = 4 }, "", .{});
    const out = try renderToString(&crlf, .{ .explain_hint = false, .summary = false });
    try std.testing.expect(std.mem.find(u8, out, " --> c.va:1:3\n  |\n1 | ab\n  |   ^\n") != null);

    // Offset 5 in a three-byte file: the last line, caret after its end.
    var eof = diag.Bag.init(arena);
    try eof.setSingleFile("e.va", "abc");
    try eof.add(.parse, .E0207, .{ .start = 5, .end = 6 }, "", .{});
    const out2 = try renderToString(&eof, .{ .explain_hint = false, .summary = false });
    try std.testing.expect(std.mem.find(u8, out2, " --> e.va:1:4\n  |\n1 | abc\n  |    ^\n") != null);
}

test "render: a span in an unknown file does not poison a known file's lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    _ = try bag.addFile("top.va", "a\nb\n");
    const f1 = try bag.addFile("f1.vh", "x\ny\nz\n");

    // Sorted first (start 3), in a file nobody registered.
    var a = bag.build(.preprocess, .E0101, .{ .start = 3, .end = 4 });
    a.inFile(@fromBackingInt(@intCast(7)));
    try a.emit();
    // Offset 4 of "x\ny\nz\n" is the `z` that starts line 3.
    var b = bag.build(.preprocess, .E0102, .{ .start = 4, .end = 5 });
    b.inFile(f1);
    try b.emit();

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    try std.testing.expect(std.mem.find(u8, out, " --> f1.vh:3:1\n") != null);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try diag.renderJson(&bag, &aw.writer);
    try std.testing.expect(std.mem.find(u8, aw.writer.buffered(), "\"file\":\"f1.vh\",\"line\":3,\"col\":1,") != null);
}

test "render: a label in another file gets its own header" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag.Bag.init(arena_state.allocator());
    _ = try bag.addFile("top.va", "aaa\nbbb\nccc\n");
    const f1 = try bag.addFile("inc.vh", "xxx\nyyy\n");
    // Preprocessed text: top.va's 12 bytes, then inc.vh from offset 12.
    bag.map = .{ .segs = &[_]diag.Segment{
        .{ .out_start = 0, .in_start = 0, .file = .root, .kind = .verbatim },
        .{ .out_start = 12, .in_start = 0, .file = f1, .kind = .verbatim },
    } };

    var b = bag.build(.lower, .E0313, .{ .start = 4, .end = 7 });
    b.label(.{ .start = 16, .end = 19 }, "declared here", .{});
    try b.emit();

    try std.testing.expectEqualStrings(
        "error[E0313]: unknown variable\n" ++
            " --> top.va:2:1\n" ++
            "  |\n" ++
            "2 | bbb\n" ++
            "  | ^^^\n" ++
            "  |\n" ++
            " ::: inc.vh:2:1\n" ++
            "  |\n" ++
            "2 | yyy\n" ++
            "  | --- declared here\n" ++
            "  |\n" ++
            "  = note: LRM 6.8\n" ++
            "\n",
        try renderToString(&bag, .{ .explain_hint = false, .summary = false }),
    );
}

test "render: columns are measured in the original text, before stripping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    // Stripped "def" is 6..9; in the original it is 12..15, column 13.
    _ = try bag.addFile("m.va", "abc /* c */ def\n");
    bag.setStrippedText(.root, "abc   def\n", &.{.{ .out = 5, .src = 11 }});
    try bag.add(.parse, .E0207, .{ .start = 6, .end = 9 }, "", .{});

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    try std.testing.expect(std.mem.find(u8, out, " --> m.va:1:13\n  |\n1 | abc /* c */ def\n  |             ^^^\n") != null);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try diag.renderJson(&bag, &aw.writer);
    try std.testing.expect(std.mem.find(u8, aw.writer.buffered(), "\"line\":1,\"col\":13,\"byte_start\":6,\"byte_end\":9}") != null);
}

test "render: output depends on the diagnostics, not their emission order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = "module m;\n  x = 1;\n  y = 2;\nendmodule\n";

    var forward = diag.Bag.init(arena);
    try forward.setSingleFile("o.va", src);
    try forward.add(.lower, .E0313, .{ .start = 12, .end = 13 }, "x", .{});
    try forward.add(.proof, .W0650, .{ .start = 21, .end = 22 }, "y", .{});

    var backward = diag.Bag.init(arena);
    try backward.setSingleFile("o.va", src);
    try backward.add(.proof, .W0650, .{ .start = 21, .end = 22 }, "y", .{});
    try backward.add(.lower, .E0313, .{ .start = 12, .end = 13 }, "x", .{});

    const once = try renderToString(&forward, .{});
    try std.testing.expectEqualStrings(once, try renderToString(&backward, .{}));
    // And rendering is repeatable: a second render of the same bag agrees.
    try std.testing.expectEqualStrings(once, try renderToString(&forward, .{}));
}

test "json: every line parses, and every string round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    try bag.setSingleFile("j.va", "analog x;\n");

    const msg = "q\" b\\ n\n t\t c\x01 µ";
    var b = bag.build(.lower, .E0313, .{ .start = 7, .end = 8 });
    b.msg("{s}", .{msg});
    b.label(.{ .start = 0, .end = 6 }, "in {s}", .{"analog"});
    b.suggest(.{ .span = .{ .start = 7, .end = 8 }, .replacement = "y" }, "rename", .{});
    try b.emit();
    try bag.add(.proof, .W0650, diag.Span.none, "", .{});

    var aw: std.Io.Writer.Allocating = .init(arena);
    try diag.renderJson(&bag, &aw.writer);
    const out = aw.writer.buffered();
    // One line per diagnostic: the message's '\n' is escaped, not written.
    try std.testing.expectEqual(@as(usize, 2), std.mem.countScalar(u8, out, '\n'));

    var lines = std.mem.splitScalar(u8, out[0 .. out.len - 1], '\n');
    // Sorted: the span-less warning (start 0) first.
    const first = try std.json.parseFromSlice(std.json.Value, arena, lines.next().?, .{});
    const warning = first.value.object;
    try std.testing.expectEqualStrings("W0650", warning.get("code").?.string);
    try std.testing.expectEqualStrings("warning", warning.get("level").?.string);
    try std.testing.expect(warning.get("span").? == .null);

    const second = try std.json.parseFromSlice(std.json.Value, arena, lines.next().?, .{});
    const e = second.value.object;
    try std.testing.expectEqualStrings(msg, e.get("message").?.string);
    try std.testing.expectEqualStrings("lower", e.get("stage").?.string);
    try std.testing.expectEqualStrings("6.8", e.get("lrm").?.string);
    try std.testing.expectEqualStrings("unknown variable", e.get("title").?.string);
    const span = e.get("span").?.object;
    try std.testing.expectEqualStrings("j.va", span.get("file").?.string);
    try std.testing.expectEqual(@as(i64, 1), span.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 8), span.get("col").?.integer);
    try std.testing.expectEqual(@as(i64, 7), span.get("byte_start").?.integer);
    try std.testing.expectEqual(@as(i64, 8), span.get("byte_end").?.integer);
    const labels = e.get("labels").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), labels.len);
    try std.testing.expectEqualStrings("in analog", labels[0].object.get("text").?.string);
    const notes = e.get("notes").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    try std.testing.expectEqualStrings("help", notes[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("y", notes[0].object.get("fix").?.object.get("replacement").?.string);
}

test "explain: a code with no citation prints no LRM line" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try diag.explain(.E1015, &aw.writer, .off);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "E1015: more nets and unknowns than a 32-bit row index holds\n\nNot a language rule"));
    try std.testing.expect(std.mem.find(u8, out, "\nLRM ") == null);

    var aw2: std.Io.Writer.Allocating = .init(gpa);
    defer aw2.deinit();
    try diag.explain(.E0207, &aw2.writer, .off);
    try std.testing.expect(std.mem.startsWith(u8, aw2.writer.buffered(), "E0207: unexpected token\nLRM annex A.1.2\n\n"));
}

/// Arbitrary text, arbitrary (inverted, past-the-end) spans, labels and
/// fixes: rendering never panics, prints one headline per kept row, and the
/// JSON line and column of each primary span match a byte-by-byte count.
fn renderAnyOne(_: void, s: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text_buf: [256]u8 = undefined;
    const text = text_buf[0..s.slice(&text_buf)];
    var bag = diag.Bag.init(arena);
    try bag.setSingleFile("f.va", text);

    // Now and then out to maxInt(u32): a span no stage should make, which
    // must still render rather than overflow.
    const hi: u32 = if (s.boolWeighted(7, 1)) @intCast(text.len + 4) else std.math.maxInt(u32);
    var n: usize = 0;
    while (n < 80 and !s.eos()) : (n += 1) {
        const a = s.valueRangeAtMost(u32, 0, hi);
        const z = s.valueRangeAtMost(u32, 0, hi);
        var b = bag.build(.parse, .E0207, .{ .start = a, .end = z });
        if (s.boolWeighted(1, 1)) b.point("p", .{});
        if (s.boolWeighted(1, 1)) {
            const ls = s.valueRangeAtMost(u32, 0, hi);
            b.label(.{ .start = ls, .end = s.valueRangeAtMost(u32, 0, hi) }, "l", .{});
        }
        if (s.boolWeighted(1, 1)) {
            const fs = s.valueRangeAtMost(u32, 0, hi);
            b.suggest(.{ .span = .{ .start = fs, .end = s.valueRangeAtMost(u32, 0, hi) }, .replacement = "r\tµ" }, "h", .{});
        }
        try b.emit();
    }

    var text_out: std.Io.Writer.Allocating = .init(arena);
    try diag.render(&bag, &text_out.writer, .{});
    try std.testing.expectEqual(bag.count(), std.mem.count(u8, text_out.writer.buffered(), "error[E0207]"));

    var json_out: std.Io.Writer.Allocating = .init(arena);
    try diag.renderJson(&bag, &json_out.writer);
    const json = json_out.writer.buffered();
    try std.testing.expectEqual(bag.count(), std.mem.countScalar(u8, json, '\n'));

    var lines = std.mem.splitScalar(u8, json, '\n');
    for (0..bag.count()) |i| {
        const line = lines.next().?;
        const span = bag.at(i).span;
        if (span.isNone()) {
            try std.testing.expect(std.mem.find(u8, line, "\"span\":null") != null);
            continue;
        }
        const upto = @min(span.start, text.len);
        const want_line = std.mem.countScalar(u8, text[0..upto], '\n') + 1;
        const line_start = if (std.mem.findScalarLast(u8, text[0..upto], '\n')) |nl| nl + 1 else 0;
        const want = try arena.print("\"span\":{{\"file\":\"f.va\",\"line\":{d},\"col\":{d},\"byte_start\":{d},", .{
            want_line, span.start - line_start + 1, span.start,
        });
        try std.testing.expect(std.mem.find(u8, line, want) != null);
    }
}

test "render never panics on any span over any text" {
    try std.testing.fuzz({}, renderAnyOne, .{ .corpus = &.{ "ab\r\ncd", "\t\tµ\n", "x" } });
}

// ---------------------------------------------------------------------------
// The catalogue
// ---------------------------------------------------------------------------

test "every catalogue citation is a clause, an annex, or an IEEE 1364-2005 clause" {
    // `annexWord` reads the first byte; this pins what it may see. Code values
    // are dense (the catalogue's comptime check), so a runtime loop covers all.
    for (0..@typeInfo(diag.Code).@"enum".field_names.len) |i| {
        const lrm = diag.info(@fromBackingInt(@intCast(i))).lrm;
        if (lrm.len == 0) continue;
        const ok = (lrm[0] >= '0' and lrm[0] <= '9') or
            (lrm[0] >= 'A' and lrm[0] <= 'H') or
            std.mem.startsWith(u8, lrm, "IEEE 1364-2005 ");
        try std.testing.expect(ok);
    }
}

test "render: a span out to maxInt(u32) over stripped text clamps, never overflows" {
    // Offsets come from every stage; one bad end must cost a wide caret, not
    // an integer-overflow panic in the strip map (`toSourceOffset`).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    _ = try bag.addFile("m.va", "abc /* c */ def\n");
    bag.setStrippedText(.root, "abc   def\n", &.{.{ .out = 5, .src = 11 }});

    const max = std.math.maxInt(u32);
    var b = bag.build(.lower, .E0313, .{ .start = 6, .end = max });
    b.suggest(.{ .span = .{ .start = 6, .end = max }, .replacement = "x" }, "h", .{});
    try b.emit();
    try bag.add(.lower, .E0207, .{ .start = max - 1, .end = max }, "", .{});
    // No trailing newline: the last line has text past any offset.
    const f1 = try bag.addFile("n.va", "xy");
    var c = bag.build(.preprocess, .E0101, .{ .start = max - 1, .end = max });
    c.inFile(f1);
    try c.emit();

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    try std.testing.expect(std.mem.find(u8, out, " --> m.va:1:13\n") != null);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try diag.renderJson(&bag, &aw.writer);
    try std.testing.expectEqual(@as(usize, 3), std.mem.countScalar(u8, aw.writer.buffered(), '\n'));
}

test "every code an explanation cites exists" {
    // A cross-reference ("see E0572") is the reader's next `--explain`; a
    // typo or a dropped code would send them nowhere.
    for (0..@typeInfo(diag.Code).@"enum".field_names.len) |i| {
        const text = diag.info(@fromBackingInt(@intCast(i))).explain;
        for (0..text.len -| 4) |k| {
            if (text[k] != 'E' and text[k] != 'W') continue;
            if (k > 0 and std.ascii.isAlphanumeric(text[k - 1])) continue;
            const word = text[k..][0..5];
            if (!std.ascii.isDigit(word[1]) or !std.ascii.isDigit(word[4])) continue;
            if (k + 5 < text.len and std.ascii.isAlphanumeric(text[k + 5])) continue;
            if (std.meta.stringToEnum(diag.Code, word) == null) {
                std.debug.print("{s} cites {s}\n", .{ diag.Code.name(@fromBackingInt(@intCast(i))), word });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "render: the summary counts the errors the cap dropped, and one fails the bag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A full bag of warnings, then an error past the cap: the compilation
    // still failed, and the summary says so.
    var bag = diag.Bag.init(arena);
    for (0..diag.max_entries) |i| try bag.add(.proof, .W0650, .at(@intCast(i + 1)), "", .{});
    try bag.add(.lower, .E0313, .at(1000), "", .{});
    try bag.add(.run, .E1100, .at(1001), "", .{}); // a run error, dropped: no compile error
    try bag.add(.proof, .W0651, .at(1002), "", .{});
    try std.testing.expect(bag.failed());
    try std.testing.expect(std.mem.endsWith(u8, try renderToString(&bag, .{ .explain_hint = false }),
        \\warning: 3 further diagnostic(s) not shown (limit 64)
        \\error: could not compile due to 1 previous error(s); 65 warning(s) emitted
        \\
    ));

    // Every error counts, kept or dropped.
    var errs = diag.Bag.init(arena);
    for (0..diag.max_entries + 2) |i| try errs.add(.lower, .E0313, .at(@intCast(i + 1)), "", .{});
    try std.testing.expect(std.mem.endsWith(u8, try renderToString(&errs, .{ .explain_hint = false }), "\nerror: could not compile due to 66 previous error(s)\n"));
}
