//! Generated inputs through every pass. As an executable (`vera-generators
//! <scratch dir>`, `zig build test-generators`, in `test`) it runs the `wide`
//! table, one child process per row so a stack overflow names its row; its
//! `test` blocks hold the generators' own tests.
//!
//! One file: a nested namespace may not redeclare a name of the file scope,
//! so the file scope declares only `main`, the namespaces and the test below.

pub fn main(init: @import("std").process.Init) !u8 {
    return wide.main(init);
}

test {
    _ = wide;
}

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
    //!
    //! A known failure is a row of `known` with its reason; a known row that
    //! passes is an XPASS and fails the run, as does a `known` row that names
    //! no row.

    const std = @import("std");
    const assert = std.debug.assert;
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
    const known: []const struct { row: []const u8, why: []const u8 } = &.{
        .{ .row = "chain.va --emit-zig", .why = device_chain },
        .{ .row = "chain.va --emit-so-tree", .why = device_chain },
        .{ .row = "sum.v --emit-rtlil", .why = "rtlil_expr.zig:53 recurses once per `+` term; overflows even the CLI's 16 MiB main thread (vera --emit-rtlil on a 5000-term sum crashes)" },
        .{ .row = "elsif.va --lint", .why = parser_caller },
        .{ .row = "elsif.va --emit-zig", .why = parser_caller },
        .{ .row = "elsif.va --emit-so-tree", .why = parser_caller },
        .{ .row = "elsif.va --emit-verilog", .why = parser_caller },
        .{ .row = "elsif.v --emit-rtlil", .why = parser_caller },
        .{ .row = "nest.va --lint", .why = parser_caller },
        .{ .row = "nest.va --emit-zig", .why = parser_caller },
        .{ .row = "nest.va --emit-so-tree", .why = parser_caller },
        .{ .row = "nest.va --emit-verilog", .why = parser_caller },
        .{ .row = "nest.v --emit-rtlil", .why = parser_caller },
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

    /// `vera-generators DIR`: every row in its own child, then the verdicts.
    /// `vera-generators DIR SHAPE PASS`: one row, here, on a 1 MiB thread.
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

        if (args.next()) |shape| {
            const s = std.meta.stringToEnum(Shape, shape) orelse return error.UnknownShape;
            const p = std.meta.stringToEnum(Pass, args.next() orelse return error.MissingPass) orelse return error.UnknownPass;
            var row: Row = .{ .shape = s, .pass = p, .dir = dir, .io = io };
            const t = try std.Thread.spawn(.{ .stack_size = stack_bytes }, Row.go, .{&row});
            t.join();
            if (row.why.len == 0) return 0;
            try w.print("{s}\n", .{row.why});
            return 1;
        }
        return drive(arena, io, dir, w);
    }

    /// One child per row, `jobs` at a time; BAD and XFAIL lines on `w`.
    fn drive(arena: Allocator, io: Io, dir: []const u8, w: *Io.Writer) !u8 {
        const exe = try std.process.executablePathAlloc(io, arena);
        var names: std.ArrayList([]const u8) = .empty;
        var argvs: std.ArrayList([]const []const u8) = .empty;
        for (std.enums.values(Shape)) |s| {
            for (analog_passes ++ digital_passes) |p| {
                var nb: [64]u8 = undefined;
                try names.append(arena, try arena.dupe(u8, rowName(&nb, s, p)));
                try argvs.append(arena, try arena.dupe([]const u8, &.{ exe, dir, @tagName(s), @tagName(p) }));
            }
        }
        const whys = try arena.alloc(?[]const u8, names.items.len);
        var pool: Pool = .{ .arena = arena, .io = io, .argvs = argvs.items, .whys = whys };
        var group: Io.Group = .init;
        const hands = @max(1, @min(8, std.Thread.getCpuCount() catch 1));
        for (0..hands) |_| group.concurrent(io, Pool.work, .{&pool}) catch break;
        pool.work();
        try group.await(io);
        if (pool.failed) |e| return e;

        var bad: usize = 0;
        const seen = try arena.alloc(bool, known.len);
        @memset(seen, false);
        for (names.items, whys) |name, why| {
            var marked: ?[]const u8 = null;
            for (known, seen) |k, *s| if (std.mem.eql(u8, k.row, name)) {
                s.* = true;
                marked = k.why;
            };
            if (why) |reason| {
                if (marked) |m| {
                    try w.print("XFAIL {s}: known: {s}\n", .{ name, m });
                    continue;
                }
                try w.print("BAD {s}: {s}\n", .{ name, reason });
                bad += 1;
            } else if (marked != null) {
                try w.print("BAD {s}: XPASS, delete its `known` row\n", .{name});
                bad += 1;
            }
        }
        for (known, seen) |k, s| if (!s) {
            try w.print("BAD {s}: `known` names no row of the table\n", .{k.row});
            bad += 1;
        };
        // The census on stdout: `zig build` prints a passing step's stderr as noise.
        var out_buf: [256]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
        const census = if (bad == 0) &stdout.interface else w;
        try census.print("wide: {d} rows, N = {d}, on a {d} KiB stack; {d} BAD\n", .{ names.items.len, n, stack_bytes >> 10, bad });
        try census.flush();
        return if (bad == 0) 0 else 1;
    }

    /// The rows' children and their cursor: one row per take, any number of hands.
    const Pool = struct {
        arena: Allocator,
        io: Io,
        argvs: []const []const []const u8,
        /// Why each row failed; null: it held.
        whys: []?[]const u8,
        next: std.atomic.Value(usize) = .init(0),
        failed: ?anyerror = null,

        fn work(pool: *Pool) void {
            while (true) {
                const i = pool.next.fetchAdd(1, .monotonic);
                if (i >= pool.argvs.len) return;
                pool.whys[i] = judge(pool.arena, pool.io, pool.argvs[i]) catch |e| {
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
            else => try arena.print("did not exit: {any} (a stack overflow is a SEGV)\n{s}", .{ r.term, head(r.stderr) }),
        };
    }

    /// The first 2 KiB: an overflow's trace is thousands of frames.
    fn head(text: []const u8) []const u8 {
        return text[0..@min(text.len, 2048)];
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
