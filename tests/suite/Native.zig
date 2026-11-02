//! `--native`: the same cases through `vera --emit-exe` and the executable it
//! builds. The golden `--run` matches is the oracle, so matching it is matching
//! the interpreter and neither engine runs twice. Every case is also one of
//! three name lists — `NATIVE`, `FALLBACK <reason>` (the executable embeds the
//! interpreter, `rt.interpret`) or `FAIL` — so native coverage is diffed by
//! name, and a fallback that hides a regression shows up as a moved name.
//! A `// native-required` fixture makes that fallback a FAIL in native modes.
//! The forced two-state report keeps its separate x/z refusal policy below.
//!
//!   zig build suite -- ieee1364 --native            # all of IEEE 1364
//!   zig build suite -- ieee1364 --native=static     # combinational logic levelized
//!   zig build suite -- devices --native d04     # the cases whose name has d04
//!   zig build suite -- ieee1364 --native=two-state  # a report, not a gate: see below
//!   zig build suite -- ieee1364 --native=snapshot   # every tick run twice (below)
//!
//! `--snapshot` (after any `--native=`) runs each executable with
//! `--vera-snapshot`: at every tick boundary its state is saved, the tick run
//! quietly, the state restored and the tick run again (`rt/snapshot.zig`).
//! The transcript must still be the golden.
//!
//! `--two-state` makes every x or z 0, so its transcript is not the golden.
//! A case passes when each line that differs shows an x or z digit in the
//! golden; FALLBACK is then every case `--two-state` refuses (E1101).

const Fixtures = @import("Fixtures.zig");
const Child = @import("Child.zig");
const Devices = @import("Devices.zig");
const Digital = @import("Digital.zig");
const std = @import("std");
const options = @import("suite_options");
const harness = Fixtures;
const devices = Devices;
const digital = Digital;
const child = Child;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const NativeJob = struct {
    gpa: Allocator,
    io: Io,
    vera_exe: []const u8,
    flags: []const []const u8,
    snapshot: bool,
    cases: []const []const u8,
    slots: []NativeSlot,
    next: std.atomic.Value(usize) = .init(0),

    fn work(job: *NativeJob) void {
        var arena_state: std.heap.ArenaAllocator = .init(job.gpa);
        defer arena_state.deinit();
        while (true) {
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.cases.len) return;
            _ = arena_state.reset(.retain_capacity);
            var aw: Io.Writer.Allocating = .init(job.gpa);
            const v = nativeVerdict(arena_state.allocator(), job.io, job.vera_exe, job.flags, job.snapshot, job.cases[i], &aw.writer) catch |e| blk: {
                aw.writer.print("FAIL {s}: the runner itself failed: {t}\n", .{ job.cases[i], e }) catch {};
                break :blk NativeVerdict{ .pass = false, .fallback = null };
            };
            var list = aw.toArrayList();
            // The reason is in the arena the next case resets.
            var kept = v;
            if (v.fallback) |why| kept.fallback = job.gpa.dupe(u8, why) catch "?";
            job.slots[i] = .{ .verdict = kept, .output = list.toOwnedSlice(job.gpa) catch "" };
        }
    }
};

/// `fallback` is the executable's reason for embedding the interpreter;
/// `refused` is a case the shared elaboration rejected, so no executable
/// was built at all; `xfail` is an unmet `//! xfail` case, which does not
/// fail the run.
/// `state` is what a `--state=auto` executable ran (`rt.auto`'s
/// `--vera-state` line): 4-state throughout, 2-state after a 4-state
/// start, or that and then a 4-state rerun.
const NativeVerdict = struct { pass: bool, fallback: ?[]const u8, refused: bool = false, xfail: bool = false, state: RunState = .four };
const RunState = enum { four, two, rerun };

/// `nativeCase` under `//! xfail` or an xfail list row, with `digitalVerdict`'s algebra.
fn nativeVerdict(arena: Allocator, io: Io, vera_exe: []const u8, flags: []const []const u8, snapshot: bool, case: []const u8, w: *Io.Writer) !NativeVerdict {
    const xfail = try devices.xfailOf(arena, io, case) orelse
        return nativeCase(arena, io, vera_exe, flags, snapshot, case, w);
    if (xfail.len == 0) {
        try w.print("FAIL {s}: `//! xfail` names no reason\n", .{case});
        return .{ .pass = false, .fallback = null };
    }
    var detail: Io.Writer.Allocating = .init(arena);
    var v = try nativeCase(arena, io, vera_exe, flags, snapshot, case, &detail.writer);
    if (v.pass) {
        try w.print("FAIL {s}: XPASS — marked xfail, but VerA now does what the fixture says.\n" ++
            "  Delete its `//! xfail` line or its row in {s}.\n", .{ case, harness.xfail_list });
        v.pass = false;
        return v;
    }
    try w.print("XFAIL {s}: known: {s}\n", .{ case, xfail });
    v.xfail = true;
    return v;
}
const NativeSlot = struct { verdict: NativeVerdict = .{ .pass = false, .fallback = null }, output: []const u8 = "" };

/// `--native`: every case in `all` matching `filter`, judged on `harness.defaultJobs()`
/// workers, then the NATIVE, FALLBACK, AUTO2 and RERUN name lists and a census on `w`,
/// in case order. Exit 1 on any FAIL or when nothing matched.
pub fn run(gpa: Allocator, io: Io, exe: []const u8, flags: []const []const u8, snapshot: bool, all: []const []const u8, filter: ?[]const u8, w: *Io.Writer) !u8 {
    var picked: std.ArrayList([]const u8) = .empty;
    defer picked.deinit(gpa);
    for (all) |c| if (filter == null or std.mem.find(u8, c, filter.?) != null) try picked.append(gpa, c);
    if (picked.items.len == 0) {
        try w.print("devices: nothing matched `{s}`\n", .{filter orelse ""});
        return 1;
    }
    const slots = try gpa.alloc(NativeSlot, picked.items.len);
    defer gpa.free(slots);
    @memset(slots, .{});
    var job: NativeJob = .{ .gpa = gpa, .io = io, .vera_exe = exe, .flags = flags, .snapshot = snapshot, .cases = picked.items, .slots = slots };
    var group: Io.Group = .init;
    const jobs = harness.defaultJobs();
    var hands: usize = 0;
    while (hands < jobs) : (hands += 1) group.concurrent(io, NativeJob.work, .{&job}) catch break;
    if (hands == 0) job.work();
    try group.await(io);

    var failed: usize = 0;
    var xfailed: usize = 0;
    var fell: usize = 0;
    var refused: usize = 0;
    var twos: usize = 0;
    var reruns: usize = 0;
    for (picked.items, slots) |case, s| {
        try w.writeAll(s.output);
        switch (s.verdict.state) {
            .four => {},
            .two => twos += 1,
            .rerun => reruns += 1,
        }
        if (s.verdict.state != .four) try w.print("AUTO2 {s}\n", .{case});
        if (s.verdict.state == .rerun) try w.print("RERUN {s}\n", .{case});
        if (s.verdict.xfail) {
            xfailed += 1;
        } else if (!s.verdict.pass) failed += 1;
        if (s.verdict.refused) {
            refused += 1;
        } else if (s.verdict.fallback) |why| {
            fell += 1;
            try w.print("FALLBACK {s}: {s}\n", .{ case, why });
        } else if (s.verdict.pass) try w.print("NATIVE {s}\n", .{case});
    }
    try w.print(
        "devices --native: {d}/{d} cases behave as they say they do; {d} native, " ++
            "{d} through the embedded interpreter, {d} refused before any executable",
        .{ picked.items.len - failed - xfailed, picked.items.len, picked.items.len - fell - refused, fell, refused },
    );
    if (xfailed != 0) try w.print("; {d} XFAIL (a known gap, not a pass)", .{xfailed});
    try w.print("; --state=auto turned 2-state in {d} (AUTO2), of which {d} reran 4-state (RERUN)\n", .{ twos + reruns, reruns });
    for (slots) |s| {
        gpa.free(s.output);
        if (s.verdict.fallback) |why| gpa.free(why);
    }
    return if (failed == 0) 0 else 1;
}

/// `digitalCase` through the executable. A rejection may come from `vera
/// --emit-exe` (the shared elaboration) or from the executable at run time;
/// either way its stderr is judged, the build's and the run's together.
fn nativeCase(arena: Allocator, io: Io, vera_exe: []const u8, flags: []const []const u8, snapshot: bool, case: []const u8, w: *Io.Writer) !NativeVerdict {
    const src = try arena.print("{s}/{s}.v", .{ options.fixture_root, case });
    const source = try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(1 << 20));
    const work = try arena.print("native/{s}", .{case});
    try Io.Dir.cwd().createDirPath(io, work);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ vera_exe, "--emit-exe", "--work-dir", work });
    try argv.appendSlice(arena, flags);
    try argv.append(arena, src);
    try argv.appendSlice(arena, try digital.runnerArgs(arena, source, std.fs.path.dirname(src).?));
    const built = try child.capture(arena, io, argv.items);
    const two_state = std.mem.eql(u8, flags[0], "--two-state");
    const fallback: ?[]const u8 = if (std.mem.find(u8, built.stderr, "not native (")) |at| blk: {
        const rest = built.stderr[at + "not native (".len ..];
        break :blk rest[0 .. std.mem.find(u8, rest, ")\n") orelse rest.len];
    } else null;
    const negative = digital.negative(source);
    if (two_state and built.exit != 0) if (std.mem.find(u8, built.stderr, "carries meaning: ")) |at| {
        const rest = built.stderr[at + "carries meaning: ".len ..];
        return .{ .pass = true, .fallback = rest[0 .. std.mem.findScalar(u8, rest, '\n') orelse rest.len] };
    };
    if (built.exit != 0) {
        if (negative and digital.rejectionMatches(source, built.exit, built.stderr)) return .{ .pass = true, .fallback = null, .refused = true };
        try w.print("FAIL {s}: vera --emit-exe exited {d}\n{s}\n", .{ case, built.exit, built.stderr });
        return .{ .pass = false, .fallback = fallback };
    }
    if (!two_state and nativeRequired(source)) if (fallback) |why| {
        try w.print("FAIL {s}: `// native-required` forbids interpreter fallback: {s}\n", .{ case, why });
        return .{ .pass = false, .fallback = fallback };
    };
    const bin = try Io.Dir.cwd().realPathFileAlloc(io, std.mem.trimEnd(u8, built.stdout, "\n"), arena);
    var ran = try child.captureIn(arena, io, if (snapshot) &.{ bin, "--vera-state", "--vera-snapshot" } else &.{ bin, "--vera-state" }, work);
    if (std.mem.find(u8, ran.stderr, "vera-snapshot: ")) |at| {
        const end = std.mem.findScalarPos(u8, ran.stderr, at, '\n') orelse ran.stderr.len;
        ran.stderr = try std.mem.concat(arena, u8, &.{ ran.stderr[0..at], ran.stderr[@min(end + 1, ran.stderr.len)..] });
    }
    var state: RunState = .four;
    if (std.mem.find(u8, ran.stderr, "vera-state: ")) |at| {
        const end = std.mem.findScalarPos(u8, ran.stderr, at, '\n') orelse ran.stderr.len;
        const line = ran.stderr[at..end];
        state = if (std.mem.find(u8, line, "rerun") != null) .rerun else if (std.mem.find(u8, line, "2-state") != null) .two else .four;
        ran.stderr = try std.mem.concat(arena, u8, &.{ ran.stderr[0..at], ran.stderr[@min(end + 1, ran.stderr.len)..] });
    }
    // `// native-state: 2|4|rerun` pins what the default `--state=auto` runs.
    if (flags.len == 1 and !two_state) if (pinnedState(source)) |want| if (want != state) {
        try w.print("FAIL {s}: `--state=auto` ran {t}, the fixture pins {t}\n", .{ case, state, want });
        return .{ .pass = false, .fallback = fallback, .state = state };
    };
    const stderr = try std.mem.concat(arena, u8, &.{ built.stderr, ran.stderr });
    if (negative) {
        if (digital.rejectionMatches(source, ran.exit, stderr)) {
            // A rejection with a transcript (`devices.digitalCase`): the run
            // went on after the error, and printed this.
            const golden = try arena.print("{s}/{s}.expected.txt", .{ options.fixture_root, case });
            const want = Io.Dir.cwd().readFileAlloc(io, golden, arena, .limited(1 << 20)) catch
                return .{ .pass = true, .fallback = fallback, .state = state };
            const same = if (two_state) try twoStateDiff(w, case, want, ran.stdout) else try devices.diff(w, case, want, ran.stdout);
            return .{ .pass = same, .fallback = fallback, .state = state };
        }
        try w.print("FAIL {s}: digital rejection mismatch (exit {d})\n{s}\n", .{ case, ran.exit, stderr });
        return .{ .pass = false, .fallback = fallback, .state = state };
    }
    if (ran.exit != 0) {
        try w.print("FAIL {s}: the executable exited {d}\n{s}\n", .{ case, ran.exit, stderr });
        return .{ .pass = false, .fallback = fallback, .state = state };
    }
    if (!digital.warningsMatch(source, stderr)) {
        try w.print("FAIL {s}: successful digital run has missing warning evidence or error diagnostics\n{s}\n", .{ case, stderr });
        return .{ .pass = false, .fallback = fallback, .state = state };
    }
    if (digital.vcdExpectation(source)) |v| return .{ .pass = try vcdDiff(arena, io, w, case, work, v, two_state), .fallback = fallback, .state = state };
    const want = try Io.Dir.cwd().readFileAlloc(io, try arena.print("{s}/{s}.expected.txt", .{ options.fixture_root, case }), arena, .limited(1 << 20));
    if (two_state) return .{ .pass = try twoStateDiff(w, case, want, ran.stdout), .fallback = fallback, .state = state };
    return .{ .pass = try devices.diff(w, case, want, ran.stdout), .fallback = fallback, .state = state };
}

/// A compiled-runtime regression may require native emission as well as its
/// transcript. This promise applies to normal native modes, not the separate
/// `--two-state` report which deliberately changes x/z semantics.
fn nativeRequired(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), "// native-required")) return true;
    return false;
}

/// A fixture's `// native-state:` line, if it has one.
fn pinnedState(source: []const u8) ?RunState {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        const word = if (std.mem.startsWith(u8, line, "// native-state: ")) line["// native-state: ".len..] else continue;
        if (std.mem.eql(u8, word, "2")) return .two;
        if (std.mem.eql(u8, word, "4")) return .four;
        if (std.mem.eql(u8, word, "rerun")) return .rerun;
    }
    return null;
}

/// A `//! expect vcd` case: the file the executable wrote in `work` against
/// the golden beside the fixture, both normalised (`digital.vcdTokens`).
/// Under `--two-state` a token may differ where the golden's shows an x or z
/// digit, `twoStateDiff`'s rule.
pub fn vcdDiff(arena: Allocator, io: Io, w: *Io.Writer, case: []const u8, work: []const u8, v: digital.VcdExpect, two_state: bool) !bool {
    const got_text = Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ work, v.produced }), arena, .limited(1 << 24)) catch {
        try w.print("FAIL {s}: the executable wrote no `{s}`\n", .{ case, v.produced });
        return false;
    };
    const dir = std.fs.path.dirname(try arena.print("{s}/{s}.v", .{ options.fixture_root, case })).?;
    const want_text = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ dir, v.golden }), arena, .limited(1 << 24));
    const got = try digital.vcdTokens(arena, got_text);
    const want = try digital.vcdTokens(arena, want_text);
    for (0..@max(got.len, want.len)) |i| {
        const g = if (i < got.len) got[i] else "<end of file>";
        const e = if (i < want.len) want[i] else "<end of file>";
        if (std.mem.eql(u8, g, e)) continue;
        if (two_state and std.mem.findAny(u8, e, "xXzZ") != null) continue;
        try w.print("FAIL {s}: VCD token {d} is `{s}`, the golden has `{s}`\n", .{ case, i, g, e });
        return false;
    }
    return true;
}

/// `--native=two-state`'s judgement: every line of `got` that differs from
/// `want` (line by line) differs where `want` shows an x or z digit.
fn twoStateDiff(w: *Io.Writer, case: []const u8, want: []const u8, got: []const u8) !bool {
    var wl = std.mem.splitScalar(u8, want, '\n');
    var gl = std.mem.splitScalar(u8, got, '\n');
    var differ: u32 = 0;
    var line: u32 = 1;
    while (true) : (line += 1) {
        const a = wl.next();
        const b = gl.next();
        if (a == null and b == null) break;
        if (a != null and b != null and std.mem.eql(u8, a.?, b.?)) continue;
        differ += 1;
        if (a != null and hasXz(a.?)) continue;
        try w.print("FAIL {s}: line {d} differs with no x or z in the golden\n  want: {s}\n  got:  {s}\n", .{ case, line, a orelse "(none)", b orelse "(none)" });
        return false;
    }
    if (differ != 0) try w.print("XZ {s}: {d} line(s) differ, each where the golden shows x or z\n", .{ case, differ });
    return true;
}

/// A value token of `line` holds an x or z digit: a run of hex digits,
/// `_`, x and z with at least one x or z (§17.1.1.3).
fn hasXz(line: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, line, " \t=:,;()[]{}'\"/");
    while (it.next()) |t| {
        var xz = false;
        for (t) |c| switch (c) {
            'x', 'X', 'z', 'Z' => xz = true,
            '0'...'9', 'a'...'f', 'A'...'F', '_' => {},
            else => break,
        } else if (xz) return true;
    }
    return false;
}
