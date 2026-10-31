//! `--emit-exe`/`--run` of a `.va`: an analysed source, its device text and
//! the `//!` directives in, the path of a built testbench executable out
//! (`Outcome.exe`, with its plusargs). The runner drives the device over the
//! operating points the directives declare; a module with a discrete half
//! gets the mixed-signal runner (VAMS §7, §8).
//!
//! Cites: IEEE 1364-2005 §17.10 (plusargs); VAMS §7, §8 (the mixed runner).
//!
//! Contents:
//! - `pub fn build(gpa: Allocator, io: Io, arena: Allocator, req: Request, x: Request.Exe, spec: *const exe.Spec, result: *const Result, device: []const u8, bag: *diag.Bag, err: *Io.Writer, o: *Outcome) request.CompileError!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const diag = @import("diag");
const exe = @import("exe");
const zigbuild = @import("zigbuild");
const request = @import("request.zig");
const Request = request.Request;
const Outcome = request.Outcome;
const Result = @import("Result.zig");

/// Renders the runner and builds it beside `device` under
/// `req.build.work_dir` (default `.zig-cache/vera-tb`). A runner diagnostic
/// (`exe.warnGridEvents`) that `--deny` made an error refuses before any
/// build; a sweep past `exe.points_max` is status 2; a runner that does not
/// compile is an engine bug, reported with `zig`'s text, status 1.
/// Asserts that `req.build.contract` is set and that `device` is not empty.
pub fn build(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    req: Request,
    x: Request.Exe,
    spec: *const exe.Spec,
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
    var facts = try exe.compileFacts(arena, result.lowered, result.mir);
    facts.validate_contract = x.validate_contract;
    try exe.warnGridEvents(bag, result.lowered, result.mir);
    // Runner diagnostics obey --deny/--forbid before an artifact is built or
    // its simulation starts, as compiler diagnostics do.
    if (bag.failed()) return o.done(1);
    var aw: Io.Writer.Allocating = .init(arena);
    exe.writeRunner(&aw.writer, arena, std.fs.path.stem(in_path), &spec.bench, facts) catch |e| switch (e) {
        error.TooManyPoints => {
            try err.print("error: {s}: `//!` directive: the sweeps expand to more than {d} points\n", .{ in_path, exe.points_max });
            return o.done(2);
        },
        // `Allocating` reports its own allocation failure as `WriteFailed`.
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    const built = zigbuild.buildExe(gpa, io, device, aw.written(), .{
        .work_dir = b.work_dir orelse ".zig-cache/vera-tb",
        .contract = b.contract.?,
        .name = result.mir.name,
        .out_path = req.out_path,
        .zig_exe = b.zig_exe,
        .mixed = facts.mixed != null,
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
            o.plusargs = spec.harness.plusargs;
        },
    }
    assert(o.status == 0);
}
