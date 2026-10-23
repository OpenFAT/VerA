//! `vera`, the command-line driver: argv -> a compiled, linted, generated or
//! run artifact, with the library's diagnostics on stderr. `--run FILE.v` uses
//! `src/sim` instead of the analog pipeline. Options: `cli/args.zig`'s
//! `usage_text`.
//!
//! Exit status: 0 on success (warnings do not fail), 1 on a diagnosed error,
//! 2 on a usage error, including conflicting flags (never last-one-wins).
//!
//! `main` reads the command line (`cli/args.zig`), refuses the flags that
//! conflict (`args.resolve`), serves `--lsp` (`cli/lsp.zig`) or reads the
//! source, then hands it to the `.v` path (`cli/digital.zig`) or to the
//! Verilog-A spine, `vera.compile`, and prints the `vera.Outcome` it returns:
//! its paths and text on stdout, its refusal and the diagnostics on stderr,
//! its status as the exit code; `--run` runs the testbench it built. Flags,
//! streams, exit codes and messages are user-visible and frozen:
//! `--emit-exe` prints the artifact's path on stdout and every diagnostic on
//! stderr.
//!
//! Clauses: §9.4 (`--display`); the rest are `vera.compile`'s.

const std = @import("std");
const builtin = @import("builtin");
/// `-Dlanguage=ams`. When false this is an IEEE 1364-2005 tool and the analog
/// backend is comptime-dead.
const ams = @import("build_options").ams;
const vera = @import("vera");
const diag = vera.diag;
const Io = std.Io;
const args = @import("cli/args.zig");
const digital_cli = @import("cli/digital.zig");
const lsp = @import("cli/lsp.zig");
const cli_report = @import("cli/report.zig");
const report = cli_report.report;

/// Returns the process exit status (see the file header).
pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var stderr_buf: [1 << 16]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr.interface;
    defer err.flush() catch {};

    var cli: args.Cli = .{};
    defer cli.deinit(gpa);
    var argv = try init.minimal.args.iterateAllocator(gpa);
    defer argv.deinit();
    _ = argv.skip();
    if (try args.parse(&cli, gpa, &argv, out, err)) |code| return code;

    // A testbench compiles for seconds and runs for microseconds; a `.so` is
    // the host's hot loop.
    const opt = cli.optimize orelse if (cli.exe_flag != null) std.lang.Optimize.debug else .fast;
    const backend = cli.zig_backend orelse vera.orchestrator.Backend.auto(opt, builtin.target.cpu.arch);
    // The self-hosted backend takes `-O` and does not optimise: legal, but a
    // Release build under it is only as fast as Debug minus the safety checks.
    if ((cli.exe_flag != null or cli.emit_so) and backend == .self_hosted and opt != .debug)
        try err.print("warning: --zig-backend=native does not optimise; the {t} artifact is unoptimised\n", .{opt});
    // Conflicting flags are refused by name, whatever order they came in.
    if (try args.resolve(&cli, err)) |code| return code;
    if (cli.lsp) {
        var stdin_buf: [1 << 16]u8 = undefined;
        var stdin = Io.File.stdin().readerStreaming(io, &stdin_buf);
        return lsp.serve(gpa, io, &cli, &stdin.interface, out, err);
    }
    const in_path = cli.paths.items[0];

    // Decided once: `isTty` can fail, and an error path should not re-ask.
    const use_color = switch (cli.color) {
        .always => true,
        .never => false,
        .auto => (stderr.file.isTty(io) catch false),
    };

    // Digital Verilog uses the shared frontend below. Other language families
    // need their own standard-conforming frontend and remain explicit refusals.
    const ext = std.fs.path.extension(in_path);
    if (std.mem.eql(u8, ext, ".sv")) {
        var sv: diag.Bag = .init(gpa);
        defer sv.deinit(gpa);
        try sv.add(.parse, .E1104, .none, "`{s}` is an IEEE 1800 source", .{in_path});
        try report(&sv, err, cli.json, use_color);
        return 2;
    }
    if (std.mem.eql(u8, ext, ".vhd") or std.mem.eql(u8, ext, ".vhdl")) {
        try err.print(
            "error: {s}: this language extension has no enabled compilation path\n",
            .{in_path},
        );
        try err.writeAll(
            "note: use --run FILE.v for the documented digital Verilog execution subset\n",
        );
        return 2;
    }

    const source = vera.Preprocessor.readText(io, .cwd(), in_path, gpa) catch |e| {
        try vera.readFailed(err, in_path, e);
        return 2;
    };
    defer gpa.free(source);

    const digital_source = std.mem.eql(u8, ext, ".v");
    // `--sim=` names a language family, and the extension says which one the file is.
    if (cli.sim == .verilog and !digital_source) {
        try err.print("error: --sim=verilog compiles IEEE 1364 designs (.v); `{s}` is not one\n", .{in_path});
        return 2;
    }
    if (cli.sim == .verilog_a and digital_source) {
        try err.print("error: --sim=verilogA compiles Verilog-A models (.va); `{s}` is a digital design\n", .{in_path});
        return 2;
    }
    // No --contract: this binary's own lib/contract.zig, written out with the
    // `sim` tree it embeds, so the contract always matches the compiler and the
    // mixed-signal runner finds `sim` beside it. The arena also holds what
    // `vera.compile` hands back.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    if (cli.check or cli.emit_so or (cli.exe_flag != null and !(digital_source and cli.run_exe))) {
        if (cli.contract_path) |p| Io.Dir.cwd().access(io, p, .{}) catch |e| {
            try err.print("error: --contract {s}: {t}\n", .{ p, e });
            return 2;
        };
        if (cli.contract_path == null or cli.emit_osdi) {
            const wd = cli.work_dir orelse ".zig-cache/vera-tb";
            const c = simTree(io, arena.allocator(), wd) catch |e| {
                try err.print("error: writing the engine sources under {s} failed: {t}\n", .{ wd, e });
                return 1;
            };
            if (cli.contract_path == null) cli.contract_path = c;
            // --emit-osdi: the OSDI dyn shipped in the same tree.
            if (cli.emit_osdi) cli.dyn_path = try std.fs.path.join(arena.allocator(), &.{ std.fs.path.dirname(c).?, "osdi_dyn.zig" });
        }
    }
    if (!digital_source) {
        if (cli.paths.items.len > 1) {
            try err.writeAll("error: more than one input file\n");
            return 2;
        }
        if (cli.libmaps.items.len != 0 or cli.search.items.len != 0) {
            try err.writeAll("error: --libmap and -L configure a .v design's libraries\n");
            return 2;
        }
    }
    if (cli.logic_flag) |f| if (!digital_source or cli.run_exe) {
        try err.print("error: {s} builds a .v design's executable; it takes --emit-exe and a .v file\n", .{f});
        return 2;
    };
    if (!digital_source and cli.emit_rtlil) {
        try err.print("error: {s}: --emit-rtlil takes an IEEE 1364 design (.v)\n", .{in_path});
        return 2;
    }
    if (digital_source and cli.emit_verilog) {
        try err.print("error: {s}: --emit-verilog takes a Verilog-A model (.va)\n", .{in_path});
        return 2;
    }
    if (digital_source) return digital_cli.run(gpa, io, init.environ_map, &cli, source, in_path, opt, backend, use_color, out, err);

    if (!ams) {
        try err.print("error: {s}: this vera is built with -Dlanguage=verilog; it runs .v sources only\n", .{in_path});
        return 2;
    }

    // The Verilog-A half: the spine (`vera.compile`) builds what the flags
    // ask for; this prints what it did, in the order it did it.
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var o: vera.Outcome = .{};
    defer o.deinit();
    vera.compile(gpa, io, arena.allocator(), source, .{
        .options = .{
            .file_name = in_path,
            .include_dirs = cli.include_dirs.items,
            .std_defs = cli.std_defs,
            .require_std_includes = true, // the source includes the annex D files it uses
            .language = cli.language,
            .sim = cli.sim,
            .lint = cli.levels,
            .proof = .{ .unknown_bound = cli.unknown_bound },
            .discipline_resolution = cli.discipline_resolution,
            .display = cli.display,
            .jac_f32 = cli.jac_f32,
            .jac_f32_host = cli.jac_f32_host,
            .param_overrides = cli.overrides.items,
        },
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
            .optimize = opt,
            .backend = backend,
            .debug_info = cli.debug_info,
            // A finished `.osdi` is reused across work directories.
            .artifact_cache = if (cli.emit_osdi) try digital_cli.globalCache(arena.allocator(), init.environ_map, "vera-osdi") else null,
        },
    }, &bag, &o) catch |e| {
        // Past the `--param` check the bag is final, and an error leaves
        // through the same report as every other exit.
        if (o.report == .after) report(&bag, err, cli.json, use_color) catch {};
        return e;
    };
    switch (o.report) {
        .failed => |e| return compileFailed(&bag, err, cli.json, use_color, e),
        .none => {
            try err.writeAll(o.err);
            return o.status;
        },
        .after => {},
    }
    // Warnings on a successful compile, deferred to one call on every exit
    // below: codegen reports too (E0515) and `render` prints the whole bag.
    defer report(&bag, err, cli.json, use_color) catch {};
    if (o.path) |p| try out.print("{s}\n", .{p});
    try out.writeAll(o.text);
    try err.writeAll(o.err);
    const bin = o.exe orelse return o.status;
    if (!cli.run_exe) {
        try out.print("{s}\n", .{bin});
        try out.flush();
        return 0;
    }
    // --run: the transcript is the point, so inherit both streams and let
    // the testbench's exit status be ours.
    var child = try std.process.spawn(io, .{ .argv = &.{bin} });
    return switch (try child.wait(io)) {
        .exited => |c| c,
        else => 1,
    };
}

/// Writes the sources `sim` compiles from (`sim_sources`, embedded at build
/// time) under `dir` and returns the `contract` root among them, the path
/// `tb.buildExe` finds the tree from. Each file lands atomically, so a
/// concurrent `vera` writing the same tree never exposes half a file.
fn simTree(io: Io, arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
    const root = try std.fs.path.join(arena, &.{ dir, "vera-src" });
    var d = try Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer d.close(io);
    for (@import("sim_sources").files) |f| {
        var af = try d.createFileAtomic(io, f[0], .{ .make_path = true, .replace = true });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, f[1]);
        try af.replace(io);
    }
    return std.fs.path.join(arena, &.{ root, "lib", "contract.zig" });
}

/// Reports a failed compilation's diagnostics and returns exit code 1. The Zig
/// error name is printed only for an undiagnosed failure.
fn compileFailed(bag: *diag.Bag, err: *Io.Writer, json: bool, use_color: bool, e: anyerror) !u8 {
    try report(bag, err, json, use_color);
    switch (e) {
        error.CompileFailed, error.NoModule => {},
        else => try err.print("error: {t}\n", .{e}),
    }
    return 1;
}

// ---------------------------------------------------------------------------
// Tests. The CLI's own files are pulled in here, the module's root.
// ---------------------------------------------------------------------------

test {
    _ = args;
    _ = digital_cli;
    _ = cli_report;
    _ = lsp;
}

test compileFailed {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // A diagnosed failure is the bag's to explain: no error name, still 1.
    try std.testing.expectEqual(@as(u8, 1), try compileFailed(&bag, &w, false, false, error.CompileFailed));
    try std.testing.expectEqual(@as(u8, 1), try compileFailed(&bag, &w, false, false, error.NoModule));
    try std.testing.expectEqualStrings("", w.buffered());
    try std.testing.expectEqual(@as(u8, 1), try compileFailed(&bag, &w, false, false, error.OutOfMemory));
    try std.testing.expectEqualStrings("error: OutOfMemory\n", w.buffered());
}

test simTree {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    // Twice: the second run replaces every file in place.
    for (0..2) |_| {
        const c = try simTree(std.testing.io, a, wd);
        try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ wd, "vera-src", "lib", "contract.zig" }), c);
        const text = try Io.Dir.cwd().readFileAlloc(std.testing.io, c, a, .unlimited);
        try std.testing.expect(std.mem.find(u8, text, "vera_version") != null);
    }
}
