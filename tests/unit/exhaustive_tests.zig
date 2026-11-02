//! Stage-boundary exhaustiveness guard: lib/ and src/ sources -> a failure for
//! every `else =>` over a boundary enum whose line lacks `// else: <reason>`.
//!
//! It parses the real source with `std.zig.Ast`, because only the prong labels
//! say which enum a switch is over.
//!
//! The portability guard is its sibling: lib/ and src/ ->
//! a failure for every direct OS API (`os_apis`) outside `os_allowed` whose
//! line lacks `// os: <reason>`. VerA builds for every target because no
//! code, compiled or emitted, calls an OS but through `std`.

const std = @import("std");
const Io = std.Io;
const ZigAst = std.zig.Ast;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const op = @import("ir").op;
const repo_root = @import("repo_options").repo_root;

/// The boundary enums, read from the real types so the registry cannot drift.
/// A switch is attributed to the FIRST entry whose fields cover all its prong
/// labels, so an enum whose names overlap an earlier one's comes after it.
/// `token.Tag` (lexer to parser) is last: its `plus`/`int_literal` overlap
/// UnaryOp and ExprTag, which keep those switches.
const registry = [_]struct { name: []const u8, fields: []const []const u8 }{
    .{ .name = "Ast.ExprTag", .fields = @typeInfo(Ast.ExprTag).@"enum".field_names },
    .{ .name = "Ast.Stmt", .fields = @typeInfo(Ast.Stmt).@"union".field_names },
    .{ .name = "Ast.BinaryOp", .fields = @typeInfo(Ast.BinaryOp).@"enum".field_names },
    .{ .name = "Ast.UnaryOp", .fields = @typeInfo(Ast.UnaryOp).@"enum".field_names },
    .{ .name = "Ast.NetKind", .fields = @typeInfo(Ast.NetKind).@"enum".field_names },
    .{ .name = "Ast.GateKind", .fields = @typeInfo(Ast.GateKind).@"enum".field_names },
    .{ .name = "Ast.Direction", .fields = @typeInfo(Ast.Direction).@"enum".field_names },
    .{ .name = "Ast.Type", .fields = @typeInfo(Ast.Type).@"enum".field_names },
    .{ .name = "Mir.Opcode", .fields = @typeInfo(Mir.Opcode).@"enum".field_names },
    .{ .name = "Mir.OpClass", .fields = @typeInfo(Mir.OpClass).@"enum".field_names },
    .{ .name = "Mir.DefKind", .fields = @typeInfo(Mir.DefKind).@"enum".field_names },
    .{ .name = "op.OpKind", .fields = @typeInfo(op.OpKind).@"enum".field_names },
    // After OpKind: its `ddt`/`cross` overlap OpKind, which keeps those switches.
    .{ .name = "Mir.Callee", .fields = @typeInfo(Mir.Callee).@"enum".field_names },
    .{ .name = "pp_directive.Directive", .fields = @typeInfo(@import("frontend").pp_directive.Directive).@"enum".field_names },
    .{ .name = "token.Tag", .fields = @typeInfo(@import("frontend").token.Tag).@"enum".field_names },
};

fn has(fields: []const []const u8, s: []const u8) bool {
    for (fields) |f| if (std.mem.eql(u8, f, s)) return true;
    return false;
}

/// Prints every unannotated `else` on a boundary enum in one file, outside
/// `test` blocks, and returns how many.
fn scan(arena: std.mem.Allocator, path: []const u8, src: [:0]const u8) !usize {
    var tree = try ZigAst.parse(arena, src, .{ .mode = .zig });
    if (tree.errors.len != 0) {
        std.debug.print("{s}: does not parse\n", .{path});
        return error.ParseFailed;
    }
    // Enclosing scopes as token spans; the innermost fn names the site.
    const Span = struct { first: u32, last: u32, name: ?[]const u8 };
    var spans: std.ArrayList(Span) = .empty;
    var n_found: usize = 0;
    for (0..tree.nodes.len) |i| {
        const n: ZigAst.Node.Index = @fromBackingInt(@intCast(i));
        switch (tree.nodeTag(n)) {
            .fn_decl => {
                var buf: [1]ZigAst.Node.Index = undefined;
                const tok = tree.fullFnProto(&buf, n).?.name_token orelse continue;
                try spans.append(arena, .{ .first = tree.firstToken(n), .last = tree.lastToken(n), .name = tree.tokenSlice(tok) });
            },
            .test_decl => try spans.append(arena, .{ .first = tree.firstToken(n), .last = tree.lastToken(n), .name = null }),
            else => {}, // else: only fn and test scopes name a site
        }
    }
    for (0..tree.nodes.len) |i| {
        const sw = tree.fullSwitch(@fromBackingInt(@intCast(i))) orelse continue;
        var else_tok: ?ZigAst.TokenIndex = null;
        var labels: std.ArrayList([]const u8) = .empty;
        for (sw.ast.cases) |c| {
            const case = tree.fullSwitchCase(c).?;
            if (case.ast.values.len == 0) else_tok = case.ast.arrow_token;
            for (case.ast.values) |v| if (tree.nodeTag(v) == .enum_literal)
                try labels.append(arena, tree.tokenSlice(tree.nodeMainToken(v)));
        }
        const et = else_tok orelse continue;
        if (labels.items.len == 0) continue;
        const hit = for (registry) |r| {
            const all = for (labels.items) |l| {
                if (!has(r.fields, l)) break false;
            } else true;
            if (all) break r.name;
        } else continue;
        const loc = tree.tokenLocation(0, et);
        if (std.mem.find(u8, src[loc.line_start..loc.line_end], "// else:") != null) continue;

        var in_test = false;
        var best: ?Span = null;
        for (spans.items) |s| {
            if (et < s.first or et > s.last) continue;
            if (s.name == null) in_test = true;
            if (s.name != null and (best == null or s.last - s.first < best.?.last - best.?.first)) best = s;
        }
        if (in_test) continue;
        const fn_name = if (best) |b| b.name.? else "-";
        std.debug.print(
            "{s}:{d}: `else =>` over {s} in {s}\n    fix: write the prongs out so the compiler checks them, " ++
                "or put `// else: <reason>` on the else line\n",
            .{ path, loc.line + 1, hit, fn_name },
        );
        n_found += 1;
    }
    return n_found;
}

test "every `else` over a boundary enum is written out or annotated" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    // One file's source, AST and scratch at a time: `scan` prints what it
    // finds before it returns, so nothing outlives the file.
    var file_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer file_state.deinit();
    var found: usize = 0;
    for ([_][]const u8{ "lib", "src" }) |sub| {
        const abs = try std.fs.path.join(arena, &.{ repo_root, sub });
        var dir = try Io.Dir.cwd().openDir(io, abs, .{ .iterate = true });
        defer dir.close(io);
        var w = try dir.walk(arena);
        while (try w.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".zig")) continue;
            _ = file_state.reset(.retain_capacity);
            const fa = file_state.allocator();
            const src = try dir.readFileAllocOptions(io, e.path, fa, .limited(1 << 24), .of(u8), 0);
            found += try scan(fa, try std.fs.path.join(fa, &.{ sub, e.path }), src);
        }
    }
    if (found != 0) {
        std.debug.print("exhaustive guard: {d} unannotated `else =>`\n", .{found});
        return error.ExhaustiveGuard;
    }
}

/// Spellings that reach an OS, or a C ABI's varargs, past `std`'s portable
/// layer. Matched as text, so a `\\` line of emitted device code counts too.
const os_apis = [_][]const u8{
    "std.posix", "std.os.",   "std.c.",  "@cImport", "std.DynLib",
    "@cVaStart", "@cVaArg",   "@cVaEnd", "@cVaCopy", "std.lang.VaList",
    ".os.tag",   "extern \"", "\"/tmp",  "\"/dev/",
};

/// The files that may name one: each says why in its header.
const os_allowed = [_][]const u8{"src/dynlib.zig"};

/// Counts every line of `src` naming an `os_apis` entry without `// os:`,
/// comment lines aside, printing each when `report`.
fn scanOs(path: []const u8, src: []const u8, report: bool) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "//")) continue;
        if (std.mem.find(u8, line, "// os:") != null) continue;
        for (os_apis) |api| if (std.mem.find(u8, line, api) != null) {
            if (report) std.debug.print(
                "{s}:{d}: `{s}` is an OS API\n    fix: use the portable `std` API, move it to {s}, " ++
                    "or put `// os: <why every target still builds>` on the line\n",
                .{ path, line_no, api, os_allowed[0] },
            );
            n += 1;
            break;
        };
    }
    return n;
}

test "no OS API outside the allowlisted module" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var found: usize = 0;
    const root = try Io.Dir.cwd().openDir(io, repo_root, .{});
    for ([_][]const u8{ "lib", "src" }) |sub| {
        var dir = try root.openDir(io, sub, .{ .iterate = true });
        defer dir.close(io);
        var w = try dir.walk(arena);
        while (try w.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".zig")) continue;
            // `/`, whatever the host's separator, so the allowlist matches.
            const rel = try std.mem.concat(arena, u8, &.{ sub, "/", e.path });
            std.mem.replaceScalar(u8, rel, '\\', '/');
            if (for (os_allowed) |a| {
                if (std.mem.eql(u8, a, rel)) break true;
            } else false) continue;
            found += scanOs(rel, try dir.readFileAlloc(io, e.path, arena, .limited(1 << 24)), true);
        }
    }
    if (found != 0) {
        std.debug.print("portability guard: {d} OS API use(s)\n", .{found});
        return error.PortabilityGuard;
    }
}

test "the portability guard sees what it is for" {
    try std.testing.expectEqual(@as(usize, 1), scanOs("x.zig", "const p = std.posix.getpid();", false));
    try std.testing.expectEqual(@as(usize, 1), scanOs("x.zig", "    \\\\    var ap = @cVaStart();", false));
    try std.testing.expectEqual(@as(usize, 0), scanOs("x.zig", "/// std.posix in prose", false));
    try std.testing.expectEqual(@as(usize, 0), scanOs("x.zig", "const t = std.os.tag; // os: a reason", false));
    try std.testing.expectEqual(@as(usize, 0), scanOs("x.zig", "const io = std.Io.Threaded;", false));
}
