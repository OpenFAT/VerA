//! `vera` over a `.va`: the settled command line and the source -> a
//! `vera.Request`, the `vera.compile` spine, and what its `Outcome` says to
//! print: paths and text on stdout, the refusal and the diagnostics on
//! stderr, the status as the exit code. `--run` then runs the testbench it
//! built with the source's plusargs, and its exit status is `vera`'s.
//!
//! Cites: IEEE 1364-2005 §17.10 (`--run`'s plusargs); the rest are
//! `vera.compile`'s.
//!
//! Contents:
//! - `pub fn run(gpa: Allocator, io: Io, arena: Allocator, env: *const std.process.Environ.Map, cli: *const Cli, source: []const u8, b: args.Settled, out: *Io.Writer, err: *Io.Writer) Error!u8`
//! - `pub const Error`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vera = @import("vera");
const diag = vera.diag;
const args = @import("args.zig");
const Cli = args.Cli;
const report = @import("report.zig");
const globalCache = @import("global_cache.zig").globalCache;

/// Every way `run` fails rather than refuses: the spine's failures, the
/// report's, and a testbench that could not be spawned.
pub const Error = vera.CompileError || diag.RenderError || std.process.SpawnError || std.process.Child.WaitError;

/// Compiles `source` (named `cli.paths[0]`) as `cli` asks and returns the
/// exit status. Every slice it hands out lives in `arena`.
/// Asserts that `cli` names exactly one input, as `main` checked.
pub fn run(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    env: *const std.process.Environ.Map,
    cli: *const Cli,
    source: []const u8,
    b: args.Settled,
    out: *Io.Writer,
    err: *Io.Writer,
) Error!u8 {
    assert(cli.paths.items.len == 1);
    assert(!cli.lsp);
    const in_path = cli.paths.items[0];
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var o: vera.Outcome = .{};
    defer o.deinit(gpa);
    vera.compile(gpa, io, arena, source, .{
        .options = .{
            .file_name = in_path,
            .include_dirs = cli.include_dirs.items,
            .defines = cli.defines.items,
            .std_defs = cli.std_defs,
            .require_std_includes = true, // the source includes the annex D files it uses
            .language = cli.language,
            .sim = cli.sim,
            .lint = cli.levels,
            .proof = .{ .unknown_bound = cli.unknown_bound },
            .discipline_resolution = cli.discipline_resolution,
            .display = cli.display,
            .param_overrides = cli.overrides.items,
        },
        .codegen = .{ .jac_f32 = cli.jac_f32, .jac_f32_host = cli.jac_f32_host },
        .spice_path = cli.spice_path,
        .verilog = if (cli.emit_verilog) .{ .digital_pins = cli.digital_pins, .power_pins = cli.power_pins, .vdd = cli.vdd } else null,
        .osdi = cli.emit_osdi,
        .expect_module = cli.expect_module,
        .check = cli.check,
        .exe = if (cli.exe_flag != null) .{ .validate_contract = cli.validate_contract } else null,
        .so = cli.emit_so,
        .zig = cli.emit_zig,
        .out_path = cli.out_path,
        .build = .{
            .contract = cli.contract_path,
            .dyn = cli.dyn_path,
            .work_dir = cli.work_dir,
            .zig_exe = cli.zig_exe,
            .optimize = b.optimize,
            .backend = b.backend,
            .debug_info = cli.debug_info,
            // A finished `.osdi` is reused across work directories.
            .artifact_cache = if (cli.emit_osdi) try globalCache(arena, env, "vera-osdi") else null,
        },
    }, &bag, &o) catch |e| {
        // Past the `--param` check the bag is final, and an error leaves
        // through the same report as every other exit. A report that fails
        // on top of it is returned in its place.
        if (o.report == .after) try report.report(&bag, err, b.style);
        return e;
    };
    switch (o.report) {
        .failed => |e| return compileFailed(&bag, err, b.style, e),
        .none => {
            try err.writeAll(o.err);
            return o.status;
        },
        .after => {},
    }
    // Warnings on a successful analysis, after whatever `deliver` printed or
    // ran: codegen reports too (E0515), and `render` prints the whole bag.
    const code = deliver(io, arena, cli, &o, out, err) catch |e| {
        try report.report(&bag, err, b.style);
        return e;
    };
    try report.report(&bag, err, b.style);
    return code;
}

// ---- private ----

/// Reports a failed analysis' diagnostics and returns exit status 1. The
/// error's name is printed only for an undiagnosed failure.
fn compileFailed(bag: *diag.Bag, err: *Io.Writer, style: report.Style, e: vera.AnalyzeError) (diag.RenderError || Io.Writer.Error)!u8 {
    try report.report(bag, err, style);
    switch (e) {
        error.CompileFailed, error.NoModule => {},
        error.OutOfMemory, error.NothingToElaborate => try err.print("error: {t}\n", .{e}),
    }
    return 1;
}

/// Prints what a successful `compile` built and, under `--run`, runs the
/// testbench with its plusargs; returns the exit status.
fn deliver(io: Io, arena: Allocator, cli: *const Cli, o: *const vera.Outcome, out: *Io.Writer, err: *Io.Writer) !u8 {
    assert(o.report == .after);
    if (o.path) |p| try out.print("{s}\n", .{p});
    try out.writeAll(o.text);
    try err.writeAll(o.err);
    const bin = o.exe orelse return o.status;
    if (!cli.run_exe) {
        try out.print("{s}\n", .{bin});
        try out.flush();
        return 0;
    }
    // --run: the transcript is the point, so the testbench inherits both
    // streams and its exit status is ours.
    const tb_argv = try arena.alloc([]const u8, 1 + o.plusargs.len);
    tb_argv[0] = bin;
    @memcpy(tb_argv[1..], o.plusargs);
    var child = try std.process.spawn(io, .{ .argv = tb_argv });
    return switch (try child.wait(io)) {
        .exited => |c| c,
        else => 1,
    };
}

test compileFailed {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // A diagnosed failure is the bag's to explain: no error name, still 1.
    try std.testing.expectEqual(@as(u8, 1), try compileFailed(&bag, &w, .{}, error.CompileFailed));
    try std.testing.expectEqual(@as(u8, 1), try compileFailed(&bag, &w, .{}, error.NoModule));
    try std.testing.expectEqualStrings("", w.buffered());
    try std.testing.expectEqual(@as(u8, 1), try compileFailed(&bag, &w, .{}, error.OutOfMemory));
    try std.testing.expectEqualStrings("error: OutOfMemory\n", w.buffered());
}
