//! `setup`'s emitted text -> the same statements as `zSetup<k>` chunks over
//! a scratch struct, which a split build compiles as objects of their own,
//! in parallel (`orchestrator.Part`). A text transform after emission, like
//! `setup.zig`'s own patches: the relooper's output has a fixed shape (one
//! statement per line, labelled blocks `B<n>: {` left by `break :B<n>`, and
//! two-armed `if`s), and only that shape is split; anything else stays one
//! piece. Every statement still runs once, in order, on the same values, so
//! every root keeps its bits.
//! LRM: none (build orchestration).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Error = Allocator.Error;

/// Emitted `setup` (doc comment and function) from which `emitSetup` splits
/// it, into one chunk per this many bytes. Measured 2026-10-01
/// (`git show 6e59b3d4^:docs/measurements/codegen-levers-2026-10-01.md`): psp103's setup (850
/// KB) was its split build's longest object; bsim4va's (457 KB) too.
pub const chunk_bytes: usize = 256 * 1024;

/// `setup` rewritten as chunks: `text` replaces the doc comment and function.
const Chunked = struct { text: []const u8, n: u32 };

const Lines = []const []const u8;

/// One unit the chunks are cut between: `lines` (indent 0) run only when
/// every guard holds (`zg<k>` or `!zg<k>`).
const Piece = struct {
    guards: Lines,
    lines: Lines,
    chunk: u32 = 0,
    /// The name and type (empty: a real, `zOf(S, 0x0)`; nothing `setup`
    /// computes carries a lane) a `const`/`var` piece declares, and where
    /// its value starts in `lines[0]`.
    name: []const u8 = "",
    ty: []const u8 = "",
    head: usize = 0,
};

/// `pieces`' output and the threshold it cuts at.
const State = struct {
    a: Allocator,
    pieces: std.ArrayList(Piece) = .empty,
    guards: u32 = 0,
    /// A statement no larger than this is one piece.
    small: usize,
};

/// Splits `setup` (`text`: its doc comment and function as `emitSetup`
/// writes them) into about `text.len / target` chunks. The body's
/// statements are cut into pieces: a labelled block whose every `break` is
/// in tail position is opened, and a two-armed `if` whose arms jump nowhere
/// outside themselves becomes its condition, stored once (`zg<k>`), and the
/// arms' statements each guarded by it. A value one piece declares and
/// another reads, a guard, and every hoisted slot array, move into a scratch
/// struct (`zSetupZ`) that `setup` owns and passes to every chunk. Then
/// `setup_chunks`, through which a split build exports each chunk from its
/// own object, and `setup`, which calls the chunks in order through those
/// objects' hidden symbols when the build's root declares
/// `vera_setup_split = true`, and otherwise calls them directly: the body
/// is emitted once, as the chunks. Null keeps the one function: a `zs_stop` or
/// `zs_done` body, fewer than two chunks, or no balanced cut.
/// `Chunked.text` is allocated in `a` (copied, so `text` may go first).
pub fn chunk(a: Allocator, text: []const u8, target: usize) Error!?Chunked {
    if (std.mem.find(u8, text, "zs_stop") != null or std.mem.find(u8, text, "zs_done") != null) return null;
    const fn_at = std.mem.find(u8, text, "pub fn setup(") orelse return null;
    if (!std.mem.endsWith(u8, text, "\n}\n\n")) return null;
    const head_end = (std.mem.findScalarPos(u8, text, fn_at, '\n') orelse return null) + 1;

    // One line per '\n' plus the last, so the table is sized before the split.
    const src = text[head_end .. text.len - 3];
    const all = try a.alloc([]const u8, std.mem.countScalar(u8, src, '\n') + 1);
    var it = std.mem.splitScalar(u8, src, '\n');
    for (all) |*l| l.* = dedent(it.next().?, 4);
    std.debug.assert(it.next() == null);
    var body: Lines = all;

    // The prologue: the float mode, the scalar alias and the hoisted arrays.
    var fields: std.ArrayList(Piece) = .empty;
    while (body.len != 0) : (body = body[1..]) {
        const l = body[0];
        if (std.mem.eql(u8, l, "@setFloatMode(.strict);") or std.mem.eql(u8, l, "const S = V;") or std.mem.eql(u8, l, "_ = V;")) {} else if (std.mem.startsWith(u8, l, "var ") and std.mem.endsWith(u8, l, " = undefined;")) {
            var p: Piece = .{ .guards = &.{}, .lines = body[0..1] };
            declOf(&p);
            if (p.ty.len == 0) return null;
            try fields.append(a, p);
        } else break;
    }
    var total: usize = 0;
    for (body) |l| total += l.len + 1;
    const n: u32 = @intCast(@min(64, (total + target - 1) / target));
    if (n < 2) return null;

    var st: State = .{ .a = a, .small = total / (4 * n) };
    if (!try pieces(&st, body, &.{})) return null;
    const ps = st.pieces.items;
    // A `return` leaves only its own chunk: allowed in the last piece alone.
    var last = ps.len;
    while (last > 0 and bytesOf(ps[last - 1].lines) == ps[last - 1].lines.len) last -= 1;
    for (ps[0..last -| 1]) |p| for (p.lines) |l| if (std.mem.find(u8, l, "return;") != null) return null;

    var acc: usize = 0;
    const sizes = try a.alloc(usize, n);
    @memset(sizes, 0);
    for (ps) |*p| {
        p.chunk = @intCast(@min(n - 1, acc * n / total));
        acc += bytesOf(p.lines);
        sizes[p.chunk] += bytesOf(p.lines);
        declOf(p);
    }
    // A cut no better than three quarters in one chunk is not worth a split.
    if (std.mem.max(usize, sizes) * 4 > total * 3) return null;

    // Which pieces read each name.
    var readers: std.StringHashMapUnmanaged(u32) = .empty;
    var several: std.StringHashMapUnmanaged(void) = .empty;
    for (ps, 0..) |p, k| {
        for (p.lines, 0..) |l, i| {
            var ids: Idents = .{ .text = if (i == 0) l[p.head..] else l };
            while (ids.next()) |id| try note(a, &readers, &several, id, @intCast(k));
        }
        for (p.guards) |g| try note(a, &readers, &several, std.mem.trimStart(u8, g, "!"), @intCast(k));
    }
    var moved: std.StringHashMapUnmanaged(void) = .empty;
    for (fields.items) |f| try moved.put(a, f.name, {});
    for (ps, 0..) |p, k| {
        if (p.name.len == 0) continue;
        const r = readers.get(p.name) orelse continue;
        if (r == k and !several.contains(p.name)) continue;
        if (p.ty.len == 0 and std.mem.startsWith(u8, p.lines[0], "var ")) return null;
        try fields.append(a, p);
        try moved.put(a, p.name, {});
    }

    var out: std.ArrayList(u8) = .empty;
    const z_s = for (fields.items) |f| {
        if (f.ty.len == 0 or hasWord(f.ty, "S")) break true;
    } else false;
    try out.print(a,
        \\/// `setup`'s hoisted slots and the values that cross between its
        \\/// chunks: `setup` owns one and passes it to every chunk.
        \\fn zSetupZ(comptime {s}: type) type {{
        \\    return struct {{
        \\
    , .{if (z_s) "S" else "_"});
    for (fields.items) |f| try out.print(a, "        {s}: {s} = undefined,\n", .{ f.name, if (f.ty.len == 0) "zOf(S, 0x0)" else f.ty });
    try out.appendSlice(a, "    };\n}\n\n");

    var b: std.ArrayList(u8) = .empty;
    for (0..n) |k| {
        b.clearRetainingCapacity();
        for (ps) |p| {
            if (p.chunk != k) continue;
            var depth: usize = 1;
            if (p.guards.len != 0) {
                try b.appendSlice(a, "    if (");
                for (p.guards, 0..) |g, i| {
                    if (i != 0) try b.appendSlice(a, " and ");
                    if (g[0] == '!') try b.append(a, '!');
                    try rename(a, &b, std.mem.trimStart(u8, g, "!"), &moved);
                }
                try b.appendSlice(a, ") {\n");
                depth = 2;
            }
            for (p.lines, 0..) |l, i| {
                if (l.len != 0) try b.appendNTimes(a, ' ', 4 * depth);
                if (i == 0 and p.name.len != 0 and moved.contains(p.name)) {
                    try b.print(a, "z.{s} = ", .{p.name});
                    try rename(a, &b, l[p.head..], &moved);
                } else try rename(a, &b, l, &moved);
                try b.append(a, '\n');
            }
            if (p.guards.len != 0) try b.appendSlice(a, "    }\n");
        }
        const t = b.items;
        try out.print(a, "fn zSetup{d}(comptime V: type, {s}: *Model, {s}: *zSetupZ(V)) void {{\n    @setFloatMode(.strict);\n", .{
            k,
            if (hasWord(t, "model")) "model" else "_",
            if (std.mem.find(u8, t, "z.") != null) "z" else "_",
        });
        if (hasWord(t, "S")) try out.appendSlice(a, "    const S = V;\n");
        try out.appendSlice(a, t);
        try out.appendSlice(a, "}\n\n");
    }

    try out.print(a,
        \\/// `setup` as {0d} chunks, called in order. A split build exports chunk
        \\/// `k` from its own object for the host's value scalar `V`.
        \\pub const setup_chunks = struct {{
        \\    pub const n: usize = {0d};
        \\    pub fn exportChunk(comptime V: type, comptime k: usize) void {{
        \\        @export(&struct {{
        \\            fn f(model: *Model, z: *anyopaque) callconv(.c) void {{
        \\                at(V, k, model, @ptrCast(@alignCast(z)));
        \\            }}
        \\        }}.f, .{{ .name = sym(V, k), .visibility = .hidden }});
        \\    }}
        \\    fn sym(comptime V: type, comptime k: usize) []const u8 {{
        \\        return std.fmt.comptimePrint("vera_setup_{{d}}_{{x}}", .{{ k, std.hash.Wyhash.hash(0, @typeName(V)) }});
        \\    }}
        \\    fn split() bool {{
        \\        const root = @import("root");
        \\        return @hasDecl(root, "vera_setup_split") and root.vera_setup_split;
        \\    }}
        \\    inline fn at(comptime V: type, comptime k: usize, model: *Model, z: *zSetupZ(V)) void {{
        \\        switch (k) {{
        \\
    , .{n});
    for (0..n) |k| try out.print(a, "            {d} => zSetup{d}(V, model, z),\n", .{ k, k });
    try out.appendSlice(a,
        \\            else => comptime unreachable,
        \\        }
        \\    }
        \\};
        \\
        \\
    );
    // `setup` only calls the chunks: its body is emitted once, as them.
    try out.appendSlice(a, text[0..fn_at]);
    try out.appendSlice(a,
        \\pub fn setup(comptime V: type, model: *Model) void {
        \\    var z: zSetupZ(V) = .{};
        \\    inline for (0..setup_chunks.n) |k| {
        \\        if (comptime setup_chunks.split())
        \\            @extern(*const fn (*Model, *anyopaque) callconv(.c) void, .{ .name = setup_chunks.sym(V, k), .visibility = .hidden })(model, &z)
        \\        else
        \\            setup_chunks.at(V, k, model, &z);
        \\    }
        \\}
        \\
        \\
    );
    return .{ .text = out.items, .n = n };
}

fn note(a: Allocator, readers: *std.StringHashMapUnmanaged(u32), several: *std.StringHashMapUnmanaged(void), id: []const u8, k: u32) Error!void {
    const g = try readers.getOrPut(a, id);
    if (!g.found_existing) {
        g.value_ptr.* = k;
    } else if (g.value_ptr.* != k) try several.put(a, id, {});
}

/// Appends the pieces of statement list `body` (indent 0) under `guards`.
/// False when a statement cannot be read (unbalanced braces).
fn pieces(st: *State, body: Lines, guards: Lines) Error!bool {
    var i: usize = 0;
    while (i < body.len) {
        const end = stmtEnd(body, i) orelse return false;
        const s = body[i..end];
        i = end;
        if (bytesOf(s) > st.small) {
            if (try openBlock(st.a, s)) |inner| {
                if (!try pieces(st, inner, guards)) return false;
                continue;
            }
            const arms = try splitIf(st.a, s);
            if (arms != null and try selfContained(st.a, arms.?.then) and try selfContained(st.a, arms.?.@"else")) {
                const arms_ = arms.?;
                st.guards += 1;
                const g = try st.a.print("zg{d}", .{st.guards});
                const decl = try st.a.print("const {s}: bool = {s};", .{ g, arms_.cond });
                try st.pieces.append(st.a, .{ .guards = guards, .lines = try st.a.dupe([]const u8, &.{decl}) });
                if (!try pieces(st, arms_.then, try cat(st.a, guards, g))) return false;
                if (arms_.@"else".len != 0 and !try pieces(st, arms_.@"else", try cat(st.a, guards, try st.a.print("!{s}", .{g})))) return false;
                continue;
            }
        }
        try st.pieces.append(st.a, .{ .guards = guards, .lines = s });
    }
    return true;
}

fn cat(a: Allocator, xs: Lines, x: []const u8) Error!Lines {
    const r = try a.alloc([]const u8, xs.len + 1);
    @memcpy(r[0..xs.len], xs);
    r[xs.len] = x;
    return r;
}

fn bytesOf(ls: Lines) usize {
    var n: usize = 0;
    for (ls) |l| n += l.len + 1;
    return n;
}

/// The end of the statement starting at `body[i]`: the line after its
/// braces balance.
fn stmtEnd(body: Lines, i: usize) ?usize {
    var d: i64 = 0;
    for (body[i..], i..) |l, j| {
        d += braceDelta(l);
        if (d == 0) return j + 1;
        if (d < 0) return null;
    }
    return null;
}

/// `B: { ... }` whose every `break :B` is in tail position: its statements,
/// those breaks removed (each falls through to the block's end). Else null.
fn openBlock(a: Allocator, s: Lines) Error!?Lines {
    const first = s[0];
    if (!std.mem.endsWith(u8, first, ": {") or !std.mem.eql(u8, s[s.len - 1], "}")) return null;
    const label = first[0 .. first.len - 3];
    for (label) |c| if (!isIdent(c)) return null;
    const inner = try dedentAll(a, s[1 .. s.len - 1]);
    const br = try a.print("break :{s};", .{label});
    const stripped = try stripTail(a, inner, br) orelse return null;
    for (stripped) |l| if (std.mem.find(u8, l, br) != null) return null;
    return stripped;
}

/// `body` without the `br` in its tail position: its last statement, or the
/// last statement of either arm of a last `if`. Null when the tail is
/// neither.
fn stripTail(a: Allocator, body: Lines, br: []const u8) Error!?Lines {
    if (body.len == 0) return body;
    var last: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        last = i;
        i = stmtEnd(body, i) orelse return null;
    }
    const s = body[last..];
    if (s.len == 1 and std.mem.eql(u8, s[0], br)) return body[0..last];
    const arms = try splitIf(a, s) orelse return body;
    const t = try stripTail(a, arms.then, br) orelse return null;
    const e = try stripTail(a, arms.@"else", br) orelse return null;
    const has_else = arms.@"else".len != 0 or arms.has_else;
    var out: std.ArrayList([]const u8) = try .initCapacity(a, last + t.len + 2 + if (has_else) e.len + 1 else 0);
    out.appendSliceAssumeCapacity(body[0..last]);
    out.appendAssumeCapacity(try a.print("if ({s}) {{", .{arms.cond}));
    for (t) |l| out.appendAssumeCapacity(try indent(a, l));
    if (has_else) {
        out.appendAssumeCapacity("} else {");
        for (e) |l| out.appendAssumeCapacity(try indent(a, l));
    }
    out.appendAssumeCapacity("}");
    std.debug.assert(out.items.len == out.capacity);
    return out.items;
}

const Arms = struct { cond: []const u8, then: Lines, @"else": Lines, has_else: bool };

/// `if (C) {` A [`} else {` E] `}` as its parts, the arms at indent 0; null
/// for any other statement, an `else if` chain included.
fn splitIf(a: Allocator, s: Lines) Error!?Arms {
    const first = s[0];
    if (!std.mem.startsWith(u8, first, "if (") or !std.mem.endsWith(u8, first, ") {")) return null;
    if (!std.mem.eql(u8, s[s.len - 1], "}")) return null;
    const cond = first[4 .. first.len - 3];
    var d: i64 = 0;
    for (s[1 .. s.len - 1], 1..) |l, i| {
        if (d == 0 and std.mem.startsWith(u8, l, "}")) {
            if (!std.mem.eql(u8, l, "} else {")) return null;
            return .{ .cond = cond, .then = try dedentAll(a, s[1..i]), .@"else" = try dedentAll(a, s[i + 1 .. s.len - 1]), .has_else = true };
        }
        d += braceDelta(l);
    }
    return .{ .cond = cond, .then = try dedentAll(a, s[1 .. s.len - 1]), .@"else" = &.{}, .has_else = false };
}

/// Whether `lines` jump only to labels they define and never return.
fn selfContained(a: Allocator, lines: Lines) Error!bool {
    var defs: std.StringHashMapUnmanaged(void) = .empty;
    defer defs.deinit(a);
    for (lines) |l| {
        const t = std.mem.trimStart(u8, l, " ");
        var e: usize = 0;
        while (e < t.len and isIdent(t[e])) e += 1;
        if (e != 0 and std.mem.startsWith(u8, t[e..], ": ")) try defs.put(a, t[0..e], {});
    }
    for (lines) |l| {
        if (std.mem.find(u8, l, "return;") != null) return false;
        for ([_][]const u8{ "break :", "continue :" }) |kw| {
            var at: usize = 0;
            while (std.mem.findPos(u8, l, at, kw)) |p| {
                at = p + kw.len;
                var e = at;
                while (e < l.len and isIdent(l[e])) e += 1;
                if (!defs.contains(l[at..e])) return false;
            }
        }
    }
    return true;
}

/// The name, type and value start of a `const`/`var` piece.
fn declOf(p: *Piece) void {
    const l = p.lines[0];
    const kw = if (std.mem.startsWith(u8, l, "const ")) "const " else if (std.mem.startsWith(u8, l, "var ")) "var " else return;
    var i = kw.len;
    while (i < l.len and isIdent(l[i])) i += 1;
    if (i == kw.len) return;
    const eq = std.mem.findPos(u8, l, i, " = ") orelse return;
    p.ty = if (l[i] == ':') std.mem.trim(u8, l[i + 1 .. eq], " ") else if (eq == i) "" else return;
    p.name = l[kw.len..i];
    p.head = eq + 3;
}

fn dedent(l: []const u8, k: usize) []const u8 {
    var i: usize = 0;
    while (i < k and i < l.len and l[i] == ' ') i += 1;
    return l[i..];
}

fn dedentAll(a: Allocator, ls: Lines) Error!Lines {
    const r = try a.alloc([]const u8, ls.len);
    for (r, ls) |*o, l| o.* = dedent(l, 4);
    return r;
}

fn indent(a: Allocator, l: []const u8) Error![]const u8 {
    return if (l.len == 0) l else a.print("    {s}", .{l});
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `{` minus `}` on a line, outside string and character literals and comments.
fn braceDelta(line: []const u8) i64 {
    var d: i64 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) switch (line[i]) {
        '"', '\'' => i = skipLit(line, i),
        '/' => if (i + 1 < line.len and line[i + 1] == '/') return d,
        '{' => d += 1,
        '}' => d -= 1,
        else => {}, // else: only braces, literals and comments move the depth
    };
    return d;
}

/// The index of the quote closing the literal opened at `i`.
fn skipLit(t: []const u8, i: usize) usize {
    var j = i + 1;
    while (j < t.len and t[j] != t[i]) : (j += 1) {
        if (t[j] == '\\') j += 1;
    }
    return j;
}

/// The identifiers of Zig text, outside literals and comments, that are not
/// a field or builtin name (`.x`, `@x`).
const Idents = struct {
    text: []const u8,
    i: usize = 0,

    fn next(it: *Idents) ?[]const u8 {
        const t = it.text;
        while (it.i < t.len) {
            const c = t[it.i];
            if (c == '"' or c == '\'') {
                it.i = skipLit(t, it.i) + 1;
            } else if (c == '/' and it.i + 1 < t.len and t[it.i + 1] == '/') {
                it.i = std.mem.findScalarPos(u8, t, it.i, '\n') orelse t.len;
            } else if (isIdent(c)) {
                const s = it.i;
                while (it.i < t.len and isIdent(t[it.i])) it.i += 1;
                // A field follows ONE dot; after `..` the name is a range bound.
                const field = s > 0 and t[s - 1] == '.' and !(s > 1 and t[s - 2] == '.');
                if (std.ascii.isDigit(c) or field or (s > 0 and t[s - 1] == '@')) continue;
                return t[s..it.i];
            } else it.i += 1;
        }
        return null;
    }
};

/// Appends `text` with every identifier in `moved` read as `z.<name>`.
fn rename(a: Allocator, out: *std.ArrayList(u8), text: []const u8, moved: *const std.StringHashMapUnmanaged(void)) Error!void {
    var it: Idents = .{ .text = text };
    var done: usize = 0;
    while (it.next()) |id| {
        if (!moved.contains(id)) continue;
        const at = @intFromPtr(id.ptr) - @intFromPtr(text.ptr);
        try out.appendSlice(a, text[done..at]);
        try out.print(a, "z.{s}", .{id});
        done = at + id.len;
    }
    try out.appendSlice(a, text[done..]);
}

/// Whether `text` uses `word` as an identifier.
pub fn hasWord(text: []const u8, word: []const u8) bool {
    var it: Idents = .{ .text = text };
    while (it.next()) |id| if (std.mem.eql(u8, id, word)) return true;
    return false;
}

test "chunk opens tail-break blocks, guards if arms, and moves shared values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\/// doc
        \\pub fn setup(comptime V: type, model: *Model) void {
        \\    @setFloatMode(.strict);
        \\    const S = V;
        \\    var h0: [2]zOf(S, 0x0) = undefined;
        \\    const t1 = S.con(model.a);
        \\    const t2: i64 = 3;
        \\    B1: {
        \\        if (t2 != 0) {
        \\            const t3 = t1.mul(t1);
        \\            h0[0] = t3.addC(1.0);
        \\            break :B1;
        \\        } else {
        \\            h0[0] = S.con(0.0);
        \\            break :B1;
        \\        }
        \\    }
        \\    model.su.r[0] = (h0[0]).val();
        \\    return;
        \\}
        \\
        \\
    ;
    const c = (try chunk(a, text, 120)).?;
    try std.testing.expect(c.n >= 2);
    for ([_][]const u8{
        "h0: [2]zOf(S, 0x0) = undefined,",
        "z.zg1 = z.t2 != 0;",
        "    if (z.zg1) {\n",
        "    if (!z.zg1) {\n",
        "z.h0[0] = S.con(0.0);",
        "model.su.r[0] = (z.h0[0]).val();",
        "/// doc\npub fn setup(",
    }) |want| if (std.mem.find(u8, c.text, want) == null) {
        std.debug.print("missing `{s}` in:\n{s}\n", .{ want, c.text });
        return error.TestUnexpectedResult;
    };
    // The chunks lost the tail breaks, and no copy of the body is kept.
    try std.testing.expect(std.mem.find(u8, c.text, "break :B1") == null);
    try std.testing.expect(std.mem.find(u8, c.text, ".mul(").? == std.mem.findLast(u8, c.text, ".mul(").?);
    // A `return` before the end would leave only its chunk: one function.
    const early = try std.mem.replaceOwned(u8, a, text, "    model.su.r[0] = (h0[0]).val();\n", "    if (t2 == 2) return;\n    model.su.r[0] = (h0[0]).val();\n");
    try std.testing.expect(try chunk(a, early, 120) == null);
    // A jump out of an arm keeps that statement whole.
    const out = try std.mem.replaceOwned(u8, a, text, "            h0[0] = S.con(0.0);\n", "            h0[0] = S.con(0.0);\n            if (t2 == 1) break :B1;\n");
    const c2 = (try chunk(a, out, 120)) orelse return;
    try std.testing.expect(std.mem.find(u8, c2.text, "zg1") == null);
}

test "chunk keeps one function for a small, stopping or unrecognised body" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\/// doc
        \\pub fn setup(comptime V: type, model: *Model) void {
        \\    @setFloatMode(.strict);
        \\    const S = V;
        \\    const t1 = S.con(model.a);
        \\    const t2 = t1.mul(t1);
        \\    model.su.r[0] = (t2).val();
        \\    return;
        \\}
        \\
        \\
    ;
    // A target past the whole body is one chunk, which is no split.
    try std.testing.expect(try chunk(a, text, 1 << 20) == null);
    // `zs_stop`/`zs_done` bodies leave through labels a chunk cannot see.
    const stop = try std.mem.replaceOwned(u8, a, text, "    return;\n", "    if (zs_stop) return;\n");
    try std.testing.expect(try chunk(a, stop, 16) == null);
    // Not `emitSetup`'s shape: no `pub fn setup(`, or not its closing.
    try std.testing.expect(try chunk(a, "fn other() void {}\n", 16) == null);
    try std.testing.expect(try chunk(a, text[0 .. text.len - 2], 16) == null);
}

test braceDelta {
    try std.testing.expectEqual(@as(i64, 1), braceDelta("B1: {"));
    try std.testing.expectEqual(@as(i64, 0), braceDelta("} else {"));
    try std.testing.expectEqual(@as(i64, -1), braceDelta("}"));
    // A brace in a string, a character literal or a comment is text.
    try std.testing.expectEqual(@as(i64, 0), braceDelta("const s = \"{{\";"));
    try std.testing.expectEqual(@as(i64, 0), braceDelta("const c = '{';"));
    try std.testing.expectEqual(@as(i64, 1), braceDelta("if (a) { // }"));
    // An escaped quote does not end the literal, so the `{` after it is text.
    try std.testing.expectEqual(@as(i64, 0), braceDelta("const s = \"\\\"{\";"));
    // Nor does an escaped apostrophe end a character literal.
    try std.testing.expectEqual(@as(i64, 0), braceDelta("const c = '\\''; const d = \"{\";"));
}

test stmtEnd {
    const body: Lines = &.{ "const a = 1;", "if (a) {", "    b();", "}", "c();" };
    try std.testing.expectEqual(@as(?usize, 1), stmtEnd(body, 0));
    try std.testing.expectEqual(@as(?usize, 4), stmtEnd(body, 1));
    try std.testing.expectEqual(@as(?usize, 5), stmtEnd(body, 4));
    // Unbalanced: a statement that never closes, or one that closes more
    // than it opened.
    try std.testing.expectEqual(@as(?usize, null), stmtEnd(&.{ "if (a) {", "b();" }, 0));
    try std.testing.expectEqual(@as(?usize, null), stmtEnd(&.{"}"}, 0));
}

test splitIf {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const both = (try splitIf(a, &.{ "if (c) {", "    x();", "} else {", "    y();", "}" })).?;
    try std.testing.expectEqualStrings("c", both.cond);
    try std.testing.expectEqual(@as(usize, 1), both.then.len);
    try std.testing.expectEqualStrings("x();", both.then[0]);
    try std.testing.expectEqual(@as(usize, 1), both.@"else".len);
    try std.testing.expectEqualStrings("y();", both.@"else"[0]);
    try std.testing.expect(both.has_else);
    const one = (try splitIf(a, &.{ "if (c) {", "    x();", "}" })).?;
    try std.testing.expect(!one.has_else);
    try std.testing.expectEqual(@as(usize, 0), one.@"else".len);
    // An `else if` chain is not two arms, and no other statement is an `if`.
    try std.testing.expect(try splitIf(a, &.{ "if (c) {", "    x();", "} else if (d) {", "    y();", "}" }) == null);
    try std.testing.expect(try splitIf(a, &.{"x();"}) == null);
}

test openBlock {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Each `break :B1` is the tail of an arm, so the block opens and the
    // breaks go: falling off the arm is leaving the block.
    const tail = (try openBlock(a, &.{ "B1: {", "    if (c) {", "        x();", "        break :B1;", "    } else {", "        break :B1;", "    }", "}" })).?;
    const want = [_][]const u8{ "if (c) {", "    x();", "} else {", "}" };
    try std.testing.expectEqual(want.len, tail.len);
    for (want, tail) |w, t| try std.testing.expectEqualStrings(w, t);
    // A break that is not in tail position skips code after it: the block stays.
    try std.testing.expect(try openBlock(a, &.{ "B1: {", "    if (c) break :B1;", "    x();", "}" }) == null);
    // Not a labelled block at all.
    try std.testing.expect(try openBlock(a, &.{"x();"}) == null);
}

test selfContained {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A jump to a label the lines define stays inside them.
    try std.testing.expect(try selfContained(a, &.{ "L1: while (true) {", "    continue :L1;", "}" }));
    try std.testing.expect(try selfContained(a, &.{ "B2: {", "    break :B2;", "}" }));
    // A jump out, or a return, leaves.
    try std.testing.expect(!try selfContained(a, &.{"break :B1;"}));
    try std.testing.expect(!try selfContained(a, &.{"return;"}));
}

test declOf {
    var p: Piece = .{ .guards = &.{}, .lines = &.{"const t3 = t1.mul(t1);"} };
    declOf(&p);
    try std.testing.expectEqualStrings("t3", p.name);
    try std.testing.expectEqualStrings("", p.ty);
    try std.testing.expectEqualStrings("t1.mul(t1);", p.lines[0][p.head..]);
    var q: Piece = .{ .guards = &.{}, .lines = &.{"var h0: [2]zOf(S, 0x0) = undefined;"} };
    declOf(&q);
    try std.testing.expectEqualStrings("h0", q.name);
    try std.testing.expectEqualStrings("[2]zOf(S, 0x0)", q.ty);
    // An assignment declares nothing.
    var r: Piece = .{ .guards = &.{}, .lines = &.{"model.su.r[0] = t3;"} };
    declOf(&r);
    try std.testing.expectEqualStrings("", r.name);
}

test dedent {
    try std.testing.expectEqualStrings("    x", dedent("        x", 4));
    try std.testing.expectEqualStrings("x", dedent("  x", 4));
    try std.testing.expectEqualStrings("", dedent("", 4));
}

test Idents {
    var it: Idents = .{ .text = "const t1 = S.con(model.a) + @as(f64, 2.5) // t9\n x" };
    for ([_][]const u8{ "const", "t1", "S", "model", "f64", "x" }) |want|
        try std.testing.expectEqualStrings(want, it.next().?);
    try std.testing.expect(it.next() == null);
    // A range bound is an operand, not a field: `..t5` reads `t5`.
    var r: Idents = .{ .text = "x[0..t5]" };
    try std.testing.expectEqualStrings("x", r.next().?);
    try std.testing.expectEqualStrings("t5", r.next().?);
    try std.testing.expect(r.next() == null);
}

test rename {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var moved: std.StringHashMapUnmanaged(void) = .empty;
    try moved.put(a, "t5", {});
    var out: std.ArrayList(u8) = .empty;
    try rename(a, &out, "h0[0] = t5.add(t5); // t5\nS.t5 + x[0..t5]", &moved);
    // Every read becomes `z.t5`; the comment and the field `.t5` stay.
    try std.testing.expectEqualStrings("h0[0] = z.t5.add(z.t5); // t5\nS.t5 + x[0..z.t5]", out.items);
}

test hasWord {
    try std.testing.expect(hasWord("const S = V;", "S"));
    try std.testing.expect(hasWord("x[0..S]", "S"));
    try std.testing.expect(!hasWord("model.S", "S")); // a field
    try std.testing.expect(!hasWord("\"S\"", "S")); // a string literal
    try std.testing.expect(!hasWord("// S", "S")); // a comment
    try std.testing.expect(!hasWord("SS + S_", "S")); // longer names
}

// Moved from the orchestrator's split-build test:
// it builds `chunk`'s output, so it lives with codegen, not `zigbuild`.
test "a chunked setup builds one object per chunk into a library that runs" {
    const zigbuild = @import("zigbuild");
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);
    try tmp.dir.writeFile(io, .{ .sub_path = "contract.zig", .data = "pub const k: f64 = 2.0;\n" });

    // `setup` emitted as chunks: each chunk is its own object when the host
    // names its value scalar, and `setup` reaches them through those objects.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const chunked = (try chunk(arena.allocator(),
        \\/// doc
        \\pub fn setup(comptime V: type, model: *Model) void {
        \\    @setFloatMode(.strict);
        \\    _ = V;
        \\    const t1: f64 = model.a * contract.k;
        \\    const t2: f64 = t1 + 1.0;
        \\    B1: {
        \\        if (t2 > 0.0) {
        \\            model.r = t2 * 2.0;
        \\            break :B1;
        \\        } else {
        \\            model.r = 0.0;
        \\            break :B1;
        \\        }
        \\    }
        \\    return;
        \\}
        \\
        \\
    , 64)).?;
    try std.testing.expect(chunked.n >= 2);
    const su_dev = try std.mem.concat(arena.allocator(), u8, &.{
        \\const std = @import("std");
        \\const contract = @import("contract");
        \\pub const Model = extern struct { a: f64 = 3.0, r: f64 = 0.0 };
        \\
        ,
        chunked.text,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "su.zig", .data =
        \\pub fn SetupValue(comptime D: type) type {
        \\    _ = D;
        \\    return f64;
        \\}
        \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
        \\    _ = .{ D, name };
        \\    @compileError("a split build calls exportDevicePart");
        \\}
        \\pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: @TypeOf(.setup)) void {
        \\    _ = name;
        \\    if (part == .setup) @export(&struct {
        \\        fn f(m: *D.Model) callconv(.c) void {
        \\            D.setup(f64, m);
        \\        }
        \\    }.f, .{ .name = "arp_setup" });
        \\}
        \\
    });
    {
        const mods = [_]zigbuild.Module{
            .{ .name = "contract", .root = try std.fs.path.join(gpa, &.{ work, "contract.zig" }) },
            .{ .name = "dyn", .root = try std.fs.path.join(gpa, &.{ work, "su.zig" }) },
        };
        defer for (mods) |m| gpa.free(m.root);
        const o: zigbuild.Options = .{ .work_dir = work, .name = "sudev", .optimize = .fast, .backend = .llvm, .modules = &mods, .split = true };
        var r = try zigbuild.compileRelease(gpa, io, o, .{ .text = su_dev, .setup_chunks = chunked.n }, 9);
        defer r.deinit(gpa);
        const so = switch (r) {
            .failed => |b| {
                b.renderToStderr(io, .{}, .off) catch {};
                return error.UnexpectedBuildFailure;
            },
            .ok => |a| a.so_path,
        };
        try tmp.dir.access(io, "shim_setup1.zig", .{});
        var lib = try @import("dynlib").DynLib.open(so);
        defer lib.close();
        const Model = extern struct { a: f64 = 3.0, r: f64 = 0.0 };
        const setup = lib.lookup(*const fn (*Model) callconv(.c) void, "arp_setup") orelse return error.MissingSymbol;
        var model: Model = .{};
        setup(&model);
        try std.testing.expectEqual(@as(f64, 14.0), model.r);
    }
}
