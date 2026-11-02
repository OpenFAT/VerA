//! `zig build suite -- --sweep`: generated Verilog-A of growing size ->
//! a MIR footprint table and a per-phase timing table on stdout. Each axis of
//! `gen` is swept over `sweep` with the others at 1, so the slope is the
//! point: an O(n^2) scan and a flat one can cost the same at n = 8.
//!
//! The half that can fail is `expected`, kept below: the device
//! and MIR sizes of every generated shape, asserted under `zig build test`
//! (two agents moving these sizes regenerate the table, they do not pick
//! a side).

const std = @import("std");
const vera = @import("vera");
const preprocessor = @import("frontend").preprocessor;
const zigbuild = @import("zigbuild");
const options = @import("suite_options");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// `root.zig` does not export `Mir`; the type is reached through the result
/// that carries it, the seam an embedder already has.
const Mir = @typeInfo(@FieldType(vera.Result, "mir")).pointer.child;

/// N for the sweep and for the spawn floor; the estimator is the min over it.
/// Noise on a shared machine only ever adds time, so the min is the closest
/// sample to the code's cost, where a mean measures the machine's load.
const reps = 25;

/// The mode the engine was compiled in, printed on every row because only a
/// ReleaseFast time is the shipping number (Debug is several times slower).
/// `builtin.mode` is this module's `-O`, which `build.zig` keeps equal to the
/// `vera` module's.
pub const mode = @tagName(@import("builtin").mode);

/// Nanoseconds since `t0` on the monotonic (`.awake`) clock.
pub fn elapsed(io: Io, t0: Io.Timestamp) u64 {
    const ns = t0.durationTo(.now(io, .awake)).nanoseconds;
    return @intCast(@max(ns, 0));
}

/// The sweep. Powers of eight, so a doubling and a squaring are visibly
/// different shapes across four steps rather than two.
pub const sweep = [_]u32{ 1, 8, 64, 512, 4096 };

/// The generated cases. Each pins the other two axes at 1, so a bend in one
/// column is attributable to one axis.
pub const Axis = enum { contrib, vals, inst };

// ---------------------------------------------------------------------------
// The generator
// ---------------------------------------------------------------------------

/// Emit a .va with `n_contrib` contributions, `n_vals` chained reals and
/// `n_inst` instances. Everything is LIVE: the value chain terminates in the
/// contributions and the contributions terminate in the top module's ports, so
/// nothing here measures the speed at which VerA deletes dead code.
fn gen(w: *Io.Writer, n_contrib: u32, n_vals: u32, n_inst: u32) Io.Writer.Error!void {
    try w.writeAll(
        \\module bench_leaf(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  parameter real gain = 1.0;
        \\
    );
    // A.6.3: only a named block declares, so the chain lives at module scope.
    for (0..n_vals) |i| try w.print("    real v{d};\n", .{i});
    try w.writeAll("  analog begin\n");
    try w.writeAll("    v0 = V(a, b) * gain;\n");
    for (1..n_vals) |i| try w.print("    v{d} = v{d} * 1.5 + 0.25;\n", .{ i, i - 1 });
    for (0..n_contrib) |i| try w.print(
        "    I(a, b) <+ gain * v{d} * {d}.0;\n",
        .{ n_vals - 1, i + 1 },
    );
    try w.writeAll(
        \\  end
        \\endmodule
        \\
        \\module bench_top(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\
    );
    for (0..n_inst) |i| try w.print("  bench_leaf i{d}(p, n);\n", .{i});
    try w.writeAll("endmodule\n");
}

fn genSource(gpa: Allocator, axis: Axis, n: u32) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try gen(
        &aw.writer,
        if (axis == .contrib) n else 1,
        if (axis == .vals) n else 1,
        if (axis == .inst) n else 1,
    );
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// The assertions — the half of this file that can fail
// ---------------------------------------------------------------------------

/// `device.text.len`, `mir.defs.len` and `mir.insts.len` for every generated
/// shape, in `sweep` order, measured by this sweep. Pure functions of the
/// source, so the same on every machine and optimize mode: a change here is a
/// change in what VerA emits, and the commit that moves it explains it.
const Shape = struct { device: usize, defs: usize, insts: usize };
const expected = std.enums.directEnumArrayDefault(Axis, [sweep.len]Shape, null, 0, .{
    .contrib = .{
        .{ .device = 38168, .defs = 8, .insts = 5 },
        .{ .device = 38523, .defs = 35, .insts = 26 },
        .{ .device = 41266, .defs = 258, .insts = 194 },
        .{ .device = 63669, .defs = 2050, .insts = 1538 },
        .{ .device = 246249, .defs = 16386, .insts = 12290 },
    },
    .vals = .{
        .{ .device = 38168, .defs = 8, .insts = 5 },
        .{ .device = 38350, .defs = 24, .insts = 19 },
        .{ .device = 39806, .defs = 136, .insts = 131 },
        .{ .device = 51511, .defs = 1032, .insts = 1027 },
        .{ .device = 145272, .defs = 8200, .insts = 8195 },
    },
    // Parallel instances share one (p, n) row; the MIR also carries each
    // instance's share of it (`lower_contrib.unitAccum`), dead in the device.
    .inst = .{
        .{ .device = 38168, .defs = 8, .insts = 5 },
        .{ .device = 39372, .defs = 57, .insts = 47 },
        .{ .device = 49220, .defs = 449, .insts = 383 },
        .{ .device = 129754, .defs = 3585, .insts = 3071 },
        .{ .device = 787539, .defs = 28673, .insts = 24575 },
    },
});

/// Compile one generated shape and hold it to `expected`. Shared by the bench
/// run (every point of the sweep) and by the unit test below (the two cheap
/// points), so the assertion has exactly one spelling.
fn checkShape(gpa: Allocator, axis: Axis, i: usize) !Footprint {
    const src = try genSource(gpa, axis, sweep[i]);
    defer gpa.free(src);

    var result = try vera.analyze(gpa, src, .{}, null);
    defer result.deinit(gpa);
    var device = try result.generate(gpa, .{}, null);
    defer device.deinit(gpa);

    const want = expected[@backingInt(axis)][i];
    try std.testing.expectEqual(want.defs, result.mir.defs.len);
    try std.testing.expectEqual(want.insts, result.mir.insts.len);
    try std.testing.expectEqual(want.device, device.output.text.len);
    return .of(result.mir);
}

// ---------------------------------------------------------------------------
// The MIR footprint — the other half of a size regression
// ---------------------------------------------------------------------------

/// What one compilation's MIR costs in bytes, by column. A `MultiArrayList` row
/// costs the sum of its field sizes, not `@sizeOf(Row)`. A constant row's bits
/// live in `Mir.consts`, so `bytes` counts that pool too. The dedup maps and the
/// interner are excluded: they are build-time scratch that `deinit` drops.
const Footprint = struct {
    insts: u64 = 0,
    defs: u64 = 0,
    blocks: u64 = 0,
    extra: u64 = 0,
    consts: u64 = 0,

    // ponytail: ask the SoA container for its row size; this still excludes spare capacity.
    const inst_b: u64 = std.MultiArrayList(Mir.InstRow).capacityInBytes(1);
    const def_b: u64 = std.MultiArrayList(Mir.ValueRow).capacityInBytes(1) + @sizeOf(Mir.Value); // + alias slot
    const block_b: u64 = std.MultiArrayList(Mir.BlockRow).capacityInBytes(1);

    fn of(m: *const Mir) Footprint {
        return .{
            .insts = m.insts.len,
            .defs = m.defs.len,
            .blocks = m.blocks.len,
            .extra = m.extra.items.len,
            .consts = m.consts.items.len,
        };
    }

    fn bytes(self: Footprint) u64 {
        return self.insts * inst_b + self.defs * def_b +
            self.blocks * block_b + self.extra * @sizeOf(u32) + self.consts * @sizeOf(u64);
    }
};

fn emitFootprint(w: *Io.Writer, case: []const u8, n: u32, f: Footprint) !void {
    try w.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        case, n, f.insts, f.defs, f.blocks, f.extra, f.bytes(),
    });
}

// ---------------------------------------------------------------------------
// The phases
// ---------------------------------------------------------------------------

/// The sweep's phases, each a prefix of the next (there is no seam that resumes
/// a compilation midway), so a stage's own cost is a subtraction: `lint - pp`
/// is lex+parse+lower+prove, `codegen - lint` is codegen.
///   pp        `preprocessor.process`                          text -> text
///   lint      `vera.analyze(gpa, src, .{}, null)`             text -> MIR
///   codegen   `result.generate(gpa, .{}, null)`               MIR -> device.zig
///   rewrite   `zigbuild.writeTree` a second time              device.zig -> 0 bytes
const Phase = enum { pp, lint, codegen, rewrite };

/// `bytes` is what the phase handled: preprocessed text out of `pp`, the same
/// text in for `lint`, device text out of `codegen`, bytes written to disk for
/// `rewrite` (asserted 0 by a test, not here).
const Sample = struct { min_ns: u64, bytes: u64 };

/// One timed compilation, freed after the clock is read.
const Kept = struct {
    result: vera.Result,
    device: ?vera.Device = null,

    fn deinit(k: *Kept, gpa: Allocator) void {
        if (k.device) |*d| d.deinit(gpa);
        k.result.deinit(gpa);
    }
};

/// Run `phase` over one generated source and return the bytes it handled.
///
/// `keep` receives the `Result` and its device instead of freeing them, so the
/// clock is read before teardown. Precondition: `keep` already has capacity for
/// `reps`, so no reallocation lands inside the timed region.
fn runPhase(
    gpa: Allocator,
    io: Io,
    phase: Phase,
    source: []const u8,
    work_dir: []const u8,
    keep: *std.ArrayList(Kept),
) !u64 {
    if (phase == .pp) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var bag = vera.diag.Bag.init(arena.allocator());
        const text = (try preprocessor.process(arena.allocator(), source, .{ .bag = &bag })).text;
        std.mem.doNotOptimizeAway(text.len);
        return text.len;
    }

    keep.appendAssumeCapacity(.{ .result = try vera.analyze(gpa, source, .{}, null) });
    const kept = &keep.items[keep.items.len - 1];

    std.mem.doNotOptimizeAway(kept.result.mir);
    if (phase == .lint) return kept.result.source.len;

    kept.device = try kept.result.generate(gpa, .{}, null);
    const device = kept.device.?.output;
    std.mem.doNotOptimizeAway(device.text.len);
    if (phase == .codegen) return device.text.len;

    // Prime the tree, then write it again: the no-op recompile. That it writes
    // 0 bytes is a `test` at the foot of the file; an assert under the clock
    // would time itself.
    _ = try rewrite(io, gpa, device, work_dir);
    return rewrite(io, gpa, device, work_dir);
}

/// One `zigbuild.writeTree`, returning how many bytes it actually put on
/// disk. Shared by the timed phase and by the test that pins the second call to
/// zero, so the claim and the measurement are the same code path.
fn rewrite(io: Io, gpa: Allocator, device: zigbuild.Output, work_dir: []const u8) !usize {
    return try zigbuild.writeTree(gpa, io, .{ .work_dir = work_dir, .name = "bench" }, device);
}

fn measure(
    gpa: Allocator,
    io: Io,
    phase: Phase,
    source: []const u8,
    work_dir: []const u8,
) !Sample {
    var kept: std.ArrayList(Kept) = .empty;
    defer {
        for (kept.items) |*k| k.deinit(gpa);
        kept.deinit(gpa);
    }
    try kept.ensureTotalCapacity(gpa, reps);

    var min: u64 = std.math.maxInt(u64);
    var bytes: u64 = 0;
    for (0..reps) |_| {
        const t0: Io.Timestamp = .now(io, .awake);
        bytes = try runPhase(gpa, io, phase, source, work_dir, &kept);
        min = @min(min, elapsed(io, t0));
    }
    return .{ .min_ns = min, .bytes = bytes };
}

fn emit(w: *Io.Writer, case: []const u8, n: u32, phase: Phase, s: Sample) !void {
    try w.print("{s}\t{s}\t{d}\t{t}\t{d}\t{d}\n", .{ mode, case, n, phase, s.min_ns, s.bytes });
}

/// `--sweep`: the footprint table, then the timing table, on `w`; returns exit
/// code 0. A shape that departs from `expected` is an error, not a row.
/// `arena` holds the generated sources until the caller frees it.
pub fn report(gpa: Allocator, io: Io, arena: Allocator, w: *Io.Writer) !u8 {
    // The footprint table is its own pass, one compile per shape outside every
    // timer: the timing table's `bytes` is a different quantity.
    try w.writeAll("case\tn\tinsts\tdefs\tblocks\textra\tmir_bytes\n");
    for (std.enums.values(Axis)) |axis| {
        for (sweep, 0..) |n, i| try emitFootprint(w, @tagName(axis), n, try checkShape(gpa, axis, i));
    }
    try w.flush();

    try w.writeAll("\nmode\tcase\tn\tphase\tmin_ns\tbytes\n");
    if (@import("builtin").mode != .fast) try w.print(
        "# {s}: NOT the shipping number (~8x slow). Re-run with -Doptimize=ReleaseFast.\n",
        .{mode},
    );
    for (std.enums.values(Axis)) |axis| {
        for (sweep) |n| {
            const src = try genSource(arena, axis, n);
            for (std.enums.values(Phase)) |p| {
                const s = try measure(gpa, io, p, src, options.work_root ++ "/benchmark/gen");
                try emit(w, @tagName(axis), n, p, s);
            }
            try w.flush();
        }
    }
    return 0;
}

// zigbuild's tree.zig claim: writing a tree already on disk touches nothing.
test "a second writeTree writes no bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const src = try genSource(gpa, .contrib, 1);
    defer gpa.free(src);
    var result = try vera.analyze(gpa, src, .{}, null);
    defer result.deinit(gpa);
    var device = try result.generate(gpa, .{}, null);
    defer device.deinit(gpa);

    const work = options.work_root ++ "/benchmark/rewrite-selftest";
    _ = try rewrite(io, gpa, device.output, work);
    try std.testing.expectEqual(@as(usize, 0), try rewrite(io, gpa, device.output, work));
}

// Every point of every axis, in `zig build test`, so a size regression in the
// emitted device fails the gate. The n = 4096 points are also the renderer's
// stack-depth check.
test "generated shapes emit the expected device and MIR size" {
    for (std.enums.values(Axis)) |axis| {
        for (0..5) |i| _ = try checkShape(std.testing.allocator, axis, i);
    }
}

test "gen emits every axis it is asked for" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try gen(&aw.writer, 3, 2, 4);
    const text = aw.written();

    // The axes are independent: asking for 3 contributions must not also change
    // how many instances or values come out.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, text, "I(a, b) <+"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "    real v"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, text, "  bench_leaf i"));
    // The chain terminates in the contribution, so nothing generated is dead.
    try std.testing.expect(std.mem.find(u8, text, "gain * v1 * 1.0;") != null);
}
