//! IEEE 1364-2005 §13.2 library map files -> a `Map`: every library's file
//! path specifications in declaration order, and the library a source file is
//! compiled into.
//!
//! IEEE 1364-2005 clauses cited: §13.2.1, §13.2.1.1, §13.2.2, §13.2.3, §13.5.1.

const std = @import("std");
const diag = @import("diag");
const Preprocessor = @import("preprocessor.zig");
const deep_stack = @import("base").deep_stack;
const Io = std.Io;

/// §13.2.1.1's resolution order, most specific first: a specification that
/// ends with an explicit filename, a wildcarded filename, or a directory.
pub const Class = enum(u2) { file, wildcard, directory };

/// One `file_path_spec`, resolved against its map file's directory.
pub const Spec = struct {
    /// Absolute, `.` and `..` resolved; `?`, `*` and `...` still wildcards.
    /// A directory specification ends in `/*` (§13.2.1: "Identical to /*").
    pattern: []const u8,
    class: Class,
};

/// One §13.2.1 `library` declaration: its name and every file path
/// specification it lists, in order. Slices live in `load`'s arena.
pub const Library = struct { name: []const u8, specs: []const Spec };

/// Where §13.2.1.1 puts a source file.
const Placement = union(enum) {
    lib: []const u8,
    /// Two libraries whose best matching specifications tie: an error.
    ambiguous: [2][]const u8,
};

/// Every library map file read, merged; built by `load`, all slices in its
/// arena.
pub const Map = struct {
    /// In declaration order, map files in the order given; a name declared
    /// twice is one library holding both declarations' specifications.
    libraries: []const Library = &.{},
    /// A.1.1's `-incdir` lists, every library's, in declaration order, each
    /// resolved against its map file's directory.
    incdirs: []const []const u8 = &.{},

    /// §13.2.1.1 the library `file` (absolute) maps into: the one whose
    /// specification matches it most specifically, else `work` (§13.2.1).
    /// A tie names the first two libraries, in declaration order, whose best
    /// specifications share the most specific class. O(specifications).
    pub fn libraryOf(map: Map, file: []const u8) Placement {
        var best: ?Class = null;
        var lib: []const u8 = "work";
        var tie: ?[]const u8 = null;
        for (map.libraries) |l| {
            var got: ?Class = null;
            for (l.specs) |s| if (matches(s.pattern, file)) {
                if (got == null or @backingInt(s.class) < @backingInt(got.?)) got = s.class;
            };
            const c = got orelse continue;
            if (best == null or @backingInt(c) < @backingInt(best.?)) {
                best = c;
                lib = l.name;
                tie = null;
            } else if (c == best.? and tie == null) tie = l.name;
        }
        // A tie is only ever recorded against a best match.
        std.debug.assert(best != null or tie == null);
        if (tie) |t| return .{ .ambiguous = .{ lib, t } };
        return .{ .lib = lib };
    }

    /// §13.5.1 the search order with no configuration: "the library
    /// declaration order in the library map file", then `work` when no map
    /// declares it. The slice is allocated in `arena`.
    pub fn order(map: Map, arena: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
        const work = map.declares("work") == null;
        const out = try arena.alloc([]const u8, map.libraries.len + @intFromBool(work));
        for (map.libraries, out[0..map.libraries.len]) |l, *o| o.* = l.name;
        if (work) out[map.libraries.len] = "work";
        return out;
    }

    /// Returns the index of the library called `name` in `libraries`, or null.
    pub fn declares(map: Map, name: []const u8) ?usize {
        for (map.libraries, 0..) |l, i| if (std.mem.eql(u8, l.name, name)) return i;
        return null;
    }
};

/// `load`'s errors: `MapFailed` after a refusal reported as E0244.
pub const Error = error{ MapFailed, OutOfMemory };

/// Reads the map files at `paths`, in order (§13.2.1: "If multiple map files
/// are specified, then they shall be read in the order in which they are
/// specified"). A refusal is E0244 in `bag`, whose files it registers, and
/// `error.MapFailed`: an unreadable file, a statement other than `library`
/// or `include` (§13.2.2), a malformed one (Syntax 13-2), or an `include`
/// cycle (a map file that includes itself, directly or through others,
/// which would never end; any finite nesting is read). Every slice of the
/// `Map` lives in `arena`.
pub fn load(arena: std.mem.Allocator, io: Io, bag: *diag.Bag, paths: []const []const u8) Error!Map {
    var l: Loader = .{ .arena = arena, .io = io, .bag = bag };
    for (paths) |p| try l.read(p, null);
    std.debug.assert(l.open.items.len == 0); // every `read` pops what it pushed
    const out = try arena.alloc(Library, l.libs.items.len);
    for (l.libs.items, out) |b, *o| o.* = .{ .name = b.name, .specs = b.specs.items };
    return .{ .libraries = out, .incdirs = l.incdirs.items };
}

const Loader = struct {
    arena: std.mem.Allocator,
    io: Io,
    bag: *diag.Bag,
    libs: std.ArrayList(struct { name: []const u8, specs: std.ArrayList(Spec) = .empty }) = .empty,
    incdirs: std.ArrayList([]const u8) = .empty,
    /// The map files open now, outermost first, by real path: an `include`
    /// of one of them is a cycle.
    open: std.ArrayList([]const u8) = .empty,

    /// `at` is the `include` that names `path`, for the diagnostic when the
    /// file cannot be read. Asserts that `at` is null exactly when no map
    /// file is open: `load` reads the outermost ones, an `include` the rest.
    fn read(l: *Loader, path: []const u8, at: ?Site) Error!void {
        std.debug.assert((at == null) == (l.open.items.len == 0));
        const text = Preprocessor.readText(l.io, .cwd(), path, l.arena) catch |e|
            return l.fail(at, "cannot read library map `{s}`: {t}", .{ path, e });
        const real = Io.Dir.cwd().realPathFileAlloc(l.io, path, l.arena) catch |e|
            return l.fail(at, "cannot resolve library map `{s}`: {t}", .{ path, e });
        for (l.open.items, 0..) |o, k| {
            if (!std.mem.eql(u8, o, real)) continue;
            var chain: std.ArrayList(u8) = .empty;
            for (l.open.items[k..]) |c| try chain.print(l.arena, "{s} -> ", .{c});
            try chain.appendSlice(l.arena, real);
            return l.fail(at, "library map `include` cycle: {s}", .{chain.items});
        }
        try l.open.append(l.arena, real);
        defer _ = l.open.pop();
        const dir = try slashed(l.arena, std.fs.path.dirname(real) orelse "/");
        const file = try l.bag.addFile(path, text);
        var t: Tokens = .{ .text = text };
        while (t.next()) |kw| {
            const here: Site = .{ .file = file, .tok = kw };
            if (std.mem.eql(u8, kw.text, "include")) {
                // §13.2.2: "as though the contents of the included map file
                // appear in place of the include command", and a relative
                // path is "relative to the location of the file that contains
                // the file path".
                const spec = t.next() orelse return l.fail(here, "`include` names no file_path_spec", .{});
                if (isPunct(spec.text)) return l.fail(.{ .file = file, .tok = spec }, "`include` names no file_path_spec", .{});
                try l.expectSemicolon(&t, file, spec);
                const next = try std.fs.path.resolveAllocPosix(l.arena, &.{ dir, unquote(spec.text) });
                const site: Site = .{ .file = file, .tok = spec };
                // Every 1024 nested files continue on a fresh stack segment,
                // so nesting is bounded by memory, not the caller's stack.
                if (l.open.items.len % 1024 != 0) try l.read(next, site) else deep_stack.run(1024, read, .{ l, next, site }) catch |e| switch (e) {
                    error.DeepStackUnavailable => return l.fail(here, "no stack left for {d} nested map files", .{l.open.items.len}),
                    else => |other| return other,
                };
            } else if (std.mem.eql(u8, kw.text, "library")) {
                const name = t.next() orelse return l.fail(here, "`library` names no library", .{});
                if (!isIdentifier(name.text)) return l.fail(.{ .file = file, .tok = name }, "`{s}` is not a library_identifier", .{name.text});
                const lib = for (l.libs.items) |*b| {
                    if (std.mem.eql(u8, b.name, name.text)) break b;
                } else blk: {
                    try l.libs.append(l.arena, .{ .name = name.text });
                    break :blk &l.libs.items[l.libs.items.len - 1];
                };
                var prev = name;
                while (true) {
                    const spec = t.next() orelse return l.fail(.{ .file = file, .tok = prev }, "a library declaration ends with `;`", .{});
                    // A.1.1: the `-incdir` list follows at least one file_path_spec.
                    if (isPunct(spec.text) or std.mem.eql(u8, spec.text, "-incdir")) return l.fail(.{ .file = file, .tok = spec }, "`library {s}` needs a file_path_spec here (Syntax 13-2), found `{s}`", .{ name.text, spec.text });
                    try lib.specs.append(l.arena, try resolveSpec(l.arena, dir, unquote(spec.text)));
                    const sep = t.next() orelse return l.fail(.{ .file = file, .tok = spec }, "a library declaration ends with `;`", .{});
                    if (std.mem.eql(u8, sep.text, ";")) break;
                    // A.1.1 `[ -incdir file_path_spec { , file_path_spec } ] ;`
                    if (std.mem.eql(u8, sep.text, "-incdir")) {
                        var prev_tok = sep;
                        while (true) {
                            const d = t.next() orelse return l.fail(.{ .file = file, .tok = prev_tok }, "a library declaration ends with `;`", .{});
                            if (isPunct(d.text)) return l.fail(.{ .file = file, .tok = d }, "`-incdir` needs a file_path_spec here (Syntax 13-2), found `{s}`", .{d.text});
                            try l.incdirs.append(l.arena, try std.fs.path.resolveAllocPosix(l.arena, &.{ dir, unquote(d.text) }));
                            const next = t.next() orelse return l.fail(.{ .file = file, .tok = d }, "a library declaration ends with `;`", .{});
                            if (std.mem.eql(u8, next.text, ";")) break;
                            if (!std.mem.eql(u8, next.text, ",")) return l.fail(.{ .file = file, .tok = next }, "found `{s}`: -incdir file_path_specs are separated by `,` and end with `;`", .{next.text});
                            prev_tok = next;
                        }
                        break;
                    }
                    if (!std.mem.eql(u8, sep.text, ",")) return l.fail(.{ .file = file, .tok = sep }, "found `{s}`: file_path_specs are separated by `,` and end with `;`", .{sep.text});
                    prev = sep;
                }
            } else return l.fail(here, "found `{s}`: a library map holds `library` and `include` statements only (IEEE 1364-2005 §13.2.2)", .{kw.text});
        }
    }

    fn expectSemicolon(l: *Loader, t: *Tokens, file: diag.FileId, after: Token) Error!void {
        const semi = t.next() orelse return l.fail(.{ .file = file, .tok = after }, "an `include` statement ends with `;`", .{});
        if (!std.mem.eql(u8, semi.text, ";")) return l.fail(.{ .file = file, .tok = semi }, "found `{s}`: an `include` statement ends with `;`", .{semi.text});
    }

    fn fail(l: *Loader, at: ?Site, comptime fmt: []const u8, args: anytype) Error {
        const span: diag.Span = if (at) |s| .{ .start = s.tok.start, .end = s.tok.start + @as(u32, @intCast(s.tok.text.len)) } else .none;
        var b = l.bag.build(.parse, .E0244, span);
        if (at) |s| b.inFile(s.file);
        b.msg(fmt, args);
        try b.emit();
        return error.MapFailed;
    }
};

const Site = struct { file: diag.FileId, tok: Token };
const Token = struct { text: []const u8, start: u32 };

/// Words of map text: a quoted string, `,`, `;`, or a run of anything else
/// up to whitespace, `,` or `;`. A comment starts only where a word could, so
/// the `/*` inside `lib/*.v` is part of the path.
const Tokens = struct {
    text: []const u8,
    pos: usize = 0,

    /// The next token, never empty, or null at the end. Asserts that the
    /// cursor is within the text and that a token advanced it.
    fn next(t: *Tokens) ?Token {
        const s = t.text;
        std.debug.assert(t.pos <= s.len);
        while (t.pos < s.len) {
            if (std.ascii.isWhitespace(s[t.pos])) {
                t.pos += 1;
            } else if (std.mem.startsWith(u8, s[t.pos..], "//")) {
                t.pos = std.mem.findScalarPos(u8, s, t.pos, '\n') orelse s.len;
            } else if (std.mem.startsWith(u8, s[t.pos..], "/*")) {
                t.pos = if (std.mem.findPos(u8, s, t.pos + 2, "*/")) |e| e + 2 else s.len;
            } else break;
        }
        if (t.pos == s.len) return null;
        const start = t.pos;
        if (s[t.pos] == '"') {
            t.pos = if (std.mem.findScalarPos(u8, s, t.pos + 1, '"')) |e| e + 1 else s.len;
        } else if (isPunct(s[t.pos .. t.pos + 1])) {
            t.pos += 1;
        } else while (t.pos < s.len and !std.ascii.isWhitespace(s[t.pos]) and s[t.pos] != ',' and s[t.pos] != ';') t.pos += 1;
        // A word starts on a byte that is neither blank nor punctuation, so
        // each arm takes one byte at least.
        std.debug.assert(t.pos > start);
        std.debug.assert(t.pos <= s.len);
        return .{ .text = s[start..t.pos], .start = @intCast(start) };
    }
};

fn isPunct(w: []const u8) bool {
    return std.mem.eql(u8, w, ",") or std.mem.eql(u8, w, ";");
}

fn isIdentifier(w: []const u8) bool {
    if (w.len == 0 or !(std.ascii.isAlphabetic(w[0]) or w[0] == '_')) return false;
    for (w) |c| if (!Preprocessor.isIdentChar(c)) return false;
    return true;
}

fn unquote(w: []const u8) []const u8 {
    return if (w.len >= 2 and w[0] == '"' and w[w.len - 1] == '"') w[1 .. w.len - 1] else w;
}

/// Returns `raw`, a `file_path_spec`, resolved against `dir` (absolute,
/// `/`-separated) and classed for §13.2.1.1. §13.2.1 "Paths that do not
/// begin with / are relative to the directory in which the current lib.map
/// file is located"; "Paths that end in / shall include all files in the
/// specified directory. Identical to /*." The pattern is allocated in
/// `arena`.
fn resolveSpec(arena: std.mem.Allocator, dir: []const u8, raw: []const u8) error{OutOfMemory}!Spec {
    const base = std.fs.path.basenamePosix(raw);
    const class: Class = if (std.mem.endsWith(u8, raw, "/"))
        .directory
    else if (std.mem.findAny(u8, base, "*?") != null or std.mem.eql(u8, base, "..."))
        .wildcard
    else
        .file;
    const path = try std.fs.path.resolveAllocPosix(arena, &.{ dir, raw });
    return .{ .pattern = if (class == .directory) try std.mem.concat(arena, u8, &.{ path, "/*" }) else path, .class = class };
}

/// `path` with the host's separator written `/`, the one §13.2.1 paths use,
/// so a Windows map directory resolves against a spec like a POSIX one.
fn slashed(arena: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const u8 {
    if (std.fs.path.sep == '/') return path;
    const out = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
    return out;
}

/// Reports whether `file` matches `pattern`, both absolute. §13.2.1's
/// wildcards: `?` one character, `*` any run within one name, `...` any
/// number of directories. `pattern` is `/`-separated (`resolveSpec`); `file`
/// is a host path, split on the host's separators. Each name is matched in
/// time linear in the product of its pattern and name lengths.
pub fn matches(pattern: []const u8, file: []const u8) bool {
    var f = file;
    while (f.len != 0 and std.fs.path.isSep(f[0])) f = f[1..];
    return segments(std.mem.trimStart(u8, pattern, "/"), f);
}

fn nextSep(f: []const u8) ?usize {
    for (f, 0..) |c, i| if (std.fs.path.isSep(c)) return i;
    return null;
}

fn segments(p: []const u8, f: []const u8) bool {
    if (p.len == 0) return f.len == 0;
    const p_end = std.mem.findScalar(u8, p, '/') orelse p.len;
    const p_rest = if (p_end == p.len) "" else p[p_end + 1 ..];
    if (std.mem.eql(u8, p[0..p_end], "...")) {
        var rest = f;
        while (true) {
            if (segments(p_rest, rest)) return true;
            const slash = nextSep(rest) orelse return false;
            rest = rest[slash + 1 ..];
        }
    }
    if (f.len == 0) return false;
    const f_end = nextSep(f) orelse f.len;
    return glob(p[0..p_end], f[0..f_end]) and segments(p_rest, if (f_end == f.len) "" else f[f_end + 1 ..]);
}

fn glob(p: []const u8, s: []const u8) bool {
    // Greedy, with one way back: the last `*` and how much of `s` it has
    // taken. A later `*` makes every earlier one's choice final, so a
    // failure only ever grows the last star's run: O(len(p) * len(s)),
    // where trying every split among the stars was exponential in them.
    var pi: usize = 0;
    var si: usize = 0;
    var star: ?usize = null;
    var taken: usize = 0;
    while (si < s.len) {
        if (pi < p.len and p[pi] != '*' and (p[pi] == '?' or p[pi] == s[si])) {
            pi += 1;
            si += 1;
        } else if (pi < p.len and p[pi] == '*') {
            star = pi;
            pi += 1;
            taken = si;
        } else if (star) |at| {
            pi = at + 1;
            taken += 1;
            si = taken;
        } else return false;
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    return pi == p.len;
}

const testing = std.testing;

test "§13.7.2 file path specification examples" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = [_][]const u8{ "/proj/lib1/rtl/a.v", "/proj/lib2/gates/a.v", "/proj/lib1/rtl/b.v", "/proj/lib2/gates/b.v" };
    const cases = [_]struct { dir: []const u8, spec: []const u8, want: [4]bool }{
        .{ .dir = "/proj", .spec = "/proj/lib*/*/a.v", .want = .{ true, true, false, false } },
        .{ .dir = "/proj", .spec = ".../a.v", .want = .{ true, true, false, false } },
        .{ .dir = "/proj", .spec = "/proj/.../b.v", .want = .{ false, false, true, true } },
        .{ .dir = "/proj", .spec = ".../rtl/*.v", .want = .{ true, false, true, false } },
        .{ .dir = "/proj/lib1", .spec = "../lib2/gates/*.v", .want = .{ false, true, false, true } },
        .{ .dir = "/proj/lib1", .spec = "./rtl/?.v", .want = .{ true, false, true, false } },
        .{ .dir = "/proj/lib1", .spec = "./rtl/", .want = .{ true, false, true, false } },
    };
    for (cases) |c| {
        const s = try resolveSpec(a, c.dir, c.spec);
        for (files, c.want) |f, w| try testing.expectEqual(w, matches(s.pattern, f));
    }
    // §13.2.1: "The paths ./*.v and *.v are identical".
    try testing.expectEqualStrings((try resolveSpec(a, "/d", "./*.v")).pattern, (try resolveSpec(a, "/d", "*.v")).pattern);
}

test "§13.7.3 resolving multiple path specifications" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = "/proj/tb";
    const map: Map = .{ .libraries = &.{
        .{ .name = "lib1", .specs = &.{try resolveSpec(a, dir, "/proj/lib1/foo*.v")} },
        .{ .name = "lib2", .specs = &.{try resolveSpec(a, dir, "/proj/lib1/foo.v")} },
        .{ .name = "lib3", .specs = &.{try resolveSpec(a, dir, "../lib1/")} },
        .{ .name = "lib4", .specs = &.{try resolveSpec(a, dir, "/proj/lib1/*ver.v")} },
    } };
    try testing.expectEqualStrings("lib1", map.libraryOf("/proj/lib1/foobar.v").lib);
    try testing.expectEqualStrings("lib2", map.libraryOf("/proj/lib1/foo.v").lib);
    try testing.expectEqualStrings("lib3", map.libraryOf("/proj/lib1/bar.v").lib);
    try testing.expectEqualStrings("lib4", map.libraryOf("/proj/lib1/barver.v").lib);
    const tie = map.libraryOf("/proj/lib1/foover.v").ambiguous;
    try testing.expectEqualStrings("lib1", tie[0]);
    try testing.expectEqualStrings("lib4", tie[1]);
    // §13.2.1: "Any file ... that does not match any library's
    // file_path_spec shall by default be compiled into a library named work."
    try testing.expectEqualStrings("work", map.libraryOf("/proj/tb/top.v").lib);
    // A directory specification is not recursive.
    try testing.expectEqualStrings("work", map.libraryOf("/proj/lib1/sub/bar.v").lib);
}

test "Tokens: words, quoted strings, `,` and `;`, and comments only where a word could start" {
    var t: Tokens = .{ .text = "library lib1 \"a b.v\",lib/*.v; // tail\n/* block */ include x;" };
    for ([_][]const u8{ "library", "lib1", "\"a b.v\"", ",", "lib/*.v", ";", "include", "x", ";" }) |w|
        try testing.expectEqualStrings(w, t.next().?.text);
    try testing.expect(t.next() == null);
    // An unterminated string or comment runs to the end of the text.
    var q: Tokens = .{ .text = "\"open" };
    try testing.expectEqualStrings("\"open", q.next().?.text);
    try testing.expect(q.next() == null);
    var c: Tokens = .{ .text = "a /* open" };
    try testing.expectEqualStrings("a", c.next().?.text);
    try testing.expect(c.next() == null);
    // `start` is the byte the diagnostic points at.
    var s: Tokens = .{ .text = "  ab ;" };
    try testing.expectEqual(@as(u32, 2), s.next().?.start);
    try testing.expectEqual(@as(u32, 5), s.next().?.start);
}

test "isIdentifier is a simple identifier; unquote strips one pair of quotes" {
    for ([_][]const u8{ "lib1", "_a$", "A_b9" }) |w| try testing.expect(isIdentifier(w));
    for ([_][]const u8{ "", "1a", "$a", "a-b", "\"a\"" }) |w| try testing.expect(!isIdentifier(w));
    try testing.expectEqualStrings("a b", unquote("\"a b\""));
    try testing.expectEqualStrings("\"a", unquote("\"a"));
    try testing.expectEqualStrings("", unquote("\"\""));
    try testing.expectEqualStrings("a", unquote("a"));
}

test "resolveSpec classes a specification by its last name and resolves it against the map's directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, []const u8, Class };
    for ([_]Case{
        .{ "a.v", "/m/a.v", .file },
        .{ "rtl/*.v", "/m/rtl/*.v", .wildcard },
        .{ "a?.v", "/m/a?.v", .wildcard },
        // §13.2.1.1 classes by the file name: `...` in a directory does not
        // make an explicit file name a wildcard.
        .{ ".../a.v", "/m/.../a.v", .file },
        .{ "rtl/...", "/m/rtl/...", .wildcard },
        .{ "rtl/", "/m/rtl/*", .directory },
        .{ "/abs/x.v", "/abs/x.v", .file },
        .{ "../up/x.v", "/up/x.v", .file },
    }) |c| {
        const s = try resolveSpec(a, "/m", c[0]);
        try testing.expectEqualStrings(c[1], s.pattern);
        try testing.expectEqual(c[2], s.class);
    }
}

test "matches: `?` is one character, `*` stays inside one name, `...` spans any number of directories" {
    const Case = struct { []const u8, []const u8, bool };
    for ([_]Case{
        .{ "/p/a?.v", "/p/ab.v", true },
        .{ "/p/a?.v", "/p/a.v", false },
        .{ "/p/a?.v", "/p/abc.v", false },
        .{ "/p/*.v", "/p/x/y.v", false },
        .{ "/p/*.v", "/p/.v", true },
        .{ "/p/*", "/p/x", true },
        .{ "/p/.../x.v", "/p/x.v", true },
        .{ "/p/.../x.v", "/p/a/b/c/x.v", true },
        .{ "/p/.../x.v", "/q/x.v", false },
        // `...` names directories: a pattern ending in it holds no file.
        .{ "/p/...", "/p/x.v", false },
        .{ "/p/a.v", "/p/a.v", true },
        .{ "/p/a.v", "/p", false },
    }) |c| try testing.expectEqual(c[2], matches(c[0], c[1]));
}

/// Independent oracle for `glob`: the textbook dynamic program, `dp[i][j]`
/// true when the first `i` pattern characters match the first `j` of `s`.
fn testGlobOracle(p: []const u8, s: []const u8) bool {
    var dp: [8][8]bool = @splat(@splat(false));
    dp[0][0] = true;
    for (1..p.len + 1) |i| {
        dp[i][0] = p[i - 1] == '*' and dp[i - 1][0];
        for (1..s.len + 1) |j| {
            if (p[i - 1] == '*') {
                dp[i][j] = dp[i - 1][j] or dp[i][j - 1];
            } else {
                dp[i][j] = dp[i - 1][j - 1] and (p[i - 1] == '?' or p[i - 1] == s[j - 1]);
            }
        }
    }
    return dp[p.len][s.len];
}

test "glob agrees with a dynamic-programming oracle on every short pattern and name" {
    // Exhaustive: patterns of up to 4 characters over `a b * ?` against
    // names of up to 5 over `a b`.
    const alphabet = "ab*?";
    var pbuf: [4]u8 = undefined;
    var sbuf: [5]u8 = undefined;
    for (0..5) |plen| {
        for (0..std.math.pow(usize, 4, plen)) |pi| {
            var x = pi;
            for (pbuf[0..plen]) |*ch| {
                ch.* = alphabet[x % 4];
                x /= 4;
            }
            for (0..6) |slen| {
                for (0..@as(usize, 1) << @intCast(slen)) |si| {
                    for (sbuf[0..slen], 0..) |*ch, k| ch.* = if ((si >> @intCast(k)) & 1 == 0) 'a' else 'b';
                    try testing.expectEqual(testGlobOracle(pbuf[0..plen], sbuf[0..slen]), glob(pbuf[0..plen], sbuf[0..slen]));
                }
            }
        }
    }
}

test "glob stays fast on a pattern of many stars against a long name" {
    // A matcher that backtracks over every split of the name among the stars
    // tries about C(60, 14) of them here before answering.
    const pattern = "*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b";
    var name: [60]u8 = @splat('a');
    try testing.expect(!glob(pattern, &name));
    name[59] = 'b';
    try testing.expect(glob(pattern, &name));
}

test "libraryOf: a better class ends a tie, and a tie names the first two libraries" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const map: Map = .{ .libraries = &.{
        .{ .name = "w1", .specs = &.{try resolveSpec(a, "/p", "*.v")} },
        .{ .name = "w2", .specs = &.{try resolveSpec(a, "/p", "?.v")} },
        .{ .name = "w3", .specs = &.{try resolveSpec(a, "/p", "x*")} },
        .{ .name = "d", .specs = &.{try resolveSpec(a, "/p", "./")} },
        .{ .name = "f", .specs = &.{ try resolveSpec(a, "/p", "y.v"), try resolveSpec(a, "/p", "*.v") } },
    } };
    // x.v: three libraries tie on a wildcard (the directory is less specific).
    const tie = map.libraryOf("/p/x.v").ambiguous;
    try testing.expectEqualStrings("w1", tie[0]);
    try testing.expectEqualStrings("w2", tie[1]);
    // y.v: `f`'s explicit file name beats the wildcards that tied before it.
    try testing.expectEqualStrings("f", map.libraryOf("/p/y.v").lib);
    // z.txt: only the directory specification matches.
    try testing.expectEqualStrings("d", map.libraryOf("/p/z.txt").lib);
}

test "§13.5.1 order is declaration order, with `work` last unless a map declares it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { Map, []const []const u8 };
    for ([_]Case{
        .{ .{}, &.{"work"} },
        .{ .{ .libraries = &.{ .{ .name = "b", .specs = &.{} }, .{ .name = "a", .specs = &.{} } } }, &.{ "b", "a", "work" } },
        .{ .{ .libraries = &.{ .{ .name = "x", .specs = &.{} }, .{ .name = "work", .specs = &.{} } } }, &.{ "x", "work" } },
    }) |c| {
        const got = try c[0].order(a);
        try testing.expectEqual(c[1].len, got.len);
        for (c[1], got) |want, name| try testing.expectEqualStrings(want, name);
    }
    const map: Map = .{ .libraries = &.{ .{ .name = "x", .specs = &.{} }, .{ .name = "y", .specs = &.{} } } };
    try testing.expectEqual(@as(?usize, 1), map.declares("y"));
    try testing.expectEqual(@as(?usize, null), map.declares("work"));
}

const test_map =
    \\// §13.2.1: a library declaration, then an include.
    \\library rtl rtl/*.v, "q/x.v" -incdir inc, "inc 2";
    \\include sub/more.map;
    \\
;

test "§13.2.2 load reads library and include statements, and a library declared twice holds both" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.map", .data = test_map });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/more.map", .data = "library rtl gates/;\nlibrary gl *.vg;\n" });
    const path: []const u8 = try tmp.dir.realPathFileAlloc(io, "lib.map", a);
    var bag: diag.Bag = .init(a);
    const map = try load(a, io, &bag, &.{path});
    try testing.expectEqual(@as(usize, 0), bag.count());
    try testing.expectEqual(@as(usize, 2), map.libraries.len);
    const rtl = map.libraries[0];
    try testing.expectEqualStrings("rtl", rtl.name);
    try testing.expectEqual(@as(usize, 3), rtl.specs.len);
    try testing.expect(std.mem.endsWith(u8, rtl.specs[0].pattern, "/rtl/*.v") and rtl.specs[0].class == .wildcard);
    try testing.expect(std.mem.endsWith(u8, rtl.specs[1].pattern, "/q/x.v") and rtl.specs[1].class == .file);
    // An included map's relative paths are relative to that map.
    try testing.expect(std.mem.endsWith(u8, rtl.specs[2].pattern, "/sub/gates/*") and rtl.specs[2].class == .directory);
    try testing.expectEqualStrings("gl", map.libraries[1].name);
    try testing.expectEqual(@as(usize, 2), map.incdirs.len);
    try testing.expect(std.mem.endsWith(u8, map.incdirs[0], "/inc"));
    try testing.expect(std.mem.endsWith(u8, map.incdirs[1], "/inc 2"));
}

test "§13.2.2 include nesting has no depth bound: a chain of 40 map files, past the old 32" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const n = 40;
    for (0..n) |k| {
        const data = if (k + 1 == n) try a.print("library deep{d} x.v;\n", .{k}) else try a.print("include m{d}.map;\n", .{k + 1});
        try tmp.dir.writeFile(io, .{ .sub_path = try a.print("m{d}.map", .{k}), .data = data });
    }
    var bag: diag.Bag = .init(a);
    const map = try load(a, io, &bag, &.{try tmp.dir.realPathFileAlloc(io, "m0.map", a)});
    try testing.expectEqual(@as(usize, 0), bag.count());
    try testing.expectEqualStrings("deep39", map.libraries[0].name);
}

/// Loads `text` as `bad.map` in `tmp`, requires one E0244 refusal, and
/// returns its message (allocated in `a`).
fn testLoadRefusal(a: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, text: []const u8) ![]const u8 {
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = text });
    const path: []const u8 = try tmp.dir.realPathFileAlloc(io, name, a);
    var bag: diag.Bag = .init(a);
    try testing.expectError(error.MapFailed, load(a, io, &bag, &.{path}));
    try testing.expectEqual(@as(usize, 1), bag.count());
    try testing.expectEqual(diag.Code.E0244, bag.at(0).code);
    return bag.at(0).message;
}

test "§13.2.2 Syntax 13-2: every malformed statement is E0244 naming what it found" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "config c;", "a library map holds `library` and `include` statements only" },
        .{ "library 1x a.v;", "`1x` is not a library_identifier" },
        .{ "library", "`library` names no library" },
        .{ "library lib a.v", "a library declaration ends with `;`" },
        .{ "library lib ;", "needs a file_path_spec here (Syntax 13-2), found `;`" },
        .{ "library lib a.v b.v;", "found `b.v`: file_path_specs are separated by `,`" },
        // A.1.1: the `-incdir` list follows at least one file_path_spec.
        .{ "library lib -incdir x;", "needs a file_path_spec here (Syntax 13-2), found `-incdir`" },
        .{ "library lib a.v, -incdir x;", "needs a file_path_spec here (Syntax 13-2), found `-incdir`" },
        .{ "library lib a.v -incdir ;", "`-incdir` needs a file_path_spec here" },
        .{ "library lib a.v -incdir x y;", "found `y`: -incdir file_path_specs are separated by `,`" },
        .{ "library lib a.v -incdir x", "a library declaration ends with `;`" },
        .{ "include ;", "`include` names no file_path_spec" },
        .{ "include", "`include` names no file_path_spec" },
        .{ "include x.map", "an `include` statement ends with `;`" },
        .{ "include x.map y;", "found `y`: an `include` statement ends with `;`" },
        .{ "include missing.map;", "cannot read library map" },
        // A map that includes itself would never end: a named cycle.
        .{ "include bad.map;", "library map `include` cycle:" },
    }) |c| {
        const msg = try testLoadRefusal(a, &tmp, "bad.map", c[0]);
        if (std.mem.find(u8, msg, c[1]) == null) {
            std.debug.print("`{s}`: got \"{s}\", want \"{s}\"\n", .{ c[0], msg, c[1] });
            return error.TestUnexpectedResult;
        }
    }
    // A top-level map that cannot be read has no file to point into.
    var bag: diag.Bag = .init(a);
    try testing.expectError(error.MapFailed, load(a, testing.io, &bag, &.{"/nonexistent-vera-dir/x.map"}));
    try testing.expectEqual(@as(usize, 1), bag.count());
    try testing.expect(std.mem.find(u8, bag.at(0).message, "cannot read library map") != null);
}
