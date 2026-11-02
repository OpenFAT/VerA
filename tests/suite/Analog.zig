//! VerA as a harness `Compiler` for `zig build suite`: fixture -> verdict.
//! `//! reject` must refuse with every substring in the diagnostic; `//! warn`
//! must compile with each substring in a warning; anything else must compile,
//! build a native testbench, run, and print `ok=1` for every assertion. The
//! `want` of an assertion is a hand-derived literal, so VerA never supplies its
//! own expectation and no golden transcript exists.
//!
//! Contents:
//! - `pub const Ctx = struct`
//! - `pub fn Ctx.deinit(ctx: *Ctx, gpa: std.mem.Allocator) void`
//! - `pub fn compiler(ctx: *Ctx) harness.Compiler`
//! - `pub fn acceptRejectCompiler() harness.Compiler`
//! - `pub fn compileOnce(gpa: std.mem.Allocator, f: Fixture, source: []const u8, d: tb.Spec) !?usize`

const Fixtures = @import("Fixtures.zig");
const Digital = @import("Digital.zig");
const std = @import("std");
const vera = @import("vera");
const tb = @import("exe");
const zigbuild = @import("zigbuild");
const options = @import("suite_options");
const Io = std.Io;
const Fixture = harness.Fixture;
const Result = harness.Result;

/// `compiler`'s state: the suite's knobs, and the testbenches `prepare` built
/// in batches.
pub const Ctx = struct {
    /// Borrowed for `fixture_opt`/`fixture_backend`.
    cfg: *const harness.Config,
    /// Fixture path -> the batch binary that stands in for its testbench.
    /// Written by `prepare` alone, before any `check` reads it.
    batched: std.StringHashMapUnmanaged(Batched) = .empty,
    /// The batch binaries' paths, owned by the `gpa` given to `prepare`.
    bins: std.ArrayList([]const u8) = .empty,

    /// Frees what `prepare` allocated; `gpa` must be the one it was given.
    pub fn deinit(ctx: *Ctx, gpa: std.mem.Allocator) void {
        for (ctx.bins.items) |b| gpa.free(b);
        ctx.bins.deinit(gpa);
        ctx.batched.deinit(gpa);
    }
};

const harness = Fixtures;
const digital = Digital;

/// The suite's fixture root and LRM directory, shared with `Fixtures`.
const suite = options;

/// One fixture's member slot in a batch binary.
const Batched = struct { bin: []const u8, index: usize };

/// Fixtures per batch, in walk order. A batch build pays the compiler's fixed
/// cost once instead of `batch_size` times; larger batches serialise more of
/// the run behind one build and hold more in one compiler's memory.
const batch_size = 8;

/// One batch's outcome: which of its fixtures (offsets in the chunk, each
/// below `batch_size`) are members, in member order, and the binary when it
/// built. One per `batch_size` fixtures; `member[0..n]` is what is valid.
const Chunk = struct {
    member: [batch_size]u8 = undefined,
    n: u8 = 0,
    bin: ?[]const u8 = null,
};

// Budget: the offsets are below `batch_size`, so a byte each; `usize` offsets
// made a row 88 B.
comptime {
    std.debug.assert(batch_size <= std.math.maxInt(u8));
    std.debug.assert(@sizeOf(Chunk) == 32);
}

/// `prepare`'s work queue: one chunk of fixtures per take.
const Pool = struct {
    gpa: std.mem.Allocator,
    io: Io,
    ctx: *const Ctx,
    fixtures: []const Fixture,
    chunks: []Chunk,
    next: std.atomic.Value(usize) = .init(0),

    fn work(pool: *Pool) void {
        while (true) {
            const k = pool.next.fetchAdd(1, .monotonic);
            if (k >= pool.chunks.len) return;
            pool.chunk(k) catch {}; // a batch that fails marks nothing; `check` builds alone
        }
    }

    fn chunk(pool: *Pool, k: usize) !void {
        var arena_state: std.heap.ArenaAllocator = .init(pool.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const lo = k * batch_size;
        const fs = pool.fixtures[lo..@min(lo + batch_size, pool.fixtures.len)];
        var staged: [batch_size]zigbuild.Staged = undefined;
        const c = &pool.chunks[k];
        for (fs, 0..) |f, fi| {
            const source = Io.Dir.cwd().readFileAlloc(pool.io, f.path, arena, .limited(1 << 20)) catch continue;
            if (digital.vcdExpectation(source) != null) continue;
            const d = tb.Spec.parse(arena, source, null) catch continue;
            if (d.harness.reject.len != 0) continue;
            var sink: ?zigbuild.Staged = null;
            var discard: Io.Writer.Discarding = .init(&.{});
            _ = runAndCheck(pool.gpa, pool.io, arena, pool.ctx, f, source, d, &discard.writer, &sink) catch continue;
            staged[c.n] = sink orelse continue;
            c.member[c.n] = @intCast(fi);
            c.n += 1;
        }
        if (c.n < 2) return; // one member gains nothing over its own build
        const cfg = pool.ctx.cfg;
        const built = try zigbuild.buildBatch(pool.gpa, pool.io, staged[0..c.n], .{
            .work_dir = try arena.print("{s}/torture-batch/{d}", .{ options.work_root, k }),
            .contract = options.contract,
            .name = "batch",
            .zig_exe = options.zig_exe,
            .optimize = cfg.fixture_opt,
            .backend = cfg.fixture_backend,
            .strip = true,
        });
        switch (built) {
            .ok => |bin| c.bin = bin,
            .failed => |text| pool.gpa.free(text),
        }
    }
};

var no_ctx: u8 = 0;

/// Why a fixture failed to produce a device, in the vocabulary the `//! reject`
/// directives are written in.
const Failure = struct {
    /// `@errorName` of the returned error, or a synthetic name for the two
    /// failure modes that are not Zig errors (see `compileFixture`).
    error_name: []const u8,
    diags: vera.diag.Bag,
    /// Non-null only for `GeneratedCompileError`; owned by `gpa`.
    generated: ?[]const u8 = null,
};

/// What one compilation did. `accepted` carries the device's size, not its
/// text: nothing downstream reads the text.
const Outcome = union(enum) {
    accepted: usize,
    refused: Failure,

    fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .accepted => {},
            .refused => |*bad| {
                if (bad.generated) |g| gpa.free(g);
                bad.diags.deinit(gpa);
            },
        }
    }
};

const Tally = struct { total: usize, failed: usize };

const posix = struct {
    test "a batch runs each member by argv[0]; one member that does not compile fails the batch" {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const work = options.work_root ++ "/batch-selftest";
        // Prints its device's tag and the plusargs it was handed.
        const runner =
            \\const std = @import("std");
            \\const device = @import("device");
            \\pub fn main(init: std.process.Init.Minimal) void {
            \\    const argv = init.args.toSlice(std.heap.page_allocator) catch return;
            \\    std.debug.print("{s}", .{device.tag});
            \\    for (argv[1..]) |a| std.debug.print(" {s}", .{a});
            \\    std.debug.print("\n", .{});
            \\}
            \\
        ;
        const tags = [_][]const u8{ "a", "b", "broken" };
        var staged: [tags.len]zigbuild.Staged = undefined;
        var dirs: [tags.len][]const u8 = undefined;
        for (&staged, &dirs, tags) |*s, *dir, tag| {
            dir.* = try std.fs.path.join(arena, &.{ work, tag });
            const device = if (std.mem.eql(u8, tag, "broken")) "pub const tag = 1 +;\n" else try arena.print("pub const tag = \"{s}\";\n", .{tag});
            s.* = try zigbuild.stage(arena, io, device, runner, .{ .work_dir = dir.*, .contract = options.contract, .name = tag, .zig_exe = options.zig_exe });
        }
        const opts: zigbuild.BuildOptions = .{ .work_dir = work ++ "/batch", .contract = options.contract, .name = "batch", .zig_exe = options.zig_exe, .strip = true };

        const built = try zigbuild.buildBatch(gpa, io, staged[0..2], opts);
        defer built.deinit(gpa);
        const bin = switch (built) {
            .ok => |p| p,
            .failed => |text| {
                std.debug.print("{s}\n", .{text});
                return error.TestUnexpectedResult;
            },
        };
        for (0..2) |i| {
            const link = try linkBatched(gpa, io, arena, dirs[i], .{ .bin = bin, .index = i });
            defer link.deinit(gpa);
            const got = try capture(gpa, io, link.ok, dirs[i], 0, &.{ "+x=1", "+y" });
            defer gpa.free(got);
            try std.testing.expectEqualStrings(try arena.print("{s} +x=1 +y\n", .{tags[i]}), got);
        }

        const bad = try zigbuild.buildBatch(gpa, io, &staged, opts);
        defer bad.deinit(gpa);
        try std.testing.expect(bad == .failed);
    }

    test "capture forwards runtime argv without expansion and preserves order" {
        // Independent POSIX argv probe, not a generated model: the model's current
        // plusarg stub cannot distinguish missing runner plumbing from its own bug.
        // Only this fixed script is interpreted; fixture bytes stay positional
        // arguments, quoted by the probe and never inserted into its source.
        const got = try capture(std.testing.allocator, std.testing.io, "/bin/sh", "/bin", 0, &.{
            "-c",      "for arg do printf '%s\\n' \"$arg\" >&2; done", "argv-probe",
            "+gain=7", "+gain=8",                                      "+gain=7",
            "+empty=", "+literal=$HOME;*",                             "+literal=$(printf_EXPANDED)",
        });
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(
            "+gain=7\n+gain=8\n+gain=7\n+empty=\n+literal=$HOME;*\n+literal=$(printf_EXPANDED)\n",
            got,
        );
        const absent = try capture(std.testing.allocator, std.testing.io, "/bin/sh", "/bin", 0, &.{});
        defer std.testing.allocator.free(absent);
        try std.testing.expectEqualStrings("", absent);
    }
};

/// VerA at full depth: compile, build a testbench, run it, read the `ok=`
/// columns. `ctx` must outlive the returned plug.
pub fn compiler(ctx: *Ctx) harness.Compiler {
    return .{
        .name = "vera",
        .runs = true,
        .owns_xfail = true,
        .ctx = ctx,
        .check = check,
        .prepare = prepare,
    };
}

/// VerA held to what a foreign compiler is held to (accept or refuse only), so
/// the head-to-head's agreement column asks both sides the same question.
pub fn acceptRejectCompiler() harness.Compiler {
    return .{
        .name = "vera",
        .runs = false,
        // `//! xfail` marks debt against the full claim; a fixture that compiles
        // and then computes a wrong number is met here and would XPASS.
        .owns_xfail = false,
        .ctx = &no_ctx,
        .check = checkAcceptReject,
    };
}

/// One accept/reject compilation, the unit the head-to-head times: returns the
/// emitted device's size, or null when VerA refused. No testbench is built, so
/// no `zig build-exe` time lands in VerA's number.
pub fn compileOnce(gpa: std.mem.Allocator, f: Fixture, source: []const u8, d: tb.Spec) !?usize {
    var outcome = try compileFixture(gpa, f, source, d);
    defer outcome.deinit(gpa);
    return switch (outcome) {
        .accepted => |n| n,
        .refused => null,
    };
}

// ---- private ----

/// The compile -> batch-build half of the run: every fixture is compiled and
/// staged as `check` would, and each run of `batch_size` consecutive fixtures
/// whose testbench is a plain analog runner is built as one binary (the mixed
/// runner links `sim` and stays one build per fixture). `check` then compiles
/// again (milliseconds), finds the batch binary, and runs it in place of its
/// own build. A batch that does not build marks nothing: its fixtures build
/// one by one in `check`, so a failure names its own fixture.
fn prepare(ctx_ptr: *anyopaque, gpa: std.mem.Allocator, io: Io, fixtures: []const Fixture, jobs: usize) anyerror!void {
    // ponytail: argv[0] dispatch goes through a symlink; Windows builds one by one.
    if (@import("builtin").os.tag == .windows) return;
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const chunks = try gpa.alloc(Chunk, (fixtures.len + batch_size - 1) / batch_size);
    defer gpa.free(chunks);
    @memset(chunks, .{});
    var pool: Pool = .{ .gpa = gpa, .io = io, .ctx = ctx, .fixtures = fixtures, .chunks = chunks };
    var group: Io.Group = .init;
    var hands: usize = 0;
    while (hands < jobs) : (hands += 1) group.concurrent(io, Pool.work, .{&pool}) catch break;
    if (hands == 0) pool.work();
    try group.await(io);

    for (chunks, 0..) |c, k| {
        const bin = c.bin orelse continue;
        try ctx.bins.append(gpa, bin);
        const lo = k * batch_size;
        for (c.member[0..c.n], 0..) |fi, i| try ctx.batched.put(gpa, fixtures[lo + fi].path, .{ .bin = bin, .index = i });
    }
}

fn checkAcceptReject(
    _: *anyopaque,
    gpa: std.mem.Allocator,
    _: Io,
    _: std.mem.Allocator,
    f: Fixture,
    source: []const u8,
    d: tb.Spec,
    w: *Io.Writer,
) anyerror!Result {
    var outcome = try compileFixture(gpa, f, source, d);
    defer outcome.deinit(gpa);
    const must_reject = d.harness.reject.len != 0;
    if ((outcome == .accepted) == !must_reject) return .met;
    if (must_reject) {
        try w.print("FAIL {s}: the LRM says this must not compile, and vera accepted it.\n", .{f.path});
    } else {
        try w.print("FAIL {s}: must compile, and vera refused it: {s}\n", .{ f.path, outcome.refused.error_name });
    }
    return .unmet;
}

fn check(
    ctx: *anyopaque,
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    f: Fixture,
    source: []const u8,
    d: tb.Spec,
    w: *Io.Writer,
) anyerror!Result {
    const c: *const Ctx = @ptrCast(@alignCast(ctx));
    if (d.harness.reject.len != 0) return verifyRejected(gpa, f, source, d, w);
    return runAndCheck(gpa, io, arena, c, f, source, d, w, null);
}

// ---------------------------------------------------------------------------
// The reject half: the expected behavior is a diagnostic
// ---------------------------------------------------------------------------

fn verifyRejected(
    gpa: std.mem.Allocator,
    f: Fixture,
    source: []const u8,
    d: tb.Spec,
    w: *Io.Writer,
) !Result {
    var outcome = try compileFixture(gpa, f, source, d);
    defer outcome.deinit(gpa);
    const bad = switch (outcome) {
        .accepted => {
            try w.print("FAIL {s}: expected a diagnostic, but it compiled cleanly\n", .{f.path});
            return .unmet;
        },
        .refused => |b| b,
    };

    for (d.harness.reject) |pattern| {
        if (!failureContains(bad, pattern)) {
            try w.print("FAIL {s}: diagnostic substring not found: \"{s}\"\n", .{ f.path, pattern });
            try w.print("  error: {s}\n", .{bad.error_name});
            try printDiags(bad, w);
            return .unmet;
        }
    }
    // `//! reject-only`: the refusal is the named rule's alone. An error no
    // pattern names is a second refusal riding inside this one, which a plain
    // `reject` cannot see.
    if (harness.probe_reject_only) {
        for (0..bad.diags.count()) |i| {
            if (bad.diags.at(i).severity != .err) continue;
            for (d.harness.reject) |pattern| {
                if (diagSays(&bad.diags, i, pattern)) break;
            } else {
                try w.print("ONLY-NO {s}: {t}\n", .{ f.path, bad.diags.at(i).code });
                return .met;
            }
        }
        try w.print("ONLY-OK {s}\n", .{f.path});
        return .met;
    }
    if (d.harness.reject_only) for (0..bad.diags.count()) |i| {
        if (bad.diags.at(i).severity != .err) continue;
        for (d.harness.reject) |pattern| {
            if (diagSays(&bad.diags, i, pattern)) break;
        } else {
            const e = bad.diags.at(i);
            try w.print("FAIL {s}: `//! reject-only`, and a second error fired: {t} {s}\n", .{ f.path, e.code, vera.diag.info(e.code).title });
            try printDiags(bad, w);
            return .unmet;
        }
    };
    return .met;
}

/// One compilation. Two failure modes are not Zig errors and get synthetic
/// names, matching the vocabulary the fixtures use:
///   `DiagnosticsReported`  — compiled, but a stage reported a message.
///   `GeneratedCompileError` — codegen deliberately emitted `@compileError`.
fn compileFixture(gpa: std.mem.Allocator, f: Fixture, source: []const u8, d: tb.Spec) !Outcome {
    var diags: vera.diag.Bag = .init(gpa);
    // Codegen too (not only the analysis `--lint` runs): some fixtures are
    // rejected by codegen emitting `@compileError`, which the analysis would
    // never see.
    var result = vera.analyze(gpa, source, .{
        .file_name = f.path,
        .include_dirs = &.{ f.dir(), harness.include_dir },
        // The suite's convention: a source includes the annex D files it uses.
        .require_std_includes = true,
        // Annex E.2: the fixture's `//! spice` cards, read as a netlist.
        .spice_netlist = d.harness.spice,
        .spice_path = f.path,
        .discipline_resolution = d.harness.discipline_resolution,
    }, &diags) catch |err| {
        if (err == error.OutOfMemory) {
            diags.deinit(gpa);
            return error.OutOfMemory;
        }
        return .{ .refused = .{ .error_name = @errorName(err), .diags = diags } };
    };
    defer result.deinit(gpa);

    if (diags.failed()) {
        return .{ .refused = .{ .error_name = "DiagnosticsReported", .diags = diags } };
    }

    var generated = result.generate(gpa, .{}, &diags) catch |err| {
        if (err == error.OutOfMemory) {
            diags.deinit(gpa);
            return error.OutOfMemory;
        }
        return .{ .refused = .{ .error_name = @errorName(err), .diags = diags } };
    };
    if (diags.failed()) {
        generated.deinit(gpa);
        return .{ .refused = .{ .error_name = "DiagnosticsReported", .diags = diags } };
    }
    // The compiler's own flag, not a text search: a kernel may carry
    // `@compileError` in a guard that never fires (`$table_model`'s does).
    if (generated.refused) {
        // The GPA-owned text moves into the failure, which frees it.
        return .{ .refused = .{
            .error_name = "GeneratedCompileError",
            .diags = diags,
            .generated = generated.output.text,
        } };
    }

    defer generated.deinit(gpa);
    diags.deinit(gpa);
    return .{ .accepted = generated.output.text.len };
}

/// Whether the failure matches a `//! reject` pattern: a code, an error name,
/// `@compileError` text, a diagnostic substring, or a phase label derived from
/// the failure:
///   `DiagnosticsReported`  the failure carries at least one diagnostic.
///   `ParseError`           every diagnostic came from preprocess or parse.
fn failureContains(f: Failure, pattern: []const u8) bool {
    if (asCode(pattern) != null) {
        for (0..f.diags.count()) |i| if (diagSays(&f.diags, i, pattern)) return true;
        return false;
    }
    if (std.mem.find(u8, f.error_name, pattern) != null) return true;
    if (f.generated) |g| if (std.mem.find(u8, g, pattern) != null) return true;

    if (!f.diags.isEmpty()) {
        if (std.mem.eql(u8, pattern, "DiagnosticsReported")) return true;
        if (std.mem.eql(u8, pattern, "ParseError")) {
            for (0..f.diags.count()) |i| switch (f.diags.at(i).stage) {
                .preprocess, .parse => {},
                .lower, .proof, .codegen, .run => return false,
            };
            return true;
        }
    }
    for (0..f.diags.count()) |i| if (diagSays(&f.diags, i, pattern)) return true;
    return false;
}

/// Does diagnostic `i` say `pattern`: its code when `pattern` is one, else a
/// substring of its message, point, catalogue title or a note.
fn diagSays(bag: *const vera.diag.Bag, i: usize, pattern: []const u8) bool {
    const d = bag.at(i);
    if (asCode(pattern)) |want| return d.code == want;
    // The title too: much wording lives in `Info.title`, not the message.
    if (std.mem.find(u8, d.message, pattern) != null) return true;
    if (std.mem.find(u8, d.point, pattern) != null) return true;
    if (std.mem.find(u8, vera.diag.info(d.code).title, pattern) != null) return true;
    var nbuf: [vera.diag.max_children]vera.diag.Note = undefined;
    for (bag.notes(d, &nbuf)) |n| {
        if (std.mem.find(u8, n.text, pattern) != null) return true;
    }
    return false;
}

/// `//! warn`: every pattern names a warning in `bag`. `//! nowarn`: `bag`
/// holds no warning. Detail goes to `w` on a miss.
fn warningsMet(bag: *vera.diag.Bag, f: Fixture, d: tb.Spec, w: *Io.Writer) !bool {
    for (d.harness.warn) |pattern| {
        for (0..bag.count()) |i| {
            if (bag.at(i).severity == .warning and diagSays(bag, i, pattern)) break;
        } else {
            try w.print("FAIL {s}: no warning matches: \"{s}\"\n", .{ f.path, pattern });
            vera.diag.render(bag, w, .{ .explain_hint = false, .summary = false }) catch {};
            return false;
        }
    }
    if (d.harness.nowarn and bag.count() != 0) {
        try w.print("FAIL {s}: `//! nowarn`, and the compile warned:\n", .{f.path});
        vera.diag.render(bag, w, .{ .explain_hint = false, .summary = false }) catch {};
        return false;
    }
    return true;
}

/// A directive is either a CODE (`E0313`, `W0650`) or a message substring.
///
/// Codes are preferred: they are stable and pin which rule fired.
fn asCode(pattern: []const u8) ?vera.diag.Code {
    if (pattern.len != 5) return null;
    if (pattern[0] != 'E' and pattern[0] != 'W') return null;
    for (pattern[1..]) |c| if (!std.ascii.isDigit(c)) return null;
    return std.meta.stringToEnum(vera.diag.Code, pattern);
}

fn printDiags(f: Failure, w: *Io.Writer) !void {
    // Render the real thing, so a failing fixture shows exactly what a user
    // would see — snippet, carets, notes and all. Colour is off: this output is
    // read from a log as often as from a terminal.
    var bag = f.diags;
    vera.diag.render(&bag, w, .{ .explain_hint = false, .summary = false }) catch {};
    // A `@compileError` carries the whole reason; without it
    // "GeneratedCompileError" says nothing about WHICH construct codegen refused.
    if (f.generated) |g| {
        var rest = g;
        while (std.mem.find(u8, rest, "@compileError")) |at| {
            const line_end = std.mem.findScalar(u8, rest[at..], '\n') orelse rest.len - at;
            try w.print("  codegen: {s}\n", .{rest[at .. at + line_end]});
            rest = rest[at + line_end ..];
        }
    }
}

// ---------------------------------------------------------------------------
// The run half: the expected behavior is a transcript the model asserts itself
// ---------------------------------------------------------------------------

fn runAndCheck(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    ctx: *const Ctx,
    f: Fixture,
    source: []const u8,
    d: tb.Spec,
    w: *Io.Writer,
    /// `prepare`'s mode: stage a plain testbench's files here instead of
    /// building and running it (left null for a mixed one).
    stage_into: ?*?zigbuild.Staged,
) !Result {
    const cfg = ctx.cfg;
    // `--perturb`: check.vh moves every want by a relative δ.
    // A define ahead of the text, so the first `include "check.vh"` sees it,
    // and an IEEE 1364 §19.7 `line after it, so the fixture's own §10.7
    // `__LINE__ is not moved down by the define's line.
    const compiled_src = if (harness.perturb) |p| try arena.print("`define VERA_PERTURB {e}\n`line 1 \"{s}\" 0\n{s}", .{ p, f.path, source }) else source;
    // Stages 1-6 with §9.4 display ON. W0650 is about speed, and every fixture
    // that probes a node trips it; allowing it here keeps the transcript about
    // the model rather than about float modes — unless a `//! warn` names it.
    var diags: vera.diag.Bag = .init(gpa);
    defer diags.deinit(gpa);
    var levels: vera.diag.Levels = .empty;
    for (d.harness.warn) |p| {
        if (std.mem.eql(u8, p, "W0650")) break;
    } else try levels.set(.W0650, .allow);

    var opts: vera.Settings = .{
        .file_name = f.path,
        .include_dirs = &.{ f.dir(), harness.include_dir },
        .require_std_includes = true,
        .lint = levels,
        .display = if (d.harness.display_record) .record else .emit,
        .spice_netlist = d.harness.spice,
        .spice_path = f.path,
        .discipline_resolution = d.harness.discipline_resolution,
    };
    var result = vera.analyze(gpa, compiled_src, opts, &diags) catch |err| {
        try w.print("FAIL {s}: did not compile: {t}\n", .{ f.path, err });
        vera.diag.render(&diags, w, .{ .explain_hint = false, .summary = false }) catch {};
        return .unmet;
    };
    defer result.deinit(gpa);
    // §3.4 a `//! param` card value for a shape parameter is a compile-time
    // value: compile again for it, as `vera --emit-exe` does.
    opts.param_overrides = try tb.shapeCards(arena, d.bench.params, result.lowered);
    if (opts.param_overrides.len != 0) {
        diags.deinit(gpa);
        diags = .init(gpa);
        const again = vera.analyze(gpa, compiled_src, opts, &diags) catch |err| {
            try w.print("FAIL {s}: did not compile: {t}\n", .{ f.path, err });
            vera.diag.render(&diags, w, .{ .explain_hint = false, .summary = false }) catch {};
            return .unmet;
        };
        result.deinit(gpa);
        result = again;
    }

    var dev = result.generate(gpa, .{}, &diags) catch |err| {
        try w.print("FAIL {s}: codegen failed: {t}\n", .{ f.path, err });
        return .unmet;
    };
    defer dev.deinit(gpa);
    const device = dev.output.text;
    if (dev.refused) {
        try w.print("FAIL {s}: codegen refused a construct (generated output is not usable)\n", .{f.path});
        return .unmet;
    }
    // An LLVM intrinsic link-fails under `--zig-backend=native`.
    if (std.mem.find(u8, device, "extern fn @\"llvm.") != null) {
        try w.print("FAIL {s}: the device declares an `llvm.*` intrinsic; it cannot build under the self-hosted backend\n", .{f.path});
        return .unmet;
    }
    try tb.warnGridEvents(&diags, result.lowered, result.mir);
    if (!try warningsMet(&diags, f, d, w)) return .unmet;

    // VAMS §7: a module with a discrete half gets the mixed-signal runner.
    var facts = try tb.compileFacts(arena, result.lowered, result.mir);
    facts.validate_contract = true;
    facts.certify = harness.certify and d.harness.fd_exempt == null;
    // L4b: the prover's claim `finiteCheck` tests. Every contribution unit
    // rated `.optimized` (proof.zig `FloatMode`); a device with none claims nothing.
    facts.finite_proved = for (result.verdict.unit_modes) |mode| {
        if (mode != .optimized) break false;
    } else result.verdict.unit_modes.len != 0;
    var runner_text: Io.Writer.Allocating = .init(arena);
    tb.writeRunner(&runner_text.writer, arena, f.stem(), &d.bench, facts) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    const runner = runner_text.written();

    // One work directory per fixture, keyed on the whole relative path: two
    // fixtures may declare the same module name AND share a file name, and a
    // shared scratch would race them onto one `device.zig`.
    const work = try std.fs.path.join(arena, &.{
        options.work_root,
        "torture",
        std.fs.path.basename(f.root),
        f.slug,
    });
    const build_opts: zigbuild.BuildOptions = .{
        .work_dir = work,
        .contract = options.contract,
        .name = result.mir.name,
        .mixed = facts.mixed != null,
        .zig_exe = options.zig_exe,
        .optimize = cfg.fixture_opt,
        .backend = cfg.fixture_backend,
        .strip = true,
    };
    if (stage_into) |s| {
        if (!build_opts.mixed) s.* = try zigbuild.stage(arena, io, device, runner, build_opts);
        return .met;
    }
    const built = (if (ctx.batched.get(f.path)) |b| linkBatched(gpa, io, arena, work, b) else zigbuild.buildExe(gpa, io, device, runner, build_opts)) catch |err| {
        try w.print("FAIL {s}: building the testbench: {t}\n", .{ f.path, err });
        return .unmet;
    };
    defer built.deinit(gpa);
    const bin = switch (built) {
        // Every testbench build failure is an engine bug; there is no excused
        // case. Make a failure impossible before adding an excuse for it.
        .failed => |text| {
            try w.print(
                "FAIL {s}: the generated testbench does not compile — an ENGINE bug:\n{s}\n",
                .{ f.path, text },
            );
            return .unmet;
        },
        .ok => |p| p,
    };

    const got = capture(gpa, io, bin, work, d.harness.expected_exit, d.harness.plusargs) catch |err| {
        try w.print("FAIL {s}: running the testbench: {t}\n", .{ f.path, err });
        return .unmet;
    };
    defer gpa.free(got);

    // THE ASSERTION, and the only one there is.
    const tally = countVerdicts(got);
    if (harness.perturb != null) return perturbed(f, got, w);
    if (d.harness.expected_checks) |expected| {
        if (tally.total != expected) {
            try w.print("FAIL {s}: observed {d} assertion(s), expected exactly {d}\n", .{
                f.path, tally.total, expected,
            });
            return .unmet;
        }
    }
    if (tally.failed != 0) {
        try w.print("FAIL {s}: {d} of {d} assertion(s) reported ok=0:\n", .{
            f.path, tally.failed, tally.total,
        });
        var lines = std.mem.splitScalar(u8, got, '\n');
        while (lines.next()) |line| {
            if (std.mem.find(u8, line, "ok=0") != null) try w.print("    {s}\n", .{line});
        }
        return .unmet;
    }

    // `//! reject-run`: the run refused, by name, and only for the named
    // rules (`reject-only`'s test, on the run's `error[...]` lines).
    for (d.harness.reject_run) |pattern| if (!digital.errorSays(got, &.{pattern}, .any)) {
        try w.print("FAIL {s}: `//! reject-run`: no run-time `error[` line holds \"{s}\":\n{s}\n", .{ f.path, pattern, got });
        return .unmet;
    };
    if (d.harness.reject_run.len != 0 and !digital.errorSays(got, d.harness.reject_run, .every)) {
        try w.print("FAIL {s}: `//! reject-run`, and a second run-time error fired:\n{s}\n", .{ f.path, got });
        return .unmet;
    }

    // A fixture may also report failure in prose — a §9.7.3 severity task, or a
    // computed verdict that is not an `ok=` column. A run-time refusal's run
    // may say FAIL about itself (the mixed runner's "the digital half did not
    // run"); it is judged by its status and `error[` lines above, so only
    // `capture`'s status line counts against it.
    if (std.mem.find(u8, got, if (d.harness.reject_run.len != 0) "FAIL: <testbench" else "FAIL") != null) {
        try w.print("FAIL {s}: the testbench itself reported a failure:\n{s}\n", .{ f.path, got });
        return .unmet;
    }

    // A run-time refusal is its own assertion (`decide` lets it through lint).
    if (tally.total == 0 and d.harness.reject_run.len == 0) {
        try w.print(
            "{s}: compiled and ran, but asserted nothing.\n",
            .{f.path},
        );
        return .unasserted;
    }
    return .met;
}

/// A `--perturb` transcript's verdict: every want was moved, so every check
/// must now print a failing verdict. Each `ok=1` left is LOOSE, named
/// here. The runner's own directive checks (`//! noise`,
/// `acstim`, `acdyn`, `qsite`, `seed`, `limit`, `abstol`) are not the
/// fixture's: check.vh does not move their wants, and whether they can fail
/// is the runner's property (its exact or 1e-12 comparisons, pinned by
/// src/codegen/exe/tb/test.zig and tests/canary), so they are left out.
fn perturbed(f: Fixture, got: []const u8, w: *Io.Writer) !Result {
    var own: Tally = .{ .total = 0, .failed = 0 };
    var runner_checks: usize = 0;
    var lines = std.mem.splitScalar(u8, got, '\n');
    while (lines.next()) |line| {
        const at = std.mem.find(u8, line, "ok=") orelse continue;
        if (directiveCheck(line)) {
            runner_checks += 1;
            continue;
        }
        own.total += 1;
        const rest = line[at + 3 ..];
        if (!(rest.len != 0 and rest[0] == '1' and (rest.len == 1 or std.ascii.isWhitespace(rest[1])))) own.failed += 1;
    }
    if (own.total == 0) return if (runner_checks != 0) .met else .unasserted;
    if (own.failed == own.total) return .met;
    try w.print("FAIL {s}: {d} of {d} check(s) still pass with their want perturbed:\n", .{ f.path, own.total - own.failed, own.total });
    lines = std.mem.splitScalar(u8, got, '\n');
    while (lines.next()) |line| {
        if (directiveCheck(line)) continue;
        const at = std.mem.find(u8, line, "ok=1") orelse continue;
        if (at + 4 == line.len or std.ascii.isWhitespace(line[at + 4])) try w.print("LOOSE {s}: {s}\n", .{ f.path, line });
    }
    return .unmet;
}

/// Whether a verdict line is one the runner prints for a device-table
/// directive (`tb/runner.zig`), not a check the fixture wrote.
fn directiveCheck(line: []const u8) bool {
    const tags = [_][]const u8{ "noise[", "noise count", "acstim[", "acstim count", "acdyn[", "qsite[", "qsite count", "seed[", "limit[", "abstol[", "meta[", "meta count" };
    for (tags) |t| if (std.mem.startsWith(u8, line, t)) return true;
    return false;
}

/// Count the `ok=` verdicts a transcript carries. `ok=1` passes, anything else
/// fails — a malformed verdict is not a pass.
fn countVerdicts(text: []const u8) Tally {
    var t: Tally = .{ .total = 0, .failed = 0 };
    var rest = text;
    while (std.mem.find(u8, rest, "ok=")) |at| {
        rest = rest[at + "ok=".len ..];
        t.total += 1;
        const is_one = rest.len != 0 and rest[0] == '1' and
            (rest.len == 1 or std.ascii.isWhitespace(rest[1]));
        if (!is_one) t.failed += 1;
    }
    return t;
}

/// Stands `<work>/vera-batch-<i>`, a symlink to the batch binary, in for the
/// fixture's own testbench (`zigbuild.batch_argv0`). Gpa-owned path.
fn linkBatched(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, work: []const u8, b: Batched) !zigbuild.BuildResult {
    var dir = try Io.Dir.cwd().openDir(io, work, .{});
    defer dir.close(io);
    const name = try arena.print(zigbuild.batch_argv0 ++ "{d}", .{b.index});
    dir.deleteFile(io, name) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    try dir.symLink(io, b.bin, name, .{});
    return .{ .ok = try std.fs.path.join(gpa, &.{ work, name }) };
}

/// Runs the testbench and returns its stderr, where both `$strobe` output and
/// the residual dump go, in program order. Caller frees with `gpa`.
///
/// The child runs in its own work directory, so §9.5 file I/O resolves in a
/// per-fixture namespace rather than the repository root. `bin` is
/// `<work>/<name>`, so from inside `work` it is `./<name>`.
fn capture(gpa: std.mem.Allocator, io: Io, bin: []const u8, work: []const u8, expected_exit: u8, plusargs: []const []const u8) ![]const u8 {
    var argv0_buf: [std.fs.max_path_bytes]u8 = undefined;
    const argv0 = try std.mem.print(&argv0_buf, "./{s}", .{std.fs.path.basename(bin)});
    const argv = try gpa.alloc([]const u8, 1 + plusargs.len);
    defer gpa.free(argv);
    argv[0] = argv0;
    @memcpy(argv[1..], plusargs);
    const r = try std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .path = work } });
    gpa.free(r.stdout);
    var text: std.ArrayList(u8) = .fromOwnedSlice(r.stderr);
    errdefer text.deinit(gpa);
    // Exit status is part of the oracle, even when earlier assertions passed.
    // Fatal-task fixtures opt into their expected status with `//! exit`.
    switch (r.term) {
        .exited => |c| if (c != expected_exit) {
            var line: [64]u8 = undefined;
            const s = std.mem.print(&line, "FAIL: <testbench exit {d}, expected {d}>\n", .{ c, expected_exit }) catch unreachable;
            try text.appendSlice(gpa, s);
        },
        else => try text.appendSlice(gpa, "FAIL: <testbench did not exit normally>\n"),
    }
    return text.toOwnedSlice(gpa);
}

// Left out of a Windows build: their oracle is POSIX (`/bin/sh`, and a
// child run as `./<name>` from its work directory), and the batch runner
// they test is the suite's, which runs on Linux and macOS.
comptime {
    if (@import("builtin").os.tag != .windows) _ = posix;
}

test "a perturbed run judges the fixture's checks, not the runner's directive tables" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const f: Fixture = .{ .path = "x.va", .root = ".", .slug = "x" };
    // Every own check flipped; a directive check still ok=1 is not LOOSE.
    try std.testing.expectEqual(Result.met, try perturbed(f, "own got=1 want=1.001 ok=0\nnoise[0] got=a want=a ok=1\n", &aw.writer));
    // Only directive checks: the runner's comparisons are what can fail.
    try std.testing.expectEqual(Result.met, try perturbed(f, "limit[0].g got=1 want=1 ok=1\n", &aw.writer));
    try std.testing.expectEqual(Result.unasserted, try perturbed(f, "nothing\n", &aw.writer));
    // An own check that survives is LOOSE, by name.
    try std.testing.expectEqual(Result.unmet, try perturbed(f, "loose got=1 want=1.001 ok=1\n", &aw.writer));
    try std.testing.expect(std.mem.find(u8, aw.written(), "LOOSE x.va: loose") != null);
}

test "verdicts are counted, and a malformed one is not a pass" {
    try std.testing.expectEqual(Tally{ .total = 0, .failed = 0 }, countVerdicts("no verdicts here"));
    try std.testing.expectEqual(Tally{ .total = 2, .failed = 0 }, countVerdicts("a ok=1\nb ok=1\n"));
    try std.testing.expectEqual(Tally{ .total = 2, .failed = 1 }, countVerdicts("a ok=1\nb ok=0\n"));
    try std.testing.expectEqual(Tally{ .total = 1, .failed = 1 }, countVerdicts("a ok=\n"));
    try std.testing.expectEqual(Tally{ .total = 1, .failed = 0 }, countVerdicts("a ok=1"));
    for ([_][]const u8{ "ok=10", "ok=1garbage", "ok=1.0", "ok=-1", "ok=" }) |bad| {
        try std.testing.expectEqual(Tally{ .total = 1, .failed = 1 }, countVerdicts(bad));
    }
}

test "declared check count rejects missing and duplicated observations" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    const source =
        \\`include "disciplines.vams"
        \\module check_count_oracle(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog $strobe("single observation ok=1");
        \\endmodule
    ;
    const fixture: Fixture = .{
        .path = suite.fixture_root ++ "/check_count_oracle.va",
        .root = suite.fixture_root,
        .slug = "harness_check_count_selftest",
    };
    const missing = try runAndCheck(gpa, std.testing.io, arena, &.{ .cfg = &.{} }, fixture, source, .{ .harness = .{ .expected_checks = 2 } }, &report.writer, null);
    try std.testing.expect(missing == .unmet);
    try std.testing.expect(std.mem.find(u8, report.written(), "observed 1 assertion(s), expected exactly 2") != null);
    const complete = try runAndCheck(gpa, std.testing.io, arena, &.{ .cfg = &.{} }, fixture, source, .{ .harness = .{ .expected_checks = 1 } }, &report.writer, null);
    try std.testing.expect(complete == .met);
    const duplicated = try runAndCheck(gpa, std.testing.io, arena, &.{ .cfg = &.{} }, fixture, source, .{
        .bench = .{ .times_s = &.{ 0.0, 1e-9 } },
        .harness = .{ .expected_checks = 1 },
    }, &report.writer, null);
    try std.testing.expect(duplicated == .unmet);
    try std.testing.expect(std.mem.find(u8, report.written(), "observed 2 assertion(s), expected exactly 1") != null);
}

test "a fatal exit after a passing assertion must be explicitly expected" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    const source =
        \\`include "disciplines.vams"
        \\module exit_oracle(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $strobe("before fatal got=1 want=1 ok=1");
        \\    $fatal(1, "intentional exit");
        \\  end
        \\endmodule
    ;
    const fixture: Fixture = .{
        .path = suite.fixture_root ++ "/exit_oracle.va",
        .root = suite.fixture_root,
        .slug = "harness_exit_status_selftest",
    };
    const unexpected = try runAndCheck(gpa, std.testing.io, arena, &.{ .cfg = &.{} }, fixture, source, .{}, &report.writer, null);
    try std.testing.expect(unexpected == .unmet);
    try std.testing.expect(std.mem.find(u8, report.written(), "exit 1, expected 0") != null);
    const expected = try runAndCheck(gpa, std.testing.io, arena, &.{ .cfg = &.{} }, fixture, source, .{ .harness = .{ .expected_exit = 1 } }, &report.writer, null);
    try std.testing.expect(expected == .met);
}

test {
    _ = harness;
}
