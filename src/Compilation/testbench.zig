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
const ir = @import("ir");
const zigbuild = @import("zigbuild");
const request = @import("request.zig");
const Request = request.Request;
const Outcome = request.Outcome;
const Result = @import("Result.zig");

/// The most explicit D2A sites a mixed runner watches: `watchEvent`'s u6.
const d2a_sites_max = 64;

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
    // `sim.digital.watchEvent` numbers an explicit D2A site in a u6: the
    // mixed runner holds at most 64 (§8.5, one bit each).
    if (facts.mixed) |mx| if (mx.events.len > d2a_sites_max) {
        try bag.add(.codegen, .E0437, .none, "{d} explicit D2A event terms; the mixed-signal runner holds at most {d}", .{ mx.events.len, d2a_sites_max });
        return o.done(1);
    };
    // The mixed runner counts the digital half's ticks from 0 in a u64: a
    // `//! time` at or past 2^64 ticks of the finest precision has no tick.
    if (facts.mixed) |mx| if (spec.bench.times_s.len != 0) {
        const tick = finestPrecision(mx.timescales);
        const last = spec.bench.times_s[spec.bench.times_s.len - 1];
        if (!(last / tick < 0x1p64)) {
            try err.print("error: {s}: `//!` directive: the last time, {e} s, is at or past 2^64 ticks of the design's finest time precision, {e} s\n", .{ in_path, last, tick });
            return o.done(2);
        }
    };
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

// ---- private ----

/// The smallest precision any `timescale gives (IEEE 1364-2005 §19.8), 1 s
/// (the default) with none: at most the digital half's finest tick, so a
/// count of these bounds its tick count from above.
fn finestPrecision(events: []const ir.Lowered.TimescaleEvent) f64 {
    var p: f64 = 1;
    for (events) |ev| if (ev.value) |t| {
        p = @min(p, t.precision);
    };
    assert(p > 0);
    return p;
}
