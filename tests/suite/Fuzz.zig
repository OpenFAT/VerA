//! `--fuzz N`: N random expressions, each printed by `vera --run` and by the
//! native executable of the same source; the two transcripts must be equal
//! and the executable must be native. The fixtures pin the §5.5 context
//! rules at the points someone thought of; this is the check on the rule
//! being implemented twice (`exec.evalContext`, `emit_expr.value`).
//!
//!   zig build suite -- devices --fuzz 2000
//!
//! Contents:
//! - `pub fn FuzzBits.format(self: FuzzBits, o: *Io.Writer) Io.Writer.Error!void`

const Child = @import("Child.zig");
const std = @import("std");
const options = @import("suite_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const child = Child;
const FuzzVar = struct { width: u32, signed: bool };
const fuzz_widths = [_]u32{ 1, 2, 3, 7, 8, 13, 16, 31, 32, 33, 48, 63, 64, 65, 100, 128, 129 };
const fuzz_vars = 12;
const fuzz_per_file = 400;

/// A sized binary literal of `width` random bits, mostly known.
const FuzzBits = struct {
    rand: std.Random,
    width: u32,
    known: bool = false,

    /// `{f}`: writes `<width>'b` and the digits, drawing them from `rand`.
    pub fn format(self: FuzzBits, o: *Io.Writer) Io.Writer.Error!void {
        try o.print("{d}'b", .{self.width});
        for (0..self.width) |_| try o.writeByte(if (!self.known and self.rand.uintLessThan(u8, 8) == 0) "xz"[self.rand.uintLessThan(u8, 2)] else "01"[self.rand.uintLessThan(u8, 2)]);
    }
};

/// Random expressions over one- and multi-word operands, every one of which
/// the native executable takes.
const FuzzGen = struct {
    rand: std.Random,
    vars: []const FuzzVar,
    out: *Io.Writer,
    /// No x or z literal.
    known: bool = false,

    /// Writes one expression; returns its self-determined width.
    fn expr(g: *FuzzGen, depth: u32) Io.Writer.Error!u32 {
        const o = g.out;
        const r = g.rand;
        if (depth == 0 or r.uintLessThan(u8, 5) == 0) return g.leaf();
        switch (r.uintLessThan(u8, 12)) {
            0 => {
                try o.writeAll(([_][]const u8{ "-", "~", "!", "&", "|", "^", "~&", "~^", "+" })[r.uintLessThan(usize, 9)]);
                try o.writeByte('(');
                const wa = try g.expr(depth - 1);
                try o.writeByte(')');
                return wa;
            },
            1, 2, 3 => {
                try o.writeByte('(');
                const wa = try g.expr(depth - 1);
                try o.writeAll(([_][]const u8{ " + ", " - ", " * ", " / ", " % ", " & ", " | ", " ^ ", " ~^ " })[r.uintLessThan(usize, 9)]);
                const wb = try g.expr(depth - 1);
                try o.writeByte(')');
                return @max(wa, wb);
            },
            4 => {
                try o.writeByte('(');
                _ = try g.expr(depth - 1);
                try o.writeAll(([_][]const u8{ " == ", " != ", " === ", " !== ", " < ", " <= ", " > ", " >= ", " && ", " || " })[r.uintLessThan(usize, 10)]);
                _ = try g.expr(depth - 1);
                try o.writeByte(')');
                return 1;
            },
            5 => {
                try o.writeByte('(');
                const wa = try g.expr(depth - 1);
                try o.writeAll(([_][]const u8{ " << ", " >> ", " <<< ", " >>> ", " ** " })[r.uintLessThan(usize, 5)]);
                if (r.boolean()) try o.print("{d}", .{r.uintLessThan(u32, 70)}) else _ = try g.expr(depth - 1);
                try o.writeByte(')');
                return wa;
            },
            6 => {
                try o.writeByte('(');
                _ = try g.expr(depth - 1);
                try o.writeAll(" ? ");
                const wa = try g.expr(depth - 1);
                try o.writeAll(" : ");
                const wb = try g.expr(depth - 1);
                try o.writeByte(')');
                return @max(wa, wb);
            },
            7 => {
                const i = r.uintLessThan(usize, g.vars.len);
                const j = r.uintLessThan(usize, g.vars.len);
                try o.print("{{v{d}, v{d}}}", .{ i, j });
                return g.vars[i].width + g.vars[j].width;
            },
            8 => {
                const i = r.uintLessThan(usize, g.vars.len);
                const n = 1 + r.uintLessThan(u32, 4);
                try o.print("{{{d}{{v{d}}}}}", .{ n, i });
                return n * g.vars[i].width;
            },
            9 => {
                try o.writeAll(if (r.boolean()) "$signed(" else "$unsigned(");
                const wa = try g.expr(depth - 1);
                try o.writeByte(')');
                return wa;
            },
            10 => {
                const i = r.uintLessThan(usize, g.vars.len);
                const vw = g.vars[i].width;
                if (r.boolean()) {
                    try o.print("v{d}[", .{i});
                    try g.index();
                    try o.writeByte(']');
                    return 1;
                }
                const lo = r.uintLessThan(u32, vw);
                const hi = lo + r.uintLessThan(u32, vw - lo);
                try o.print("v{d}[{d}:{d}]", .{ i, hi, lo });
                return hi - lo + 1;
            },
            else => {
                try o.writeAll("mem[");
                try g.index();
                try o.writeByte(']');
                return 8;
            },
        }
    }

    /// A leaf of at most 64 bits: the engine refuses a wider index.
    fn index(g: *FuzzGen) Io.Writer.Error!void {
        while (true) {
            const cut = g.out.end;
            if (try g.leaf() <= 64) return;
            g.out.end = cut;
        }
    }

    fn leaf(g: *FuzzGen) Io.Writer.Error!u32 {
        const o = g.out;
        const r = g.rand;
        switch (r.uintLessThan(u8, 6)) {
            0 => {
                try o.print("{d}", .{r.uintLessThan(u32, 300)});
                return 32;
            },
            1 => {
                if (g.known) try o.writeAll(([_][]const u8{ "'b1", "-4'sd3", "'sd7", "'h5a" })[r.uintLessThan(usize, 4)]) else try o.writeAll(([_][]const u8{ "'bx", "'bz", "'hx1", "'b1", "-4'sd3", "4'sb1x01", "'sd7", "3'bz0x" })[r.uintLessThan(usize, 8)]);
                return 32;
            },
            else => {
                const i = r.uintLessThan(usize, g.vars.len);
                try o.print("v{d}", .{i});
                return g.vars[i].width;
            },
        }
    }
};

/// `--fuzz N`: writes the designs under the scratch tree, runs both engines on
/// each and prints every differing line and a census to stderr. Exit 1 on the
/// first refused or non-native design, or when any transcript differs.
pub fn run(init: std.process.Init, vera_exe: []const u8, count: u32) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, vera_exe, gpa);
    defer gpa.free(exe);
    const work = options.work_root ++ "/fuzz";
    try Io.Dir.cwd().createDirPath(io, work);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(0x5eed_1364);
    const rand = prng.random();
    var done: u32 = 0;
    var file: u32 = 0;
    var failed = false;
    var twos: u32 = 0;
    var reruns: u32 = 0;
    while (done < count) : (file += 1) {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();
        const n = @min(fuzz_per_file, count - done);
        const late = file % 2 == 1;
        const src = try fuzzSource(a, rand, n, late);
        const path = try a.print("{s}/fuzz{d}.v", .{ work, file });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
        const want = try child.capture(a, io, &.{ exe, "--run", path });
        const built = try child.capture(a, io, &.{ exe, "--emit-exe", "--work-dir", work, path });
        if (want.exit != 0 or built.exit != 0) {
            try w.print("FAIL {s}: --run exited {d}, --emit-exe exited {d}\n{s}{s}\n", .{ path, want.exit, built.exit, want.stderr, built.stderr });
            return 1;
        }
        if (std.mem.find(u8, built.stderr, "not native (") != null) {
            try w.print("FAIL {s}: not native\n{s}\n", .{ path, built.stderr });
            return 1;
        }
        if (late and std.mem.find(u8, built.stderr, "4-state: ") != null) {
            try w.print("FAIL {s}: known operands, yet `--state=auto` built it 4-state\n{s}\n", .{ path, built.stderr });
            return 1;
        }
        const got = try child.capture(a, io, &.{ std.mem.trimEnd(u8, built.stdout, "\n"), "--vera-state" });
        if (std.mem.find(u8, got.stderr, "rerun") != null) reruns += 1 else if (std.mem.find(u8, got.stderr, "2-state") != null) twos += 1;
        if (!std.mem.eql(u8, want.stdout, got.stdout)) {
            failed = true;
            var wl = std.mem.splitScalar(u8, want.stdout, '\n');
            var gl = std.mem.splitScalar(u8, got.stdout, '\n');
            while (wl.next()) |x| {
                const y = gl.next() orelse "";
                if (!std.mem.eql(u8, x, y)) try w.print("FAIL {s}: --run `{s}`, native `{s}`\n", .{ path, x, y });
            }
        }
        done += n;
    }
    try w.print("fuzz: {d} expressions in {d} files, native {s} --run; --state=auto ran 2-state in {d} files, of which it reran {d} 4-state\n", .{ count, file, if (failed) "DIFFERS from" else "equals", twos + reruns, reruns });
    return if (failed) 1 else 0;
}

// ---- private ----

/// One design: `fuzz_vars` random four-state operands, then `n` lines, each
/// one random expression printed self-determined or through an assignment
/// to a random-width target (so its context width and signedness vary).
/// `late`: every operand and literal known, and the lines one tick after
/// them, so `--state=auto` computes them in its 2-state phase, where an x
/// an operator makes is printed as 4-state prints it and storing one reruns
/// the design 4-state.
fn fuzzSource(a: Allocator, rand: std.Random, n: u32, late: bool) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    const o = &out.writer;
    var vars: [fuzz_vars]FuzzVar = undefined;
    try o.writeAll("module fuzz;\n");
    for (&vars, 0..) |*v, i| {
        v.* = .{ .width = fuzz_widths[rand.uintLessThan(usize, fuzz_widths.len)], .signed = rand.boolean() };
        try o.print("  reg {s}[{d}:0] v{d};\n", .{ if (v.signed) "signed " else "", v.width - 1, i });
    }
    try o.writeAll("  reg [7:0] mem [2:5];\n");
    for (fuzz_widths, 0..) |tw, i| try o.print("  reg {s}[{d}:0] t{d};\n", .{ if (i % 2 == 0) "signed " else "", tw - 1, i });
    try o.writeAll("  initial begin\n");
    // Half the operands fully known, or arithmetic would almost always see
    // an x and never reach its known-value path.
    for (vars, 0..) |v, i| try o.print("    v{d} = {f};\n", .{ i, FuzzBits{ .rand = rand, .width = v.width, .known = late or i % 2 == 0 } });
    for (2..6) |i| try o.print("    mem[{d}] = {f};\n", .{ i, FuzzBits{ .rand = rand, .width = 8, .known = late } });
    if (late) {
        for (fuzz_widths, 0..) |_, i| try o.print("    t{d} = 0;\n", .{i});
        try o.writeAll("    #1;\n");
    }
    for (0..n) |line| {
        var g: FuzzGen = .{ .rand = rand, .vars = &vars, .out = o, .known = late };
        // `%d` of more than 64 bits is refused by both engines alike, so it
        // is asked of an expression only when its width is at most 64. A
        // late design stores only in its last tenth: storing an x ends the
        // 2-state phase for every line after it.
        if (rand.boolean() or (late and line < n - n / 10)) {
            var e: Io.Writer.Allocating = .init(a);
            g.out = &e.writer;
            const ew = try g.expr(3);
            try o.print("    $display(\"%b {s}\", {s}, {s});\n", .{ if (ew <= 64 and rand.boolean()) "%d" else "%h", e.written(), e.written() });
        } else {
            const t = rand.uintLessThan(usize, fuzz_widths.len);
            try o.print("    t{d} = ", .{t});
            _ = try g.expr(3);
            try o.print(";\n    $display(\"%b {s}\", t{d}, t{d});\n", .{ if (fuzz_widths[t] <= 64) "%d" else "%h", t, t });
        }
    }
    try o.writeAll("  end\nendmodule\n");
    return out.written();
}
