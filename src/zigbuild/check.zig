//! `--check`: generated device text in, a `zig build-obj -fno-emit-bin` of it
//! beside the `contract` module out, as a verdict, with the compiler's message
//! on the caller's writer when it fails. The messages are user-visible and
//! frozen. Cites no LRM clause: this checks VerA's own output against its own
//! contract.
//!
//! Contents:
//! - `pub const Check = struct { zig_exe, contract, device, source_path }`
//! - `pub const Verdict = enum { compiles, fails }`
//! - `pub const CheckError`
//! - `pub fn typeCheck(gpa: Allocator, io: Io, check: Check, err: *Io.Writer) CheckError!Verdict`

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// What `typeCheck` checks. Strings are borrowed for the call.
pub const Check = struct {
    /// The compiler to spawn; looked up on `PATH` when bare.
    zig_exe: []const u8 = "zig",
    /// Root of the `contract` module.
    contract: []const u8,
    /// The generated device text.
    device: []const u8,
    /// The source the device came from: named in every message, and its stem
    /// names the files under `.zig-cache/vera-check`.
    source_path: []const u8,
};

/// Whether the device type-checks against the contract.
pub const Verdict = enum { compiles, fails };

/// Every way `typeCheck` fails short of a verdict: the scratch files could
/// not be written, `zig` could not be run or reaped, or `err` could not take
/// the message (std's names). The scratch files stay.
pub const CheckError = Allocator.Error || Io.Dir.CreateDirPathError || Io.Dir.OpenError ||
    Io.Dir.WriteFileError || std.process.SpawnError || std.process.Child.WaitError || Io.Writer.Error;

/// How long one device's `zig build-obj` gets before it is killed. A check
/// takes well under a second per device, so a child past this is wedged, and
/// an unbounded one is a hang the parent build cannot report.
const check_budget_s = 120;

/// The check's root: the contract's checks on, over the device.
const check_root =
    \\pub const vera_validate_contract = true;
    \\comptime {
    \\    @import("contract").validate(@import("device"));
    \\}
    \\
;

/// The scratch directory, relative to the process cwd.
const scratch_dir = ".zig-cache/vera-check";

/// Runs `zig build-obj -fno-emit-bin` over the device with the `contract`
/// module, rooted at a file that turns the contract's checks on
/// (`contract.validating`). Returns `.compiles`, or `.fails` with the reason
/// (naming `check.source_path`) written on `err`: the compiler's own
/// message, or a note that it ran past `check_budget_s` and was killed.
///
/// Proves only that the file parses and its `comptime` blocks hold: analysis
/// is lazy and `contract.validate` is reflection, so a type error inside an
/// `eval`/`q` body passes here. Fails as `CheckError` says. Asserts that
/// `check.source_path` is not empty.
pub fn typeCheck(gpa: Allocator, io: Io, check: Check, err: *Io.Writer) CheckError!Verdict {
    assert(check.source_path.len > 0);
    assert(check.contract.len > 0);
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, scratch_dir);
    var tmp = try cwd.openDir(io, scratch_dir, .{});
    defer tmp.close(io);

    // Every name and argv string lives for this call only.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stem = std.fs.path.stem(check.source_path);
    const dev_name = try arena.print("{s}.device.zig", .{stem});
    try tmp.writeFile(io, .{ .sub_path = dev_name, .data = check.device });
    const root_name = try arena.print("{s}.check.zig", .{stem});
    try tmp.writeFile(io, .{ .sub_path = root_name, .data = check_root });

    // `--dep` applies to the NEXT `-M`, and the FIRST `-M` is the root
    // module, as in argv.zig.
    const argv = [_][]const u8{
        check.zig_exe, "build-obj",                                                        "-fno-emit-bin",
        "--dep",       "device",                                                           "--dep",
        "contract",    try arena.print("-Mroot=" ++ scratch_dir ++ "/{s}", .{root_name}),  "--dep",
        "contract",    try arena.print("-Mdevice=" ++ scratch_dir ++ "/{s}", .{dev_name}), try arena.print("-Mcontract={s}", .{check.contract}),
        "--cache-dir", ".zig-cache",
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });

    // `concurrent`, not `async`: `async` may run the watchdog inline on this
    // thread, which would sleep out the whole budget before the child was
    // ever read from. An Io that cannot spare a second thread gets an
    // unbounded wait rather than a wrong one.
    var watchdog = io.concurrent(killAfter, .{ io, &child, check_budget_s }) catch null;

    // SAFETY: the reader writes each byte before it reads it back.
    var buf: [1 << 16]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buf);
    var aw: Io.Writer.Allocating = .init(arena);
    _ = reader.interface.streamRemaining(&aw.writer) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        // A broken pipe ends the message early; the exit status still decides.
        error.ReadFailed => 0,
    };

    // Retired BEFORE `wait` reaps, because after the reap this pid belongs to
    // whoever the OS hands it to next and a watchdog still holding it would
    // signal a stranger. `killAfter` reaps what it kills, so the timed-out
    // path must not `wait` again (an assert in Child.wait).
    const timed_out = if (watchdog) |*w| w.cancel(io) else false;
    if (timed_out) {
        try err.print(
            "error: {s}: type check did not finish in {d}s and was killed. " ++
                "The generated Zig is at " ++ scratch_dir ++ "/{s}; run the " ++
                "`zig build-obj` from typeCheck() by hand to see where it sticks.\n",
            .{ check.source_path, check_budget_s, dev_name },
        );
        return .fails;
    }

    const term = try child.wait(io);
    const failed = switch (term) {
        .exited => |c| c != 0,
        else => true,
    };
    if (!failed) return .compiles;

    try err.print(
        "error: {s}: codegen produced Zig that does not compile — this is an engine bug, " ++
            "not a problem with the model:\n",
        .{check.source_path},
    );
    try err.writeAll(aw.writer.buffered());
    return .fails;
}

// ---- private ----

/// Kills `child` once the budget is up and returns whether it had to; a
/// cancel (the check finished first) ends the sleep and answers false.
fn killAfter(io: Io, child: *std.process.Child, seconds: i64) bool {
    assert(seconds > 0);
    io.sleep(.fromSeconds(seconds), .awake) catch |e| {
        assert(e == error.Canceled);
        return false;
    };
    child.kill(io);
    return true;
}

// The oracle is `zig` itself over a stand-in contract whose `validate`
// refuses a device without `eval`, and the frozen message text.

test typeCheck {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const contract = try gpa.print(".zig-cache/tmp/{s}/contract.zig", .{tmp.sub_path});
    defer gpa.free(contract);
    // `validate` runs only when the root turns it on, which `check_root` does.
    try tmp.dir.writeFile(io, .{ .sub_path = "contract.zig", .data =
        \\pub fn validate(comptime D: type) void {
        \\    if (!@import("root").vera_validate_contract) @compileError("off");
        \\    if (!@hasDecl(D, "eval")) @compileError("no eval");
        \\}
        \\
    });
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    const good = try typeCheck(gpa, io, .{ .contract = contract, .device = "pub fn eval() void {}\n", .source_path = "dir/good.va" }, &err.writer);
    try std.testing.expectEqual(Verdict.compiles, good);
    try std.testing.expectEqual(@as(usize, 0), err.written().len);

    // The contract's own refusal is a failed check, reported on `err` with
    // the compiler's message and the source path.
    const bad = try typeCheck(gpa, io, .{ .contract = contract, .device = "pub const x = 1;\n", .source_path = "dir/bad.va" }, &err.writer);
    try std.testing.expectEqual(Verdict.fails, bad);
    try std.testing.expect(std.mem.startsWith(u8, err.written(), "error: dir/bad.va: codegen produced Zig that does not compile"));
    try std.testing.expect(std.mem.find(u8, err.written(), "no eval") != null);
}
