//! Generated inputs through every pass. As an executable (`vera-generators
//! <scratch dir>`, `zig build test-generators`, in `test`) it runs each
//! generator's table, one child process per row so a crash names its row;
//! its `test` blocks hold the generators' own tests.
//!   `wide`     N-wide sources (statement chains, case arms, sum terms,
//!              else-if chains, and N-deep nesting to compare) on a 1 MiB stack
//!   `escaped`  seeded escaped identifiers through every name-resolving path
//!   `files`    an include tree past the 65535-file table (E0154)
//!   `table`    the driver both share: rows, children, the `known` algebra
//!
//! One file: a nested namespace may not redeclare a name of the file scope,
//! so the file scope declares only `main`, the namespaces and the test below.

/// `vera-generators DIR`: every table's rows, each in its own child.
/// `vera-generators DIR <generator> A B`: one row, here.
pub fn main(init: @import("std").process.Init) !u8 {
    return table.main(init);
}

test {
    _ = table;
    _ = wide;
    _ = escaped;
    _ = files;
}

const table = struct {
    //! The driver: each generator's rows as argv lines of this executable,
    //! run as children (`jobs` at a time), each judged by how it ended; then
    //! the generator's `known` list. A known row that fails is XFAIL; one that
    //! passes is an XPASS and fails the run, as does a `known` row that names
    //! no row.

    const std = @import("std");
    const Io = std.Io;
    const Allocator = std.mem.Allocator;

    pub const Known = struct { row: []const u8, why: []const u8 };
    pub const Row = struct { name: []const u8, argv: []const []const u8 };

    pub fn main(init: std.process.Init) !u8 {
        const io = init.io;
        var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var args = try init.minimal.args.iterateAllocator(arena);
        _ = args.skip();
        const dir = args.next() orelse return error.MissingScratchDir;

        var buf: [4096]u8 = undefined;
        var stderr = Io.File.stderr().writerStreaming(io, &buf);
        const w = &stderr.interface;
        defer w.flush() catch {};

        if (args.next()) |generator| {
            const a = args.next() orelse return error.MissingRowArgument;
            const b = args.next() orelse return error.MissingRowArgument;
            const why = if (std.mem.eql(u8, generator, "wide"))
                try wide.child(io, dir, a, b)
            else if (std.mem.eql(u8, generator, "escaped"))
                try escaped.child(io, a, b)
            else
                return error.UnknownGenerator;
            if (why.len == 0) return 0;
            try w.print("{s}\n", .{why});
            return 1;
        }
        const exe = try std.process.executablePathAlloc(io, arena);
        var bad: usize = 0;
        bad += try drive(arena, io, w, "wide", try wide.rows(arena, exe, dir), wide.known);
        bad += try drive(arena, io, w, "escaped", try escaped.rows(arena, exe, dir), escaped.known);
        return if (bad == 0) 0 else 1;
    }

    /// Runs `rows`, prints BAD and XFAIL lines on `w` and a census; returns
    /// the BAD count.
    fn drive(arena: Allocator, io: Io, w: *Io.Writer, label: []const u8, rows_: []const Row, known: []const Known) !usize {
        const whys = try arena.alloc(?[]const u8, rows_.len);
        var pool: Pool = .{ .arena = arena, .io = io, .rows = rows_, .whys = whys };
        var group: Io.Group = .init;
        const hands = @max(1, @min(8, std.Thread.getCpuCount() catch 1));
        for (0..hands) |_| group.concurrent(io, Pool.work, .{&pool}) catch break;
        pool.work();
        try group.await(io);
        if (pool.failed) |e| return e;

        // XFAIL and the census on stdout: `zig build` prints a passing step's
        // stderr as noise.
        var out_buf: [4096]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
        const out = &stdout.interface;
        defer out.flush() catch {};
        var bad: usize = 0;
        const seen = try arena.alloc(bool, known.len);
        @memset(seen, false);
        for (rows_, whys) |row, why| {
            var marked: ?[]const u8 = null;
            for (known, seen) |k, *s| if (std.mem.eql(u8, k.row, row.name)) {
                s.* = true;
                marked = k.why;
            };
            if (why) |reason| {
                if (marked) |m| {
                    try out.print("XFAIL {s}: known: {s}\n", .{ row.name, m });
                    continue;
                }
                try w.print("BAD {s}: {s}\n", .{ row.name, reason });
                bad += 1;
            } else if (marked != null) {
                try w.print("BAD {s}: XPASS, delete its `known` row\n", .{row.name});
                bad += 1;
            }
        }
        for (known, seen) |k, s| if (!s) {
            try w.print("BAD {s}: `known` names no row of the table\n", .{k.row});
            bad += 1;
        };
        try (if (bad == 0) out else w).print("{s}: {d} rows, {d} BAD\n", .{ label, rows_.len, bad });
        return bad;
    }

    /// The rows' children and their cursor: one row per take, any number of hands.
    const Pool = struct {
        arena: Allocator,
        io: Io,
        rows: []const Row,
        /// Why each row failed; null: it held.
        whys: []?[]const u8,
        next: std.atomic.Value(usize) = .init(0),
        failed: ?anyerror = null,

        fn work(pool: *Pool) void {
            while (true) {
                const i = pool.next.fetchAdd(1, .monotonic);
                if (i >= pool.rows.len) return;
                pool.whys[i] = judge(pool.arena, pool.io, pool.rows[i].argv) catch |e| {
                    pool.failed = e;
                    return;
                };
            }
        }
    };

    fn judge(arena: Allocator, io: Io, argv: []const []const u8) !?[]const u8 {
        const r = try std.process.run(arena, io, .{ .argv = argv });
        return switch (r.term) {
            .exited => |c| if (c == 0) null else try arena.print("exit {d}: {s}", .{ c, head(r.stderr) }),
            else => try arena.print("did not exit: {any} (SEGV: a stack overflow; ABRT: a panic)\n{s}", .{ r.term, head(r.stderr) }),
        };
    }

    /// The first 2 KiB: an overflow's trace is thousands of frames.
    fn head(text: []const u8) []const u8 {
        return text[0..@min(text.len, 2048)];
    }
};

const wide = struct {
    //! Width is what no parse nesting measures: a 5000-statement chain, a
    //! 5000-arm `case` or a 5000-term sum is flat source, so a pass that walks
    //! it one call per element runs on whatever stack its caller has, and an
    //! embedder's thread may have 1 MiB. Three analog lowering walks and
    //! device codegen's `renderSelLazy` overflowed exactly so (case_5000,
    //! chainNext). Each shape goes through every pass VerA has for its
    //! language on a 1 MiB thread: a `.va` through `--lint`, `--emit-zig`,
    //! the `--emit-so` tree and `--emit-verilog`; the `.v` analogue through
    //! `--elab`, `--run` and `--emit-rtlil`. N-deep nesting is the comparison
    //! row: depth is measured, so `lib/base/deep_stack.zig` runs it on a stack
    //! sized for it, "not bounded by the calling thread's stack".
    //!
    //! The oracle is the stack: a recursion per element overflows it and the
    //! row's child dies on the guard page (a signal, BAD). A pass that returns
    //! must have succeeded, and an emitter's text must hold the last
    //! element's constant, so a pass that stopped early is caught too.

    const std = @import("std");
    const vera = @import("vera");
    const zigbuild = @import("zigbuild");
    const digital = @import("sim").digital;
    const native = @import("digital");

    const Io = std.Io;
    const Allocator = std.mem.Allocator;

    /// 2500 arms already overflowed 1 MiB in codegen, 5000 in analog lowering.
    const n = 5000;
    const stack_bytes = 1 << 20;

    /// Rows that fail on a real bug, with the bug. Empty is the goal.
    pub const known: []const table.Known = &.{
        .{ .row = "chain.va --emit-zig", .why = device_chain },
        .{ .row = "chain.va --emit-so-tree", .why = device_chain },
        .{ .row = "elsif.va --lint", .why = parser_caller },
        .{ .row = "elsif.va --emit-zig", .why = parser_caller },
        .{ .row = "elsif.va --emit-so-tree", .why = parser_caller },
        .{ .row = "elsif.va --emit-verilog", .why = parser_caller },
        .{ .row = "nest.va --lint", .why = parser_caller },
        .{ .row = "nest.va --emit-zig", .why = parser_caller },
        .{ .row = "nest.va --emit-so-tree", .why = parser_caller },
        .{ .row = "nest.va --emit-verilog", .why = parser_caller },
    };
    const device_chain = "device codegen renders a value's operands recursively (render.zig renderVal -> renderInst -> render_op.renderOp), one call per `y = y + c` statement";
    const parser_caller = "the parser's first segment (parser/stmt.zig:69 parseStmt, generate.zig:113 parseIf) runs on the caller's stack, which deep_stack.zig says nesting is not bounded by; `--elab`/`--run` pass, under runGuarded";

    const Shape = enum { chain, case_arms, sum, elsif, nest };
    const Pass = enum { lint, emit_zig, emit_so_tree, emit_verilog, elab, run, emit_rtlil };
    const analog_passes = [_]Pass{ .lint, .emit_zig, .emit_so_tree, .emit_verilog };
    const digital_passes = [_]Pass{ .elab, .run, .emit_rtlil };

    /// `chain.va --emit-zig`: what a row is called on the command line and in
    /// `known`.
    fn rowName(buf: []u8, s: Shape, p: Pass) []const u8 {
        const ext = if (@backingInt(p) < @backingInt(Pass.elab)) "va" else "v";
        return std.fmt.bufPrint(buf, "{t}.{s} --{s}", .{ s, ext, flagOf(p) }) catch unreachable; // 64 bytes hold every name
    }

    fn flagOf(p: Pass) []const u8 {
        return switch (p) {
            .lint => "lint",
            .emit_zig => "emit-zig",
            .emit_so_tree => "emit-so-tree",
            .emit_verilog => "emit-verilog",
            .elab => "elab",
            .run => "run",
            .emit_rtlil => "emit-rtlil",
        };
    }

    /// Every shape through every pass of its language.
    pub fn rows(arena: Allocator, exe: []const u8, dir: []const u8) ![]const table.Row {
        var out: std.ArrayList(table.Row) = .empty;
        for (std.enums.values(Shape)) |s| for (analog_passes ++ digital_passes) |p| {
            var nb: [64]u8 = undefined;
            try out.append(arena, .{
                .name = try arena.dupe(u8, rowName(&nb, s, p)),
                .argv = try arena.dupe([]const u8, &.{ exe, dir, "wide", @tagName(s), @tagName(p) }),
            });
        };
        return out.items;
    }

    /// One row on a 1 MiB thread: "" when it held, else why not.
    pub fn child(io: Io, dir: []const u8, shape: []const u8, pass: []const u8) ![]const u8 {
        const s = std.meta.stringToEnum(Shape, shape) orelse return error.UnknownShape;
        const p = std.meta.stringToEnum(Pass, pass) orelse return error.UnknownPass;
        var row: Row = .{ .shape = s, .pass = p, .dir = dir, .io = io };
        const t = try std.Thread.spawn(.{ .stack_size = stack_bytes }, Row.go, .{&row});
        t.join();
        return row.why;
    }

    /// One row, run by `go` on the 1 MiB thread: `why` is empty when it held.
    const Row = struct {
        shape: Shape,
        pass: Pass,
        dir: []const u8,
        io: Io,
        why: []const u8 = "",

        fn go(r: *Row) void {
            var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena_state.deinit();
            r.why = r.pass_(arena_state.allocator()) catch |e| @errorName(e);
            // `why` must outlive the arena.
            r.why = std.heap.page_allocator.dupe(u8, r.why) catch "OutOfMemory";
        }

        fn pass_(r: *Row, arena: Allocator) ![]const u8 {
            const gpa = std.heap.page_allocator;
            const io = r.io;
            var last_buf: [16]u8 = undefined;
            switch (r.pass) {
                .lint, .emit_zig, .emit_so_tree, .emit_verilog => {
                    const source = try analog(arena, r.shape);
                    var req: vera.Request = .{ .options = .{ .file_name = "m.va" } };
                    switch (r.pass) {
                        .lint => {},
                        .emit_zig, .emit_so_tree => req.zig = true,
                        .emit_verilog => req.verilog = .{},
                        else => unreachable,
                    }
                    var bag: vera.diag.Bag = .init(gpa);
                    defer bag.deinit(gpa);
                    var o: vera.Outcome = .{};
                    defer o.deinit(gpa);
                    try vera.compile(gpa, io, arena, source, req, &bag, &o);
                    if (o.status != 0 or bag.failed()) return arena.print("refused (status {d}): {s}", .{ o.status, o.err });
                    if (r.pass == .emit_so_tree) {
                        const dir = try std.fs.path.join(arena, &.{ r.dir, @tagName(r.shape) });
                        if (try zigbuild.writeTree(gpa, io, .{ .work_dir = dir, .name = "m" }, o.device.?.output) == 0) return "the tree has no files";
                        return "";
                    }
                    // `--emit-verilog` models the ports, not the analog body.
                    if (r.pass == .lint or r.pass == .emit_verilog) return "";
                    const last = try std.fmt.bufPrint(&last_buf, "{d}.5", .{n - 1});
                    if (std.mem.find(u8, o.text, last) == null) return arena.print("the text does not hold the last element's {s}", .{last});
                    return "";
                },
                .elab, .run, .emit_rtlil => {
                    const source = try design(arena, r.shape);
                    const opts: digital.Options = .{ .file_name = "t.v", .io = io };
                    var bag: vera.diag.Bag = .init(arena);
                    var sink: Io.Writer.Discarding = .init(&.{});
                    switch (r.pass) {
                        .elab => _ = try digital.elaborate(arena, source, opts, &bag, &sink.writer),
                        .run => try digital.run(arena, source, opts, &bag, &sink.writer),
                        .emit_rtlil => {
                            var why: []const u8 = "";
                            const text = native.rtlil.emit(arena, source, opts, &bag, &why) catch |e| switch (e) {
                                error.Refused => return arena.print("refused: {s}", .{why}),
                                else => |x| return x,
                            };
                            // RTLIL writes a constant in decimal or as 32 binary digits.
                            const last = try std.fmt.bufPrint(&last_buf, "{d}", .{n - 1});
                            var bits_buf: [40]u8 = undefined;
                            const bits = try std.fmt.bufPrint(&bits_buf, "32'{b:0>32}", .{n - 1});
                            if (std.mem.find(u8, text, last) == null and std.mem.find(u8, text, bits) == null)
                                return arena.print("the text does not hold the last element's {s}", .{last});
                        },
                        else => unreachable,
                    }
                    if (bag.failed()) return "refused: diagnostics";
                    return "";
                },
            }
        }
    };

    /// A `.va` of shape `s`, N wide (N deep for `nest`); its last element's
    /// constant is `(n - 1).5`.
    fn analog(arena: Allocator, s: Shape) ![]u8 {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(arena, "module m(p, n);\n  inout p, n;\n  electrical p, n;\n  real y;\n  integer k;\n  analog begin\n    y = V(p, n);\n    k = V(p, n);\n");
        try body(arena, &src, s, ".5");
        try src.appendSlice(arena, "    I(p, n) <+ y * V(p, n);\n  end\nendmodule\n");
        return src.items;
    }

    /// The `.v` analogue: the same shape in a combinational `always`.
    fn design(arena: Allocator, s: Shape) ![]u8 {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(arena, "module t(input [31:0] a, input [31:0] k, output reg [31:0] y);\n  always @(*) begin\n    y = a;\n");
        try body(arena, &src, s, "");
        try src.appendSlice(arena, "  end\nendmodule\n");
        return src.items;
    }

    /// The shape's statements over `y`, `k` and a term `t` (`V(p, n)` or `a`),
    /// each element's constant `i` then `frac`.
    fn body(arena: Allocator, src: *std.ArrayList(u8), s: Shape, frac: []const u8) !void {
        const t = if (frac.len != 0) "V(p, n)" else "a";
        switch (s) {
            .chain => for (0..n) |i| try src.print(arena, "    y = y + {d}{s};\n", .{ i, frac }),
            .case_arms => {
                try src.appendSlice(arena, "    case (k)\n");
                for (0..n) |i| try src.print(arena, "      {d}: y = {d}{s};\n", .{ i, i, frac });
                try src.appendSlice(arena, "    endcase\n");
            },
            .sum => {
                try src.appendSlice(arena, "    y = y");
                for (0..n) |i| try src.print(arena, " + {d}{s} * {s}", .{ i, frac, t });
                try src.appendSlice(arena, ";\n");
            },
            .elsif => for (0..n) |i| try src.print(arena, "    {s}if (k == {d}) y = {d}{s};\n", .{ if (i == 0) "" else "else ", i, i, frac }),
            .nest => {
                for (0..n) |_| try src.appendSlice(arena, "begin ");
                try src.print(arena, "y = y + {d}{s};", .{ n - 1, frac });
                for (0..n) |_| try src.appendSlice(arena, " end");
                try src.appendSlice(arena, "\n");
            },
        }
    }

    test "the shapes hold the last element's constant; the row names" {
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        for (std.enums.values(Shape)) |s| {
            const a = try analog(arena, s);
            const d = try design(arena, s);
            try std.testing.expect(std.mem.find(u8, a, "4999.5") != null);
            try std.testing.expect(std.mem.find(u8, d, "4999") != null);
        }
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings("chain.va --emit-zig", rowName(&buf, .chain, .emit_zig));
        try std.testing.expectEqualStrings("sum.v --emit-rtlil", rowName(&buf, .sum, .emit_rtlil));
    }
};

const escaped = struct {
    //! IEEE 1364-2005 §3.7.1: an escaped identifier is `\` and any printable
    //! characters up to white space, and "neither the leading backslash
    //! character nor the terminating white space is considered to be part of
    //! the identifier". So `\a[1] ` is one name, not `a` indexed by 1: the
    //! class of the defparam `segment()` abort (`\a__g[1]__in1`). A row is a
    //! feature (`Feature`: a bracket, a parenthesis, a dot, a `[k]` suffix, a
    //! bare `[k]`) through one path; each of its seeds names every object of
    //! two designs with fresh escaped identifiers holding that feature, and
    //! runs them through the paths that resolve a name:
    //! a three-level hierarchy with a two-segment `defparam` and hierarchical
    //! references under `--run`, and named port connections and a named
    //! parameter assignment under `--emit-rtlil`.
    //!
    //! The oracle is renaming: the same design with plain names (`n0`, `n1`,
    //! ...) must behave the same. `--run` prints the hand-derived `8 2 7`
    //! under both; `--emit-rtlil`'s text with each escaped name written as
    //! its plain one is the plain design's text. (The VPI path,
    //! `vpi_handle_by_name`, is `tests/vpi_escaped/`.)

    const std = @import("std");
    const vera = @import("vera");
    const digital = @import("sim").digital;
    const native = @import("digital");

    const Io = std.Io;
    const Allocator = std.mem.Allocator;

    /// Seeds per row: each row is one feature through one pass.
    const seeds = 16;
    const Pass = enum { run, emit_rtlil };

    /// What every name of a row's designs holds, besides printable text
    /// with none of `[].()\` (and no backtick: a directive inside a name is
    /// not this test's question).
    const Feature = enum {
        /// `[` or `]` inside, not ending the name.
        bracket,
        /// `(` or `)` anywhere.
        paren,
        /// `.` anywhere: a hierarchical name's separator, inside one name.
        dot,
        /// Ends in `[k]`, as `\a__g[1]__in1`'s gate-array names do.
        index_suffix,
        /// Is `[k]` and nothing else.
        index_only,
        /// Starts with `\`: `\\a ` is the name `\a`, not `a`.
        backslash,
    };

    pub const known: []const table.Known = &.{
        .{ .row = "index_suffix --run", .why = "E0901 on a legal defparam: elab_defparams.segment reads a segment ending in `]` as name[k], so `\\a[5] ` is looked up as `a` indexed 5" },
        .{ .row = "dot --run", .why = "E0901 on a legal defparam whose last segment starts with `$` and holds a `.` (`defparam u.\\$4.n  = 7;`): the name is kept as `\\$4.n` and names nothing (`\\$4 ` and `\\a.n ` work)" },
        .{ .row = "backslash --emit-rtlil", .why = "the parser interns `\\$x ` (the name `$x`) and `\\\\$x ` (the name `\\$x`) as one string, `\\$x` (Parser.internTok keeps a `$`-led escaped name's `\\`), so --emit-rtlil writes both as `\\$x`; a seed whose name starts with `\\$` fails. `\\\\a ` is written `\\\\a` since pass 3" },
        .{ .row = "index_only --run", .why = "abort: elab.isScope asserts a name is not empty, and segment() makes `\\[3] ` the name \"\" indexed 3 (an assertion on source text)" },
    };

    pub fn rows(arena: Allocator, exe: []const u8, dir: []const u8) ![]const table.Row {
        var out: std.ArrayList(table.Row) = .empty;
        for (std.enums.values(Feature)) |f| for (std.enums.values(Pass)) |p| {
            try out.append(arena, .{
                .name = try arena.print("{t} --{s}", .{ f, if (p == .run) "run" else "emit-rtlil" }),
                .argv = try arena.dupe([]const u8, &.{ exe, dir, "escaped", @tagName(f), @tagName(p) }),
            });
        };
        return out.items;
    }

    /// The names a design takes, one per role.
    const roles = 7;

    /// Seed `seed`'s names for `f`: distinct, 3 to 12 printable characters.
    fn names(arena: Allocator, f: Feature, seed: u64) ![roles][]const u8 {
        var prng: std.Random.DefaultPrng = .init(seed);
        const r = prng.random();
        var out: [roles][]const u8 = undefined;
        var i: usize = 0;
        while (i < roles) {
            var text: std.ArrayList(u8) = .empty;
            for (0..r.intRangeAtMost(usize, 2, 8)) |_| try text.append(arena, while (true) {
                const x = r.intRangeAtMost(u8, 0x21, 0x7e);
                if (std.mem.findScalar(u8, "[].()\\`", x) == null) break x;
            });
            const at = r.uintAtMost(usize, text.items.len - 1);
            switch (f) {
                .bracket => try text.insert(arena, at, "[]"[r.uintLessThan(usize, 2)]),
                .paren => try text.insert(arena, r.uintAtMost(usize, text.items.len), "()"[r.uintLessThan(usize, 2)]),
                .dot => try text.insert(arena, r.uintAtMost(usize, text.items.len), '.'),
                .index_suffix => try text.print(arena, "[{d}]", .{r.uintLessThan(u8, 10)}),
                .backslash => try text.insert(arena, 0, '\\'),
                .index_only => {
                    text.clearRetainingCapacity();
                    try text.print(arena, "[{d}]", .{r.uintLessThan(u8, 100)});
                },
            }
            for (out[0..i]) |o| {
                if (std.mem.eql(u8, o, text.items)) break;
            } else {
                out[i] = text.items;
                i += 1;
            }
        }
        return out;
    }

    /// `\text ` for an escaped run, `n<role>` for the plain one.
    fn ref(arena: Allocator, ns: ?[roles][]const u8, role: usize) ![]const u8 {
        return if (ns) |x| std.fmt.allocPrint(arena, "\\{s} ", .{x[role]}) else std.fmt.allocPrint(arena, "n{d}", .{role});
    }

    /// The `--run` design: `M` (0) with parameter `P` (1) and reg `R` (2),
    /// in `Q` (3) as `K` (4), in `top` as `I` (5) and `J` (6). The defparam
    /// moves `I.K.P` to 7, so `I.K.R` is 8, `J.K.R` 2.
    fn runDesign(arena: Allocator, ns: ?[roles][]const u8) ![]const u8 {
        var n: [roles][]const u8 = undefined;
        for (&n, 0..) |*x, i| x.* = try ref(arena, ns, i);
        return std.fmt.allocPrint(arena,
            \\module {0s};
            \\  parameter {1s} = 1;
            \\  reg [7:0] {2s};
            \\  initial {2s} = {1s} + 1;
            \\endmodule
            \\module {3s};
            \\  {0s} {4s} ();
            \\endmodule
            \\module top;
            \\  {3s} {5s} ();
            \\  {3s} {6s} ();
            \\  defparam {5s}.{4s}.{1s} = 7;
            \\  initial #1 $display("%0d %0d %0d", {5s}.{4s}.{2s}, {6s}.{4s}.{2s}, {5s}.{4s}.{1s});
            \\endmodule
            \\
        , .{ n[0], n[1], n[2], n[3], n[4], n[5], n[6] });
    }

    /// The `--emit-rtlil` design: `M` (0) with ports `A` (1), `R` (2) and
    /// parameter `P` (3), in `top` as `I` (4, `P` set to 7 by name) and `J`
    /// (5), connected by name. (`--emit-rtlil` refuses a defparam.)
    fn rtlilDesign(arena: Allocator, ns: ?[roles][]const u8) ![]const u8 {
        var n: [roles][]const u8 = undefined;
        for (&n, 0..) |*x, i| x.* = try ref(arena, ns, i);
        return std.fmt.allocPrint(arena,
            \\module {0s}({1s}, {2s});
            \\  input [7:0] {1s};
            \\  output [7:0] {2s};
            \\  parameter {3s} = 1;
            \\  assign {2s} = {1s} + {3s};
            \\endmodule
            \\module top(a, y, z);
            \\  input [7:0] a;
            \\  output [7:0] y, z;
            \\  {0s} #(.{3s}(7)) {4s} (.{1s}(a), .{2s}(y));
            \\  {0s} {5s} (.{1s}(a), .{2s}(z));
            \\endmodule
            \\
        , .{ n[0], n[1], n[2], n[3], n[4], n[5] });
    }

    /// One feature through one pass over every seed: "" when each escaped
    /// design behaved as its plain twin, else the first seed's difference.
    pub fn child(io: Io, feature: []const u8, pass: []const u8) ![]const u8 {
        const f = std.meta.stringToEnum(Feature, feature) orelse return error.UnknownFeature;
        const p = std.meta.stringToEnum(Pass, pass) orelse return error.UnknownPass;
        const arena = std.heap.page_allocator; // the child exits right after
        for (0..seeds) |seed| {
            const why = try one(arena, io, p, try names(arena, f, seed));
            if (why.len != 0) return arena.print("seed {d}: {s}", .{ seed, why });
        }
        return "";
    }

    fn one(arena: Allocator, io: Io, p: Pass, ns: [roles][]const u8) ![]const u8 {
        const opts: digital.Options = .{ .file_name = "t.v", .io = io };
        switch (p) {
            .run => {
                const want = "8 2 7\n";
                for ([_]?[roles][]const u8{ null, ns }) |which| {
                    const source = try runDesign(arena, which);
                    var bag: vera.diag.Bag = .init(arena);
                    var out: Io.Writer.Allocating = .init(arena);
                    digital.run(arena, source, opts, &bag, &out.writer) catch |e| return arena.print("{t}: {s} on\n{s}", .{ e, try messages(arena, &bag), source });
                    if (bag.failed() or !std.mem.eql(u8, out.written(), want))
                        return arena.print("printed `{s}`, want `{s}`, on\n{s}", .{ out.written(), want, source });
                }
                return "";
            },
            .emit_rtlil => {
                var texts: [2][]const u8 = undefined;
                for ([_]?[roles][]const u8{ null, ns }, &texts) |which, *text| {
                    const source = try rtlilDesign(arena, which);
                    var bag: vera.diag.Bag = .init(arena);
                    var why: []const u8 = "";
                    text.* = native.rtlil.emit(arena, source, opts, &bag, &why) catch |e| return arena.print("{t} {s} on\n{s}", .{ e, why, source });
                }
                // Longest first, so a name inside another is not cut out of it.
                var renamed = texts[1];
                var order: [roles]usize = undefined;
                for (&order, 0..) |*o, i| o.* = i;
                std.mem.sort(usize, order[0..6], ns, struct {
                    fn longer(x: [roles][]const u8, a: usize, b: usize) bool {
                        return x[a].len > x[b].len;
                    }
                }.longer);
                for (order[0..6]) |i| renamed = try std.mem.replaceOwned(u8, arena, renamed, ns[i], try std.fmt.allocPrint(arena, "n{d}", .{i}));
                if (!std.mem.eql(u8, renamed, texts[0]))
                    return arena.print("the escaped design's RTLIL, renamed, is not the plain one's:\n--- plain\n{s}\n--- escaped, renamed\n{s}\n--- escaped\n{s}", .{ texts[0], renamed, texts[1] });
                return "";
            },
        }
    }

    /// The bag's messages, one a line.
    fn messages(arena: Allocator, bag: *const vera.diag.Bag) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (0..bag.count()) |i| try out.print(arena, "{t} {s}\n", .{ bag.at(i).code, bag.at(i).message });
        return out.items;
    }

    test "seeded names: distinct, printable, each with its feature" {
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();
        for (std.enums.values(Feature)) |f| for (0..seeds) |seed| {
            const ns = try names(arena_state.allocator(), f, seed);
            for (ns, 0..) |a, i| {
                for (a) |c| try std.testing.expect(c > ' ' and c < 0x7f and c != '`');
                for (ns[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a, b));
                const ends_index = a[a.len - 1] == ']' and std.mem.findScalar(u8, a, '[') != null;
                try std.testing.expect(switch (f) {
                    .bracket => std.mem.findAny(u8, a, "[]") != null and !ends_index,
                    .paren => std.mem.findAny(u8, a, "()") != null,
                    .dot => std.mem.findScalar(u8, a, '.') != null,
                    .index_suffix => ends_index and a.len > 3,
                    .index_only => ends_index and a[0] == '[',
                    .backslash => a[0] == '\\' and std.mem.findScalar(u8, a[1..], '\\') == null,
                });
            }
        };
    }
};

const files = struct {
    //! Every location carries a 16-bit file id, so a compilation holds
    //! `diag.files_max` (65535) files, and each `include registers its file
    //! again: one header included 65536 times is past the table. An include
    //! tree is input, so that is E0154 (`lib/diag/code.zig`), never a crash;
    //! the oracle is that code in the bag of both front ends.

    const std = @import("std");
    const vera = @import("vera");
    const digital = @import("sim").digital;

    const Allocator = std.mem.Allocator;

    /// `n` `include lines of `h.vh`, then `tail`.
    fn includes(arena: Allocator, n: usize, tail: []const u8) ![]const u8 {
        var src: std.ArrayList(u8) = .empty;
        for (0..n) |_| try src.appendSlice(arena, "`include \"h.vh\"\n");
        try src.appendSlice(arena, tail);
        return src.items;
    }

    fn hasCode(bag: *const vera.diag.Bag, code: vera.diag.Code) bool {
        for (0..bag.count()) |i| if (bag.at(i).code == code) return true;
        return false;
    }

    test "E0154: an include tree past 65535 files is a coded refusal in both front ends, not a crash" {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "h.vh", .data = "" });
        const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        const past = vera.diag.files_max; // includes: with the source, one file past the table

        var bag: vera.diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var o: vera.Outcome = .{};
        defer o.deinit(gpa);
        const source = try includes(arena, past, "module m; endmodule\n");
        try vera.compile(gpa, io, arena, source, .{ .options = .{ .file_name = "m.va", .include_dirs = &.{dir} } }, &bag, &o);
        try std.testing.expect(o.status != 0);
        try std.testing.expect(hasCode(&bag, .E0154));

        var dbag: vera.diag.Bag = .init(arena);
        var sink: std.Io.Writer.Discarding = .init(&.{});
        const design = try includes(arena, past, "module t; endmodule\n");
        try std.testing.expectError(error.DigitalFailed, digital.elaborate(arena, design, .{ .file_name = "t.v", .include_dirs = &.{dir}, .io = io }, &dbag, &sink.writer));
        try std.testing.expect(hasCode(&dbag, .E0154));

        // One file fewer is inside the table.
        var ok: vera.diag.Bag = .init(arena);
        _ = try digital.elaborate(arena, try includes(arena, past - 1, "module t; endmodule\n"), .{ .file_name = "t.v", .include_dirs = &.{dir}, .io = io }, &ok, &sink.writer);
        try std.testing.expect(!hasCode(&ok, .E0154));
    }
};
