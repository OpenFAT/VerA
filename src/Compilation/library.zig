//! `--emit-so` and `--emit-osdi` of a `.va`: a generated device in, a
//! versioned shared library `lib<name>.1.so` under the work directory out
//! (`Outcome.path`); `--emit-osdi` builds it under the OSDI dyn and copies it
//! to `-o` or `<module>.osdi`. The host owns loading it and every simulation
//! state. A library whose device does not compile is checked again by
//! `zigbuild.typeCheck`, so an engine bug names the `.va`.
//!
//! Cites: none of the LRM's; OSDI 0.4 (`lib/osdi_dyn.zig`).
//!
//! Contents:
//! - `pub fn build(gpa: Allocator, io: Io, arena: Allocator, req: Request, result: *const Result, device: Output, err: *Io.Writer, o: *Outcome) request.CompileError!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zigbuild = @import("zigbuild");
const Output = @import("device").codegen.Output;
const request = @import("request.zig");
const Request = request.Request;
const Outcome = request.Outcome;
const Result = @import("Result.zig");

/// Builds `device` cold into a library and sets `o.path`, or sets
/// `o.status` with the reason on `err`: 2 for a missing `--work-dir` (not
/// needed under `osdi`) or `--dyn`, 1 for a failed build or copy.
/// Asserts that `req.so` is set, and `req.build.contract` once the build runs.
pub fn build(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    req: Request,
    result: *const Result,
    device: Output,
    err: *Io.Writer,
    o: *Outcome,
) request.CompileError!void {
    assert(req.so);
    assert(o.status == 0);
    const b = req.build;
    const in_path = req.options.file_name;
    const wd = b.work_dir orelse if (req.osdi) ".zig-cache/vera-tb" else {
        try err.writeAll("error: --emit-so needs --work-dir DIR\n");
        return o.done(2);
    };
    const dyn = b.dyn orelse {
        try err.writeAll("error: --emit-so needs --dyn PATH\n");
        return o.done(2);
    };
    assert(b.contract != null); // Past the refusals a `--emit-so` line can reach.
    const modules = [_]zigbuild.Module{
        .{ .name = "contract", .root = b.contract.? },
        .{ .name = "dyn", .root = dyn, .deps = &.{"contract"} },
    };
    var r = zigbuild.compileRelease(gpa, io, .{
        .work_dir = wd,
        .name = try zigbuild.fileStem(arena, result.mir.name),
        .optimize = b.optimize,
        .backend = b.backend,
        .modules = &modules,
        .zig_exe = b.zig_exe,
        .debug_info = b.debug_info,
        // `osdi_dyn` keeps every per-iterate callback in `.eval`.
        .cold_self_hosted = req.osdi,
        .artifact_cache = if (req.osdi) b.artifact_cache else null,
    }, device, 1) catch |e| {
        try err.print("error: {s}: building the device failed: {t}\n", .{ in_path, e });
        return o.done(1);
    };
    defer r.deinit(gpa);
    switch (r) {
        .ok => |a| if (req.osdi) {
            const dest = req.out_path orelse try arena.print("{s}.osdi", .{result.mir.name});
            Io.Dir.cwd().copyFile(a.so_path, Io.Dir.cwd(), dest, io, .{}) catch |e| {
                try err.print("error: cannot write `{s}`: {t}\n", .{ dest, e });
                return o.done(1);
            };
            o.path = dest;
        } else {
            o.path = try arena.dupe(u8, a.so_path);
        },
        .failed => |bundle| {
            // An error typeCheck can see is the device's own (an engine bug),
            // reported against the .va as a check would have.
            if (try zigbuild.typeCheck(gpa, io, err, b.zig_exe, b.contract.?, device.text, in_path)) |code| return o.done(code);
            try err.print("error: {s}: the generated device did not compile:\n", .{in_path});
            try bundle.renderToWriter(.{}, err);
            return o.done(1);
        },
    }
    assert(o.path != null);
}
