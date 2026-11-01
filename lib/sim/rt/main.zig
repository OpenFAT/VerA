//! The executable's `main`: a `Design` and its dispatch functions in, the
//! process exit status out, after the transcript on stdout and diagnostics
//! on stderr. The phases of `--state=auto`, `--vera-snapshot` and the
//! interpreter fallback (`interpret`) start here.
//! Cites: IEEE 1364-2005 §11 (the run to completion), §18.3.6.1 (the last step).
//!
//! Contents:
//! - `pub fn interpret(init: std.process.Init, opts: digital.Options, source: []const u8) u8`
//! - `pub fn auto(init_: std.process.Init, d: *const Design, units: i32, comptime four: Dispatch, comptime two_: Dispatch) u8`
//! - `pub fn main(init_: std.process.Init, d: *const Design, units: i32, comptime four: Dispatch) u8`
//! - `pub fn loop(s: *State, four: anytype, comptime two_: ?Dispatch, limit: u64) ?Error`

const std = @import("std");
const assert = std.debug.assert;
const diag = @import("diag");
const deep = @import("base").deep_stack;
const digital = @import("../digital/root.zig");
const State = @import("State.zig");
const design = @import("design.zig");
const engine = @import("engine.zig");
const evcd = @import("evcd.zig");
const snapshot = @import("snapshot.zig");
const Design = design.Design;
const Dispatch = design.Dispatch;
const Error = design.Error;
const prebuilt = design.prebuilt;

/// Runs `source` through the interpreter, exactly `vera --run`: the
/// executable of a design `src/codegen/digital/` did not make native. Prints
/// the transcript on stdout and diagnostics on stderr; returns `vera --run`'s
/// exit status. The names in `opts` resolve against the working directory.
/// Asserts that `source` (which `vera` embedded) fits u32 byte offsets and
/// `opts` asks for no mixed-signal run.
pub fn interpret(init: std.process.Init, opts: digital.Options, source: []const u8) u8 {
    assert(source.len < std.math.maxInt(u32)); // `digital.run`'s, paired.
    assert(opts.mixed == null);
    return deep.runGuarded(0, interpretDeep, .{ init, opts, source });
}

/// The `main` of a `--state=auto` executable: `four` (`Phase(false)`)
/// until a time step begins with no live x or z (`State.boundary`), `two`
/// (`Phase(true)`) after. A store of an x or z in the 2-state phase
/// (`error.Rerun`) runs the design again from time 0, all 4-state; the
/// transcript up to that store was the 4-state one already, so only the
/// rerun's output past it is printed. Run with the argument
/// `--vera-state`, it says which ran in one `vera-state:` line on stderr.
/// Asserts that `units` is a §19.8 exponent (s down to fs).
pub fn auto(init_: std.process.Init, d: *const Design, units: i32, comptime four: Dispatch, comptime two_: Dispatch) u8 {
    assert(units <= 2);
    assert(units >= -15);
    return deep.runGuarded(0, struct {
        fn go(i: std.process.Init, dd: *const Design, u: i32) u8 {
            assert(u <= 2); // `auto`'s, across the deep-stack call.
            assert(u >= -15);
            return autoDeep(i, dd, u, four, two_);
        }
    }.go, .{ init_, d, units });
}

/// The `main` of a 4-state or `--two-state` executable. Asserts that
/// `units` is a §19.8 exponent (s down to fs).
pub fn main(init_: std.process.Init, d: *const Design, units: i32, comptime four: Dispatch) u8 {
    assert(units <= 2);
    assert(units >= -15);
    return deep.runGuarded(0, struct {
        fn go(i: std.process.Init, dd: *const Design, u: i32) u8 {
            assert(u <= 2); // `main`'s, across the deep-stack call.
            assert(u >= -15);
            var s: State = undefined;
            s.init(i, dd, u) catch |e| return s.exit(e);
            return s.exit(run(i, &s, four, null));
        }
    }.go, .{ init_, d, units });
}

/// Dispatches every event of `s` at a tick up to `limit` in its phase;
/// returns how the run ended, null also when the next event is past `limit`.
/// `four` is a `Dispatch`, or in the prebuilt engine an `engine.DispatchC`.
/// Asserts that `limit` is not behind the clock.
pub fn loop(s: *State, four: anytype, comptime two_: ?Dispatch, limit: u64) ?Error {
    // Every caller passes a tick at or after `now` (`peekTime`, `@max`).
    assert(s.sched.now <= limit);
    if (prebuilt) return engine.loop(s, four, two_, limit);
    // ponytail: unbounded on purpose; `State.next` counts the events of a
    // step against its budget and the scheduler runs dry or stops.
    while (true) {
        const pc = (@call(.always_inline, State.next, .{ s, limit }) catch |e| return e) orelse return null;
        assert(s.sched.now <= limit); // `next` dispatches nothing past it.
        (if (two_ != null and s.two) two_.?(s, pc) else if (@TypeOf(four) == engine.DispatchC) engine.call(four, s, pc) else four(s, pc)) catch |e| return e;
    }
}

// ---- private ----

fn interpretDeep(init: std.process.Init, opts: digital.Options, source: []const u8) u8 {
    assert(opts.mixed == null);
    const io = init.io;
    var out_buf: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var err_buf: [1 << 12]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &err_buf);
    defer stderr.interface.flush() catch {};
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    var run_opts = opts;
    run_opts.io = io;
    // An error that did not end the run still fails it, as in `vera --run`
    // (`cli/digital.zig`, #65); §17.2.9's terminated load is a warning,
    // W1157 (VD-134).
    const code: u8 = if (digital.run(arena, source, run_opts, &bag, &stdout.interface)) @intFromBool(bag.failed()) else |e| blk: {
        if (e != error.DigitalFailed) stderr.interface.print("error: digital execution failed: {t}\n", .{e}) catch {};
        break :blk 1;
    };
    stdout.interface.flush() catch return 1;
    if (!bag.isEmpty()) diag.render(&bag, &stderr.interface, .{}) catch {};
    assert(code <= 1); // `vera --run`'s statuses.
    return code;
}

fn autoDeep(init_: std.process.Init, d: *const Design, units: i32, comptime four: Dispatch, comptime two_: Dispatch) u8 {
    assert(d.v.len == d.x.len);
    var s: State = undefined;
    s.init(init_, d, units) catch |e| return s.exit(e);
    s.live = s.gpa.alloc(u64, d.x.len) catch |e| return s.exit(e);
    @memset(s.live, std.math.maxInt(u64));
    for (d.dead) |w| {
        assert(w[0] + w[1] <= d.x.len); // A dead run is words of the planes.
        @memset(s.live[w[0]..][0..w[1]], 0);
    }
    const failed = run(init_, &s, four, two_);
    if (failed == null or failed.? != error.Rerun) {
        if (s.two) report(init_, "vera-state: 2-state from tick {d}\n", .{s.two_at}) else report(init_, "vera-state: 4-state\n", .{});
        return s.exit(failed);
    }
    report(init_, "vera-state: 2-state from tick {d}, rerun 4-state at tick {d}\n", .{ s.two_at, s.budget_time });
    s.out.flush() catch return 1;
    const printed = s.buffers.stdout.pos;
    var r: State = undefined;
    r.init(init_, d, units) catch |e| return r.exit(e);
    // ponytail: the rerun's whole transcript in memory; a writer that drops
    // the first `printed` bytes if a transcript outgrows it.
    var mem: std.Io.Writer.Allocating = .init(r.gpa);
    r.buffers.sink = &mem.writer;
    r.out = r.buffers.sink;
    const again = run(init_, &r, four, null);
    const code = r.exit(again);
    const text = mem.written();
    s.out.writeAll(text[@min(printed, text.len)..]) catch return 1;
    s.out.flush() catch return 1;
    return code;
}

/// `loop` over the whole run. With the argument `--vera-snapshot`, every
/// tick runs twice (`snapshot.twice`) and one `vera-snapshot:` line on
/// stderr says how many ticks and the largest boundary in bytes.
fn run(init_: std.process.Init, s: *State, comptime four: Dispatch, comptime two_: ?Dispatch) ?Error {
    assert(s.sched.now == 0); // Straight after `State.init`.
    assert(!s.quiet);
    const failed = if (!asked(init_, "--vera-snapshot")) loop(s, four, two_, std.math.maxInt(u64)) else blk: {
        var stats: snapshot.Stats = .{};
        const failed = snapshot.twice(s, four, two_, &stats);
        stderrLine(init_, "vera-snapshot: {d} ticks, boundary at most {d} bytes\n", .{ stats.ticks, stats.bytes });
        break :blk failed;
    };
    // §18.3.6.1: the extended dump's last step, then `$vcdclose`.
    if (failed != null) return failed;
    evcd.close(s, s.sched.now) catch |e| return e;
    return null;
}

/// Whether the executable was run with the argument `flag`.
fn asked(init_: std.process.Init, flag: []const u8) bool {
    assert(std.mem.startsWith(u8, flag, "--vera-")); // The runtime's own flags.
    assert(flag.len > "--vera-".len);
    var args = init_.minimal.args.iterateAllocator(init_.gpa) catch return false;
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

fn report(init_: std.process.Init, comptime f: []const u8, values: anytype) void {
    comptime assert(std.mem.startsWith(u8, f, "vera-state: "));
    comptime assert(f[f.len - 1] == '\n');
    if (asked(init_, "--vera-state")) stderrLine(init_, f, values);
}

/// One line on stderr.
fn stderrLine(init_: std.process.Init, comptime f: []const u8, values: anytype) void {
    comptime assert(std.mem.startsWith(u8, f, "vera-"));
    comptime assert(f[f.len - 1] == '\n'); // One line.
    var buf: [128]u8 = undefined;
    var e = std.Io.File.stderr().writerStreaming(init_.io, &buf);
    e.interface.print(f, values) catch {};
    e.interface.flush() catch {};
}
