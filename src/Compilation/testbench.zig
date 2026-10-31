//! `--emit-exe`/`--run` of a `.va`: an analysed source, its device text and
//! the `//!` directives in, the path of a built testbench executable out
//! (`Outcome.exe`, with its plusargs). The runner drives the device over the
//! operating points the directives declare; a module with a discrete half
//! gets the mixed-signal runner (VAMS §7, §8).
//!
//! Cites: IEEE 1364-2005 §17.10 (plusargs); VAMS §7, §8 (the mixed runner).
//!
//! Contents:
//! - `pub fn build(gpa: Allocator, io: Io, arena: Allocator, req: Request, x: Request.Exe, bench: exe.Directives, result: *const Result, device: []const u8, bag: *diag.Bag, err: *Io.Writer, o: *Outcome) request.CompileError!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const diag = @import("diag");
const exe = @import("exe");
const request = @import("request.zig");
const Request = request.Request;
const Outcome = request.Outcome;
const Result = @import("Result.zig");

/// Renders the runner and builds it beside `device` under
/// `req.build.work_dir` (default `.zig-cache/vera-tb`). A runner diagnostic
/// (`exe.warnGridEvents`) that `--deny` made an error refuses before any
/// build; a sweep past `exe.max_points` is status 2; a runner that does not
/// compile is an engine bug, reported with `zig`'s text, status 1.
/// Asserts that `req.build.contract` is set and that `device` is not empty.
pub fn build(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    req: Request,
    x: Request.Exe,
    bench: exe.Directives,
    result: *const Result,
    device: []const u8,
    bag: *diag.Bag,
    err: *Io.Writer,
    o: *Outcome,
) request.CompileError!void {
    assert(req.build.contract != null);
    assert(device.len != 0);
    const b = req.build;
    const in_path = req.options.file_name;
    var d = bench;
    d.mixed = exe.mixedPlan(result.lowered, result.mir);
    // `exe.Error` is the module's one set; `opStates` only allocates.
    d.op_states = exe.opStates(arena, result.lowered) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    d.mem_bytes = exe.memBytes(result.lowered);
    d.validate_contract = x.validate_contract;
    try exe.warnGridEvents(bag, result.lowered, result.mir);
    // Runner diagnostics obey --deny/--forbid before an artifact is built or
    // its simulation starts, as compiler diagnostics do.
    if (bag.failed()) return o.done(1);
    const runner = exe.renderRunner(arena, std.fs.path.stem(in_path), d) catch |e| switch (e) {
        error.TooManyPoints => {
            try err.print("error: {s}: `//!` directive: the sweeps expand to more than {d} points\n", .{ in_path, exe.max_points });
            return o.done(2);
        },
        error.OutOfMemory => return error.OutOfMemory,
        // `exe.Error`'s directive errors come from `exe.parse`, never a render.
        else => unreachable,
    };
    const built = exe.buildExe(gpa, io, device, runner, .{
        .work_dir = b.work_dir orelse ".zig-cache/vera-tb",
        .contract = b.contract.?,
        .name = result.mir.name,
        .out_path = req.out_path,
        .zig_exe = b.zig_exe,
        .mixed = d.mixed != null,
        .optimize = b.optimize,
        .backend = b.backend,
        .debug_info = b.debug_info,
    }) catch |e| {
        try err.print("error: {s}: building the testbench failed: {t}\n", .{ in_path, e });
        return o.done(1);
    };
    defer built.deinit(gpa);
    switch (built) {
        .failed => |text| {
            try err.print("error: {s}: the generated testbench does not compile — this is an engine bug, not a problem with the model:\n", .{in_path});
            try err.writeAll(text);
            return o.done(1);
        },
        .ok => |p| {
            o.exe = try arena.dupe(u8, p);
            o.plusargs = bench.plusargs;
        },
    }
    assert(o.status == 0);
}
