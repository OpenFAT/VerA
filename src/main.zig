//! `vera`, the command-line driver: argv -> a compiled, linted, generated or
//! run artifact, with the library's diagnostics on stderr. Options:
//! `cli/usage.zig`.
//!
//! Exit status: 0 on success (warnings do not fail), 1 on a diagnosed error,
//! 2 on a usage error, including conflicting flags (never last-one-wins).
//!
//! `main` is the spine: read the command line (`cli/args.zig`), settle the
//! build mode, refuse the flags that conflict (`args.resolve`), serve
//! `--lsp` (`cli/lsp.zig`), refuse a language with no compilation path, read
//! the source, refuse the flags its language cannot take, write this vera's
//! own engine tree when a `zig` build needs a contract, then hand the source
//! to the `.v` half (`cli/digital.zig`) or the Verilog-A half
//! (`cli/analog.zig`). Flags, streams, exit codes and messages are
//! user-visible and frozen.
//!
//! Cites: §9.4 (`--display`); IEEE 1800 (refused, E1104); the rest are the
//! halves'.
//!
//! Contents:
//! - `pub fn main(init: std.process.Init) !u8`

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vera = @import("vera");
const diag = vera.diag;
const zigbuild = @import("zigbuild");
const Preprocessor = @import("frontend").Preprocessor;
const args = @import("cli/args.zig");
const analog = @import("cli/analog.zig");
const digital_cli = @import("cli/digital.zig");
const lsp = @import("cli/lsp.zig");
const report = @import("cli/report.zig");
/// `-Dlanguage=ams`. When false this is an IEEE 1364-2005 tool and the analog
/// backend is comptime-dead.
const ams = @import("build_options").ams;

/// Returns the process exit status (see the file header).
pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {}; // Nothing is left to report a failed flush to.

    var stderr_buf: [1 << 16]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &stderr_buf);
    const err = &stderr.interface;
    defer err.flush() catch {}; // As above.

    var cli: args.Cli = .{};
    defer cli.deinit(gpa);
    var argv = try init.minimal.args.iterateAllocator(gpa);
    defer argv.deinit();
    _ = argv.skip();
    if (try args.parse(&cli, gpa, &argv, out, err)) |code| return code;

    // A testbench compiles for seconds and runs for microseconds; a `.so` is
    // the host's hot loop.
    const opt = cli.optimize orelse if (cli.exe_flag != null) std.lang.Optimize.debug else .fast;
    const backend = cli.zig_backend orelse zigbuild.Backend.auto(opt, builtin.target.cpu.arch);
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
    assert(cli.paths.items.len != 0); // `resolve` printed the usage otherwise.
    const in_path = cli.paths.items[0];

    // Decided once: `isTty` can fail, and an error path should not re-ask.
    const style: report.Style = .{ .json = cli.json, .color = switch (cli.color) {
        .always => true,
        .never => false,
        .auto => stderr.file.isTty(io) catch false,
    } };
    if (try refuseLanguage(gpa, in_path, style, err)) |code| return code;

    const source = Preprocessor.readText(io, .cwd(), in_path, gpa) catch |e| {
        try vera.readFailed(err, in_path, e);
        return 2;
    };
    defer gpa.free(source);
    const digital_source = std.mem.eql(u8, std.fs.path.extension(in_path), ".v");
    if (try refuseFlags(&cli, digital_source, in_path, err)) |code| return code;

    // The arena holds what the halves hand back, and the engine tree's paths.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (try contractTree(io, arena, &cli, digital_source, err)) |code| return code;

    if (digital_source) return digital_cli.run(gpa, io, init.environ_map, &cli, source, in_path, .{ .optimize = opt, .backend = backend, .style = style }, out, err);
    if (!ams) {
        try err.print("error: {s}: this vera is built with -Dlanguage=verilog; it runs .v sources only\n", .{in_path});
        return 2;
    }
    return analog.run(gpa, io, arena, init.environ_map, &cli, source, .{ .optimize = opt, .backend = backend, .style = style }, out, err);
}

// ---- private ----

/// Refuses an input whose language has no compilation path: IEEE 1800 is
/// E1104, VHDL a plain refusal. Null for any other extension.
fn refuseLanguage(gpa: Allocator, in_path: []const u8, style: report.Style, err: *Io.Writer) !?u8 {
    assert(in_path.len != 0);
    const ext = std.fs.path.extension(in_path);
    if (std.mem.eql(u8, ext, ".sv")) {
        var sv: diag.Bag = .init(gpa);
        defer sv.deinit(gpa);
        try sv.add(.parse, .E1104, .none, "`{s}` is an IEEE 1800 source", .{in_path});
        try report.report(&sv, err, style);
        return 2;
    }
    if (std.mem.eql(u8, ext, ".vhd") or std.mem.eql(u8, ext, ".vhdl")) {
        try err.print("error: {s}: this language extension has no enabled compilation path\n", .{in_path});
        try err.writeAll("note: use --run FILE.v for the documented digital Verilog execution subset\n");
        return 2;
    }
    return null;
}

/// Refuses the flags the source's language cannot take: `--sim=` names a
/// family and the extension says which one the file is; a `.va` takes one
/// input and no library flags; `--state`, `--emit-rtlil` and `--elab` are a
/// `.v` design's, `--emit-verilog` a `.va`'s. Runs before anything is
/// written to disk.
fn refuseFlags(cli: *const args.Cli, digital_source: bool, in_path: []const u8, err: *Io.Writer) Io.Writer.Error!?u8 {
    assert(cli.paths.items.len != 0);
    assert(!cli.lsp);
    if (cli.sim == .verilog and !digital_source) {
        try err.print("error: --sim=verilog compiles IEEE 1364 designs (.v); `{s}` is not one\n", .{in_path});
        return 2;
    }
    if (cli.sim == .verilog_a and digital_source) {
        try err.print("error: --sim=verilogA compiles Verilog-A models (.va); `{s}` is a digital design\n", .{in_path});
        return 2;
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
    if (!digital_source and cli.elab) {
        try err.print("error: {s}: --elab takes an IEEE 1364 design (.v); --lint elaborates a Verilog-A/AMS source\n", .{in_path});
        return 2;
    }
    if (digital_source and cli.emit_verilog) {
        try err.print("error: {s}: --emit-verilog takes a Verilog-A model (.va)\n", .{in_path});
        return 2;
    }
    return null;
}

/// When a `zig` build needs a contract, checks a typed `--contract` and,
/// without one or for `--emit-osdi`, writes this vera's own `lib/` tree
/// under the work directory and points `cli.contract_path` (and, for
/// `--emit-osdi`, `cli.dyn_path`) into it, so the contract always matches
/// the compiler. Null to go on, else the exit status with the reason on `err`.
fn contractTree(io: Io, arena: Allocator, cli: *args.Cli, digital_source: bool, err: *Io.Writer) (Allocator.Error || Io.Writer.Error)!?u8 {
    const builds = cli.check or cli.emit_so or (cli.exe_flag != null and !(digital_source and cli.run_exe));
    if (!builds) return null;
    if (cli.contract_path) |p| Io.Dir.cwd().access(io, p, .{}) catch |e| {
        try err.print("error: --contract {s}: {t}\n", .{ p, e });
        return 2;
    };
    if (cli.contract_path != null and !cli.emit_osdi) return null;
    const wd = cli.work_dir orelse ".zig-cache/vera-tb";
    const c = simTree(io, arena, wd) catch |e| {
        try err.print("error: writing the engine sources under {s} failed: {t}\n", .{ wd, e });
        return 1;
    };
    if (cli.contract_path == null) cli.contract_path = c;
    // --emit-osdi: the OSDI dyn shipped in the same tree.
    if (cli.emit_osdi) cli.dyn_path = try std.fs.path.join(arena, &.{ std.fs.path.dirname(c).?, "osdi_dyn.zig" });
    assert(cli.contract_path != null);
    return null;
}

/// Writes the sources `sim` compiles from (`sim_sources`, embedded at build
/// time) under `dir` and returns the `contract` root among them, the path
/// a testbench build finds the tree from. Each file lands atomically, so a
/// concurrent `vera` writing the same tree never exposes half a file.
fn simTree(io: Io, arena: Allocator, dir: []const u8) ![]const u8 {
    assert(dir.len != 0);
    const root = try std.fs.path.join(arena, &.{ dir, "vera-src" });
    var d = try Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer d.close(io);
    const files = @import("sim_sources").files;
    comptime assert(files.len != 0);
    for (files) |f| {
        var af = try d.createFileAtomic(io, f[0], .{ .make_path = true, .replace = true });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, f[1]);
        try af.replace(io);
    }
    return std.fs.path.join(arena, &.{ root, "lib", "contract.zig" });
}

// The CLI's own files are pulled in here, the module's root.
test {
    _ = args;
    _ = analog;
    _ = digital_cli;
    _ = report;
    _ = lsp;
    _ = @import("cli/global_cache.zig");
    _ = @import("cli/usage.zig");
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
