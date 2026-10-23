//! `--check`: generated device text in, a `zig build-obj -fno-emit-bin` of it
//! beside the `contract` module out, as a verdict (null, or an exit status
//! with its message on `err`). The messages are user-visible and frozen.
//! No LRM clause: this checks VerA's own output against its own contract.

const std = @import("std");
const Io = std.Io;

/// How long one device's `zig build-obj` gets before it is killed. A check
/// takes well under a second per device, so a child past this is wedged, and
/// an unbounded one is a hang the parent build cannot report.
const check_budget_s = 120;

/// Kills `child` once the budget is up. Returns whether it had to; a cancel
/// (the check finished first) short-circuits the sleep and answers false.
fn killAfter(io: Io, child: *std.process.Child, seconds: i64) bool {
    io.sleep(.fromSeconds(seconds), .awake) catch return false;
    child.kill(io);
    return true;
}

/// `typeCheck`'s root: the contract's checks on, over the device.
const check_root =
    \\pub const vera_validate_contract = true;
    \\comptime {
    \\    @import("contract").validate(@import("device"));
    \\}
    \\
;

/// Runs `zig build-obj -fno-emit-bin` over the generated device with the
/// `contract` module. Returns null when it type-checks, else the exit code,
/// with the reason (naming `in_path`) written on `err`.
///
/// Proves only that the file parses and its `comptime` blocks hold: analysis
/// is lazy and `contract.validate` is reflection, so a type error inside an
/// `eval`/`q` body exits 0 here.
pub fn typeCheck(
    gpa: std.mem.Allocator,
    io: Io,
    err: *Io.Writer,
    zig_exe: []const u8,
    contract: []const u8,
    device_zig: []const u8,
    in_path: []const u8,
) !?u8 {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, ".zig-cache/vera-check");
    var tmp = try cwd.openDir(io, ".zig-cache/vera-check", .{});
    defer tmp.close(io);

    // Every name and argv string lives for this call only.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stem = std.fs.path.stem(in_path);
    const dev_name = try arena.print("{s}.device.zig", .{stem});
    try tmp.writeFile(io, .{ .sub_path = dev_name, .data = device_zig });

    // The device is not the root: the root turns the contract's checks on
    // (`contract.validating`), which `--check` is for.
    const root_name = try arena.print("{s}.check.zig", .{stem});
    try tmp.writeFile(io, .{ .sub_path = root_name, .data = check_root });
    const contract_arg = try arena.print("-Mcontract={s}", .{contract});
    const root_arg = try arena.print("-Mroot=.zig-cache/vera-check/{s}", .{root_name});
    const device_arg = try arena.print("-Mdevice=.zig-cache/vera-check/{s}", .{dev_name});

    // `--dep` applies to the NEXT `-M`, and the FIRST `-M` is the root module —
    // the ordering rule `buildArgv` in orchestrator.zig follows.
    const argv = [_][]const u8{
        zig_exe,       "build-obj",  "-fno-emit-bin",
        "--dep",       "device",     "--dep",
        "contract",    root_arg,     "--dep",
        "contract",    device_arg,   contract_arg,
        "--cache-dir", ".zig-cache",
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });

    // `concurrent`, not `async`: `async` is permitted to run the watchdog
    // inline on this thread, which would sleep out the whole budget before the
    // child was ever read from. An Io that cannot spare a second thread gets
    // an unbounded wait rather than a wrong one.
    var watchdog = io.concurrent(killAfter, .{ io, &child, check_budget_s }) catch null;

    var buf: [1 << 16]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buf);
    var aw: Io.Writer.Allocating = .init(arena);
    _ = reader.interface.streamRemaining(&aw.writer) catch {};

    // Retired BEFORE `wait` reaps, because after the reap this pid belongs to
    // whoever the OS hands it to next and a watchdog still holding it would
    // signal a stranger. `killAfter` reaps what it kills, so the timed-out
    // path must not `wait` again (an assert in Child.wait).
    const timed_out = if (watchdog) |*w| w.cancel(io) else false;
    if (timed_out) {
        try err.print(
            "error: {s}: type check did not finish in {d}s and was killed. " ++
                "The generated Zig is at .zig-cache/vera-check/{s}; run the " ++
                "`zig build-obj` from typeCheck() by hand to see where it sticks.\n",
            .{ in_path, check_budget_s, dev_name },
        );
        return 1;
    }

    const term = try child.wait(io);
    const failed = switch (term) {
        .exited => |c| c != 0,
        else => true,
    };
    if (!failed) return null;

    try err.print(
        "error: {s}: codegen produced Zig that does not compile — this is an engine bug, " ++
            "not a problem with the model:\n",
        .{in_path},
    );
    try err.writeAll(aw.writer.buffered());
    return 1;
}

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

    const good = try typeCheck(gpa, io, &err.writer, "zig", contract, "pub fn eval() void {}\n", "dir/good.va");
    try std.testing.expectEqual(@as(?u8, null), good);
    try std.testing.expectEqual(@as(usize, 0), err.written().len);

    // The contract's own refusal is a failed check, reported on `err` with
    // the compiler's message and the source path.
    try std.testing.expectEqual(@as(?u8, 1), try typeCheck(gpa, io, &err.writer, "zig", contract, "pub const x = 1;\n", "dir/bad.va"));
    try std.testing.expect(std.mem.startsWith(u8, err.written(), "error: dir/bad.va: codegen produced Zig that does not compile"));
    try std.testing.expect(std.mem.find(u8, err.written(), "no eval") != null);
}
