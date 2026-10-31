//! Deep stacks: a recursive walk and the nesting depth it will reach in, the
//! walk's result out, computed on a thread whose stack is reserved for that
//! depth. Source nesting (parentheses, operator chains, `begin` blocks,
//! else-if chains, macro arguments, include files) is therefore bounded by
//! memory and the OS thread limit, not by the calling thread's stack (8 MiB
//! on Linux and macOS main threads; an embedder's thread may have less).
//!
//! Cites: no LRM clause bounds nesting.
//!
//! Contents:
//! - `pub const Error = error{DeepStackUnavailable}`
//! - `pub const Segments = struct { frames: u32 = 0, base: u32 = 0 }`
//! - `Segments.due(s: Segments, caller_cap: u32, segment_cap: u32) bool`
//! - `Segments.segment(s: *Segments, levels: usize, comptime func: anytype, args: anytype) Result(@TypeOf(func))`
//! - `pub const message: []const u8`, the refusal's format, one `{d}` for `mib()`
//! - `pub var refuse_for_test: bool`
//! - `pub fn Result(comptime Func: type) type`
//! - `pub fn run(depth_hint: usize, comptime func: anytype, args: anytype) Result(@TypeOf(func))`
//! - `pub fn runGuarded(depth_hint: usize, comptime f: anytype, args: anytype)`, returning what `f` returns
//! - `pub fn exhausted() bool`
//! - `pub fn mib() usize`
//!
//! Two kinds of walk, two entry points:
//!
//! - A walk whose depth a parse measured (`run`). The reservation is
//!   `base_bytes + depth_hint * bytes_per_level`, rounded up to 64 KiB (a
//!   multiple of every page size VerA targets: 4 KiB, 16 KiB on Apple
//!   silicon, and Windows' 64 KiB allocation granularity). A reservation or
//!   spawn that fails is `error.DeepStackUnavailable`; the caller names the
//!   depth in its own diagnostic (E0241 in the parser and later stages, E0119
//!   in the preprocessor). The parser and preprocessor run on segments
//!   (`Segments`): every `segment_levels` levels the next level gets a fresh
//!   `run` while its parent thread waits, so depth costs one blocked thread
//!   per segment. At the parser's 4,096 levels per segment (an 80 MiB
//!   reservation in Debug, 48 MiB in release), 100,000 levels is 25 threads;
//!   macOS's default of 2,048 threads per process (kern.num_taskthreads)
//!   allows about 8 million levels, and Linux's threads-max (tens of
//!   thousands or more) further still.
//! - A walk whose depth no parse measured (`runGuarded`): the digital
//!   engine's expression and statement trees, its instance hierarchy, a
//!   recursive task or function at run time. It runs on the largest stack the
//!   machine allows, halved until a thread starts and run in place when none
//!   does, with `exhausted` checked at each recursive step, so running out is
//!   a named refusal (E1100) and never a crash. On a thread `runGuarded` did
//!   not start (a host's, calling a `.v` contract device) `exhausted` allows
//!   4 MiB.
//!
//! How `std.Thread.spawn`'s `stack_size` behaves per target (Zig 0.18):
//! - Linux without libc: one anonymous `mmap` of the whole size plus a guard
//!   page, `mprotect`ed read/write; pages are committed only as the walk
//!   touches them. Under the default overcommit heuristic a size past RAM +
//!   swap fails with `OutOfMemory`.
//! - Linux with libc, macOS: `pthread_attr_setstacksize`, then libc maps the
//!   stack the same lazy way. macOS refuses a size that is not a page
//!   multiple (Zig asserts on it), hence the 64 KiB rounding.
//! - Windows: `NtCreateThreadEx` with the size as the stack's initial
//!   commit, after a lossy cast to u32. So Windows charges the whole size
//!   against the commit limit (pagefile, not RAM, until touched) and cannot
//!   take 4 GiB or more: `bytesFor` refuses that size instead of letting the
//!   cast shrink it.
//! - Single-threaded builds cannot spawn: every walk runs on the caller's
//!   stack.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// The one failure `run` adds to the walk's own error set: the stack for the
/// requested depth could not be reserved, or the thread not started. Nothing
/// of the walk ran.
pub const Error = error{DeepStackUnavailable};

/// A segmented recursion's bookkeeping (the parser's grammar functions, the
/// preprocessor's `include and macro nesting): `frames` native levels open,
/// and their count `base` when the current stack segment began. The caller
/// counts `frames` up and down around each level; `segment` alone writes
/// `base`. Invariant: `base <= frames`.
pub const Segments = struct {
    frames: u32 = 0,
    base: u32 = 0,

    /// Returns whether the current segment is full: `caller_cap` levels while
    /// no segment has begun (the caller's own stack), `segment_cap` on one.
    /// The next level then runs through `segment`.
    /// Asserts that `base <= frames` and both caps are positive.
    pub fn due(s: Segments, caller_cap: u32, segment_cap: u32) bool {
        assert(s.base <= s.frames);
        assert(caller_cap > 0);
        assert(segment_cap > 0);
        const cap = if (s.base == 0) caller_cap else segment_cap;
        return s.frames - s.base >= cap;
    }

    /// Runs `func(args)` as a new segment that begins at the current level,
    /// on a `run` stack for `levels`, and restores the enclosing segment
    /// after. Fails as `run` does.
    /// Asserts that `base <= frames` on entry and that `func` left `frames`
    /// as it found it.
    pub fn segment(s: *Segments, levels: usize, comptime func: anytype, args: anytype) Result(@TypeOf(func)) {
        assert(s.base <= s.frames);
        const saved = s.base;
        const frames = s.frames;
        s.base = s.frames;
        defer {
            assert(s.frames == frames);
            s.base = saved;
        }
        return run(levels, func, args);
    }
};

/// The refusal past `exhausted`, as a format string whose one argument is
/// `mib()`.
pub const message = "nesting here exhausts the {d} MiB stack VerA reserved for it";

/// Test hook: while set (test builds only), `run` refuses every call as an
/// unreservable stack would, so a caller's diagnostic for it can be tested.
/// A global, not a parameter: the refusal must reach a `run` many calls
/// below the test, on threads the test did not start. Ignored outside tests.
pub var refuse_for_test: bool = false;

/// Stack bytes per nesting level, for the deepest walk measured. Debug
/// frames are several times release frames.
// Measured on x86_64-linux (2026-10-15) as the stack high-water mark over the
// depth, through `vera --lint` and `--emit-zig`, at 4,000 to 100,000 levels of
// a sum chain, parentheses, unary minus, a `?:` chain, nested `begin`, nested
// `if`, an else-if chain and nested concatenation, per level of the parser's
// nesting count (`Parser.deepest`). Worst per level, Debug: 7.2 KB (the sum
// chain, lowering's `context.zig` walk), then 3.9 KB (else-if and nested
// `if`, `lowerStmt`), 2.6 KB (`?:`, `lowerTernary`); the parser's own
// segments peaked at 5.8 KB (nested `begin`). ReleaseFast: 2.7 KB (sum),
// 1.4 KB (else-if), 0.9 KB (`?:`). The 16 KiB and 8 KiB below leave at
// least 2x.
const bytes_per_level: usize = switch (builtin.mode) {
    .Debug => 16 * 1024,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => 8 * 1024,
};

/// Stack every `run` gets before any nesting: twice the 8 MiB main-thread
/// stack the pipeline ran on before, for walks whose frames do not grow with
/// nesting (codegen's buffers, the prover).
const base_bytes: usize = 16 << 20;

/// Depth `run` leaves on the caller's stack: 512 levels of the Debug worst
/// case is 3.7 MB, half the 1,024 levels every caller's stack held while the
/// parser capped nesting there.
const in_place_levels: usize = 512;

/// Every reservation is a multiple of this.
const granule: usize = 64 * 1024;

/// The largest stack one thread can be given on this target.
const platform_max: usize = if (builtin.os.tag == .windows) // os: a comptime constant; every target builds both arms
    std.math.maxInt(u32) & ~@as(usize, granule - 1)
else
    std.math.maxInt(usize) & ~@as(usize, granule - 1);

/// The stack one guarded step may use between two `exhausted` checks.
const margin: usize = 1 << 20;
/// A thread `runGuarded` did not start (a host's, calling a contract device)
/// has an unknown stack: half of the smallest main-thread stack VerA expects
/// (8 MiB on Linux and macOS) below the first check.
const foreign: usize = 4 << 20;
/// The smallest guarded reservation worth a thread; below it the walk runs
/// in place.
const least: usize = 64 << 20;
/// Stack bytes asked for per level of `runGuarded`'s depth hint.
const guarded_per_level: usize = 16 << 10;

comptime {
    assert(std.math.isPowerOfTwo(granule));
    assert(base_bytes % granule == 0);
    assert(foreign > margin);
    assert(least > foreign);
    assert(least > 2 * margin);
    assert(least % granule == 0);
}

/// The lowest frame address this thread's guarded walks may reach, and the
/// stack it was reserved from (for the diagnostic). 0 until `runGuarded`
/// starts the thread, or `exhausted` first runs on a thread it did not start.
threadlocal var floor: usize = 0;
threadlocal var reserved: usize = 0;
/// This thread is one `runGuarded` started.
threadlocal var inside: bool = false;

/// Returns `Func`'s return type with `Error` added to its error set.
pub fn Result(comptime Func: type) type {
    const R = @typeInfo(Func).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| (eu.error_set || Error)!eu.payload,
        else => Error!R,
    };
}

/// Calls `func` with `args` on a fresh thread whose stack holds `depth_hint`
/// nesting levels and returns its result; the calling thread waits. A hint
/// of at most 512 levels calls `func` directly. `depth_hint` counts levels of
/// the walk `bytes_per_level` was measured on; a walk with larger frames per
/// level scales its hint. `func` may touch the caller's state: the caller is
/// blocked until it returns, and the join orders every write before the
/// caller reads.
/// Fails with `error.DeepStackUnavailable`, before any of `func` runs, when
/// the stack cannot be reserved or the thread not started (and on every call
/// while `refuse_for_test` is set in a test build).
// `anytype` as in `std.Thread.spawn`, whose shape this is: the walk and its
// arguments are the caller's.
pub fn run(depth_hint: usize, comptime func: anytype, args: anytype) Result(@TypeOf(func)) {
    if (builtin.single_threaded) return @call(.auto, func, args);
    if (builtin.is_test and refuse_for_test) return error.DeepStackUnavailable;
    // Shallow walks stay on the caller's stack: a thread costs a spawn, cold
    // stack pages and, on a hybrid CPU, maybe a slower core (measured: 1 ms
    // and up to 8% of a `vera --lint` of a compact model when every compile
    // spawned one).
    if (depth_hint <= in_place_levels) return @call(.auto, func, args);
    const size = bytesFor(depth_hint) orelse return error.DeepStackUnavailable;
    assert(size >= base_bytes + in_place_levels * bytes_per_level);
    const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    const Call = struct {
        fn entry(out: *R, a: @TypeOf(args)) void {
            out.* = @call(.auto, func, a);
        }
    };
    // SAFETY: `entry` writes it before `join` returns, and nothing reads it
    // before.
    var out: R = undefined;
    const thread = std.Thread.spawn(.{ .stack_size = size }, Call.entry, .{ &out, args }) catch
        return error.DeepStackUnavailable;
    thread.join();
    return out;
}

/// Calls `f(args...)` on a thread with the largest stack the machine allows
/// (halved until a thread starts), joined before returning; on this thread
/// when it already is one, or when no thread can be started (then
/// `exhausted` gives this thread the foreign 4 MiB budget, so a deep walk is
/// still a refusal and never a crash). `depth_hint` is the deepest nesting
/// the caller measured, 0 when it measured none. Unlike `run` it never fails:
/// the walk itself refuses what does not fit, through `exhausted`.
/// Cost: a recursion that never ends touches the whole reservation (up to a
/// sixteenth of physical memory, at most 16 GiB) before `exhausted` refuses.
pub fn runGuarded(depth_hint: usize, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    if (inside or builtin.single_threaded or builtin.os.tag == .freestanding) return @call(.auto, f, args); // os: a comptime target test; freestanding has no threads
    const Task = struct {
        args: @TypeOf(args),
        size: usize,
        result: R = undefined,

        fn go(t: *@This()) void {
            assert(!inside); // A fresh thread.
            inside = true;
            reserved = t.size;
            floor = @frameAddress() -| (t.size - 2 * margin);
            t.result = @call(.auto, f, t.args);
        }
    };
    var size = largest(depth_hint);
    assert(size >= least);
    // Each failed spawn halves the size, so the loop ends within
    // log2(size / least) + 1 tries.
    const tries_max = std.math.log2(size / least) + 1;
    for (0..tries_max + 1) |_| {
        var task: Task = .{ .args = args, .size = size };
        if (std.Thread.spawn(.{ .stack_size = size }, Task.go, .{&task})) |thread| {
            thread.join();
            return task.result;
        } else |_| {
            if (size / 2 < least) return @call(.auto, f, args);
            size /= 2;
        }
    }
    unreachable; // The halving reached `least` within `tries_max`.
}

/// Returns whether the calling step is within `margin` (1 MiB) of the end of
/// its stack. On a thread `runGuarded` did not start, the first call fixes
/// the floor 4 MiB below itself. Always false on freestanding.
pub fn exhausted() bool {
    if (builtin.os.tag == .freestanding) return false; // os: a comptime target test; freestanding has no stack to bound
    const at = @frameAddress();
    if (floor == 0) {
        reserved = foreign;
        floor = at -| (foreign - margin);
    }
    assert(reserved >= foreign); // `foreign`, or a `runGuarded` size of at least `least`.
    return at < floor;
}

/// Returns the MiB this thread's guarded stack was reserved with: 0 before
/// `runGuarded` or `exhausted` ran on it.
pub fn mib() usize {
    if (reserved == 0) assert(floor == 0);
    return reserved >> 20;
}

// ---- private ----

/// Returns the stack `run` reserves for `depth` levels, or null when that
/// size overflows or passes what this target can give one thread.
fn bytesFor(depth: usize) ?usize {
    const levels = std.math.mul(usize, depth, bytes_per_level) catch return null;
    const raw = std.math.add(usize, levels, base_bytes + granule - 1) catch return null;
    const size = raw & ~(granule - 1);
    assert(size % granule == 0);
    assert(size >= levels + base_bytes);
    return if (size > platform_max) null else size;
}

/// Returns the stack `runGuarded` asks for first: a sixteenth of physical
/// memory, at most 16 GiB, or more when `hint` levels need it, up to all of
/// it. Windows commits a thread's whole stack, and a 32-bit address space has
/// no room: both ask for 256 MiB.
fn largest(hint: usize) usize {
    if (@sizeOf(usize) < 8 or builtin.os.tag == .windows) return 256 << 20; // os: a comptime target test; every target takes one branch
    const total: usize = @intCast(@min(std.process.totalSystemMemory() catch 8 << 30, 1 << 48));
    const want = @max(@min(total / 16, 16 << 30), std.math.mul(usize, hint, guarded_per_level) catch total);
    const size = @max(least, std.mem.alignBackward(usize, @min(want, total), 1 << 20));
    assert(size >= least);
    assert(size <= @max(least, total));
    return size;
}

test "run: a recursion far past the calling thread's stack" {
    const Walk = struct {
        // Recurses `n` levels with a frame of about 1 KiB each, then returns `n`.
        fn recurse(n: usize) error{Odd}!usize {
            var pad: [1024]u8 = undefined;
            pad[n % pad.len] = @truncate(n);
            std.mem.doNotOptimizeAway(&pad);
            if (n == 0) return 0;
            return 1 + try recurse(n - 1);
        }
    };
    // 30,000 levels of 1 KiB frames is about 30 MiB: past the 8 MiB main
    // stack and past `base_bytes`, so the levels' share is what holds it.
    try std.testing.expectEqual(@as(usize, 30_000), try run(30_000, Walk.recurse, .{30_000}));
}

test "run: the walk's own errors and plain results pass through" {
    const TestWalks = struct {
        fn failing(x: u32) error{Odd}!u32 {
            return if (x % 2 == 1) error.Odd else x;
        }

        fn plain(x: u32) u32 {
            return x + 1;
        }
    };
    for ([_]usize{ 1, in_place_levels + 1 }) |hint| {
        try std.testing.expectError(error.Odd, run(hint, TestWalks.failing, .{3}));
        try std.testing.expectEqual(@as(u32, 4), try run(hint, TestWalks.failing, .{4}));
        try std.testing.expectEqual(@as(u32, 8), try run(hint, TestWalks.plain, .{7}));
    }
}

test "run: a depth no stack can hold is DeepStackUnavailable, not a crash" {
    const TestWalks = struct {
        fn failing(x: u32) error{Odd}!u32 {
            return if (x % 2 == 1) error.Odd else x;
        }

        fn plain(x: u32) u32 {
            return x + 1;
        }
    };
    try std.testing.expectEqual(@as(?usize, null), bytesFor(std.math.maxInt(usize)));
    if (builtin.single_threaded) {
        // No thread to reserve: the walk runs in place whatever the hint.
        try std.testing.expectEqual(@as(u32, 2), try run(std.math.maxInt(usize), TestWalks.plain, .{1}));
    } else {
        try std.testing.expectError(error.DeepStackUnavailable, run(std.math.maxInt(usize), TestWalks.plain, .{1}));
        try std.testing.expectError(error.DeepStackUnavailable, run(std.math.maxInt(usize) / bytes_per_level, TestWalks.failing, .{2}));
    }
}

test "bytesFor: base plus levels, rounded to 64 KiB" {
    try std.testing.expectEqual(@as(?usize, base_bytes), bytesFor(0));
    const one = bytesFor(1).?;
    try std.testing.expect(one >= base_bytes + bytes_per_level);
    try std.testing.expectEqual(@as(usize, 0), one % granule);
    // 64 KiB above the base, exactly: 16 KiB (Debug) or 8 KiB of one level, rounded up.
    try std.testing.expectEqual(@as(?usize, base_bytes + granule), bytesFor(1));
}

test "runGuarded reserves a stack deeper than the main thread's, and exhausted stops before its end" {
    const Walk = struct {
        // About 1 KiB of frame per level, so 100000 levels need ~100 MiB:
        // more than any default main-thread stack.
        fn down(n: u32) error{Exhausted}!u32 {
            var pad: [1024]u8 = undefined;
            pad[n % pad.len] = @truncate(n);
            std.mem.doNotOptimizeAway(&pad);
            if (exhausted()) return error.Exhausted;
            if (n == 0) return 0;
            return 1 + try down(n - 1);
        }
        fn forever(n: u32) error{Exhausted}!u32 {
            var pad: [1024]u8 = undefined;
            std.mem.doNotOptimizeAway(&pad);
            if (exhausted()) return error.Exhausted;
            return 1 + try forever(n + 1);
        }
        // A thread VerA did not start: `exhausted` gives it the foreign
        // budget, so a walk that never ends is refused within 4 MiB.
        fn host(out: *(error{Exhausted}!u32)) void {
            out.* = forever(0);
        }
    };
    if (builtin.single_threaded) {
        // In place, on the foreign budget: refused, not crashed.
        try std.testing.expectError(error.Exhausted, runGuarded(0, Walk.down, .{@as(u32, 100000)}));
        return;
    }
    // A machine whose `largest(0)` cannot hold 100 MiB fails here: it cannot
    // run the digital engine's deep fixtures either.
    try std.testing.expectEqual(@as(u32, 100000), try runGuarded(0, Walk.down, .{@as(u32, 100000)}));
    var got: error{Exhausted}!u32 = 0;
    const t = try std.Thread.spawn(.{ .stack_size = 16 << 20 }, Walk.host, .{&got});
    t.join();
    try std.testing.expectError(error.Exhausted, got);
}

test "Segments: the caller's cap until a segment begins, the segment's on one, restored after" {
    const Walk = struct {
        fn inner(s: *Segments) bool {
            // Two levels into the segment begun at level 5.
            s.frames += 2;
            defer s.frames -= 2;
            return s.due(100, 2) and !s.due(100, 3);
        }
    };
    var s: Segments = .{ .frames = 4 };
    try std.testing.expect(!s.due(5, 1)); // 4 levels of the caller's 5
    s.frames = 5;
    try std.testing.expect(s.due(5, 1));
    try std.testing.expect(try s.segment(1, Walk.inner, .{&s}));
    try std.testing.expectEqual(Segments{ .frames = 5, .base = 0 }, s);
}

test "runGuarded: a nested call runs in place, on the thread and stack already reserved" {
    const Walk = struct {
        fn outer() [2]std.Thread.Id {
            return .{ std.Thread.getCurrentId(), runGuarded(0, inner, .{}) };
        }
        fn inner() std.Thread.Id {
            return std.Thread.getCurrentId();
        }
    };
    const ids = runGuarded(0, Walk.outer, .{});
    try std.testing.expectEqual(ids[0], ids[1]);
    // A thread of its own, unless the build has none.
    try std.testing.expectEqual(!builtin.single_threaded, ids[0] != std.Thread.getCurrentId());
    // A hint past all memory asks for all of it, never more.
    try std.testing.expect(largest(std.math.maxInt(usize)) <= @max(least, @min(std.process.totalSystemMemory() catch 8 << 30, 1 << 48)));
}
