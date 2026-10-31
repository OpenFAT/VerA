//! `vera`'s argv -> one `Cli` value: what the user typed, flag by flag, in
//! order (`parse`), then the conflicts between well-formed flags refused and
//! what they derive settled (`resolve`), whatever their order. `--help`,
//! `--version` and `--explain` answer in `parse`; a malformed flag is refused
//! there with exit status 2.
//!
//! Every flag is a row of one of two tables: `switches` (the whole argument)
//! and `valued` (`--name=` and the text after it). A flag with its value in
//! the next argument is a switch that reads one more. Adding a flag is a row
//! and a prong; the exhaustive `switch` names every site.
//!
//! The flags, their spelling and every message are user-visible and frozen.
//! Cites: LRM 3.4 (`--param`), annex E.2 (`--spice`), IEEE 1364-2005 §3.7.1
//! (`-D` names), §13.2 and §13.7.1 (`--libmap`, `-L`), §15.5.4
//! (`--negative-timing`).
//!
//! Contents:
//! - `pub const usage_text` (re-exported from `usage.zig`)
//! - `pub const Cli = struct`, `Cli.deinit(cli: *Cli, gpa: Allocator) void`
//! - `pub const Settled = struct`
//! - `pub const ParseError = Allocator.Error || Io.Writer.Error`
//! - `pub fn parse(cli: *Cli, gpa: Allocator, args: anytype, out: *Io.Writer, err: *Io.Writer) ParseError!?u8`
//! - `pub fn resolve(cli: *Cli, err: *Io.Writer) Io.Writer.Error!?u8`
//! - `pub fn missing(w: *Io.Writer, flag: []const u8, what: []const u8) Io.Writer.Error!u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vera = @import("vera");
const diag = vera.diag;
const Display = vera.Display;
const zigbuild = @import("zigbuild");
const report = @import("report.zig");
const digital = @import("sim").digital;
/// The native emitter (src/codegen/digital/): `--schedule=` and `--state=`.
const native = @import("digital");
/// The VerA release: what `--version` prints and every device it generates
/// carries (`contract.vera_version`).
const vera_version = @import("contract").vera_version;
/// `-Dlanguage=ams`. When false this is an IEEE 1364-2005 tool and the analog
/// backend is comptime-dead.
const ams = @import("build_options").ams;

/// `--help`, and what a command line naming no input prints to stderr.
pub const usage_text = @import("usage.zig").usage_text;

/// One command line, as typed.
pub const Cli = @import("Cli.zig");

/// What `main` settles once the line is read, for both halves: the build
/// mode a testbench or library gets, and how diagnostics are written.
pub const Settled = struct {
    optimize: std.lang.Optimize,
    backend: zigbuild.Backend,
    style: report.Style,
};

/// Every way `parse` fails: the lists could not grow, or `out`/`err` could
/// not take the answer. `cli` keeps what it read before the failure.
pub const ParseError = Allocator.Error || Io.Writer.Error;

/// A whole-argument flag. Those that take a value read the next argument.
const Switch = enum {
    help,
    version,
    explain,
    lint,
    elab,
    lsp,
    emit_zig,
    emit_verilog,
    emit_rtlil,
    digital_pins,
    power_pins,
    check,
    emit_so,
    emit_osdi,
    emit_exe,
    run,
    validate_contract,
    jac_f32,
    jac_f32_host,
    contract,
    param,
    dyn,
    work_dir,
    debug_info,
    zig,
    negative_timing,
    two_state,
    out,
    spice,
    libmap,
    protect_keys,
    library,
    include,
    no_std_defs,
    json,
    text,
    color_always,
    color_never,
    color_auto,
};

const switches = std.StaticStringMap(Switch).initComptime(.{
    .{ "--help", .help },                       .{ "-h", .help },
    .{ "--version", .version },                 .{ "-v", .version },
    .{ "-V", .version },                        .{ "--explain", .explain },
    .{ "--lint", .lint },                       .{ "--elab", .elab },
    .{ "--lsp", .lsp },                         .{ "--emit-zig", .emit_zig },
    .{ "--emit-verilog", .emit_verilog },       .{ "--emit-rtlil", .emit_rtlil },
    .{ "--digital-pins", .digital_pins },       .{ "--power-pins", .power_pins },
    .{ "--check", .check },                     .{ "--emit-so", .emit_so },
    .{ "--emit-osdi", .emit_osdi },             .{ "--emit-exe", .emit_exe },
    .{ "--run", .run },                         .{ "--validate-contract", .validate_contract },
    .{ "--jac-f32", .jac_f32 },                 .{ "--jac-f32-host", .jac_f32_host },
    .{ "--contract", .contract },               .{ "--param", .param },
    .{ "--dyn", .dyn },                         .{ "--work-dir", .work_dir },
    .{ "--debug-info", .debug_info },           .{ "--zig", .zig },
    .{ "--negative-timing", .negative_timing }, .{ "--two-state", .two_state },
    .{ "-o", .out },                            .{ "--spice", .spice },
    .{ "--libmap", .libmap },                   .{ "--protect-keys", .protect_keys },
    .{ "-L", .library },                        .{ "-I", .include },
    .{ "--no-std-defs", .no_std_defs },         .{ "--diagnostics=json", .json },
    .{ "--diagnostics=text", .text },           .{ "--color=always", .color_always },
    .{ "--color=never", .color_never },         .{ "--color=auto", .color_auto },
});

/// A `--name=value` flag, keyed by its text through the `=`.
const Valued = enum {
    vdd,
    display,
    optimize,
    state,
    schedule,
    event_budget,
    zig_backend,
    expect_module,
    std,
    sim,
    discipline_resolution,
    unknown_bound,
};

const valued = std.StaticStringMap(Valued).initComptime(.{
    .{ "--vdd=", .vdd },                                     .{ "--display=", .display },
    .{ "--optimize=", .optimize },                           .{ "--state=", .state },
    .{ "--schedule=", .schedule },                           .{ "--event-budget=", .event_budget },
    .{ "--zig-backend=", .zig_backend },                     .{ "--expect-module=", .expect_module },
    .{ "--std=", .std },                                     .{ "--sim=", .sim },
    .{ "--discipline-resolution=", .discipline_resolution }, .{ "--unknown-bound=", .unknown_bound },
});

/// `--optimize=` names. Zig 0.17 renamed `std.lang.Optimize`'s tags
/// (`fast`, ...); the flag keeps the names it always took.
const optimize_names = std.StaticStringMap(std.lang.Optimize).initComptime(.{
    .{ "Debug", .debug },
    .{ "ReleaseSafe", .safe },
    .{ "ReleaseFast", .fast },
    .{ "ReleaseSmall", .small },
});

/// The arguments one command line may hold: past this the line is refused,
/// so a runaway generator cannot grow the lists without bound.
const args_max: u32 = 1 << 20;

/// The tests' sources and helpers; analysed only under `zig test`.
const fixtures = struct {
    const testing = std.testing;

    /// A fixed command line, the iterator shape `parse` reads.
    const Argv = struct {
        items: []const []const u8,
        i: usize = 0,

        fn next(a: *Argv) ?[]const u8 {
            if (a.i == a.items.len) return null;
            defer a.i += 1;
            return a.items[a.i];
        }
    };

    /// One command line under test: the `Cli` it fills and what it printed.
    const Line = struct {
        cli: Cli = .{},
        out: Io.Writer.Allocating,
        err: Io.Writer.Allocating,

        fn init() Line {
            return .{ .out = .init(testing.allocator), .err = .init(testing.allocator) };
        }

        fn deinit(l: *Line) void {
            l.cli.deinit(testing.allocator);
            l.out.deinit();
            l.err.deinit();
        }

        /// `parse` over `argv` (literals, so they outlive `cli`).
        fn read(l: *Line, argv: []const []const u8) !?u8 {
            var it: Argv = .{ .items = argv };
            return parse(&l.cli, testing.allocator, &it, &l.out.writer, &l.err.writer);
        }

        /// `parse`, then `resolve` when `parse` went on.
        fn settle(l: *Line, argv: []const []const u8) !?u8 {
            if (try l.read(argv)) |code| return code;
            return resolve(&l.cli, &l.err.writer);
        }
    };

    /// `argv` stops `parse` with exit status 2 and exactly `want` on stderr.
    fn expectRefused(argv: []const []const u8, want: []const u8) !void {
        var l: Line = .init();
        defer l.deinit();
        try testing.expectEqual(@as(?u8, 2), try l.read(argv));
        try testing.expectEqualStrings(want, l.err.written());
        try testing.expectEqualStrings("", l.out.written());
    }

    /// `argv` through `parse` and `resolve`: `code`, and exactly `want` on stderr.
    fn expectSettled(argv: []const []const u8, code: ?u8, want: []const u8) !void {
        var l: Line = .init();
        defer l.deinit();
        try testing.expectEqual(code, try l.settle(argv));
        try testing.expectEqualStrings(want, l.err.written());
    }

    fn parseLine(gpa: std.mem.Allocator) !void {
        var cli: Cli = .{};
        defer cli.deinit(gpa);
        var it: Argv = .{ .items = &.{ "-I", "inc", "--param", "r=1", "--deny=W0650", "--libmap", "a.map", "-L", "lib", "top.v" } };
        var discard: Io.Writer.Discarding = .init(&.{});
        try testing.expectEqual(@as(?u8, null), try parse(&cli, gpa, &it, &discard.writer, &discard.writer));
    }
};

/// Reads every argument after argv[0] into `cli`, in order. Returns null to
/// go on, or the process exit code when the line is answered here: 0 after
/// `--help` (usage on `out`), `--version` (`vera <contract.vera_version>` on
/// `out`) or `--explain CODE` (the explanation on `out`), 2 after a
/// malformed flag or an empty argument (the reason on `err`). Stops at the first such flag, so
/// the rest of the line is never read. `args` is any iterator whose `next()`
/// returns each argument as a `?[]const u8` (`std.process.Args.Iterator`, a
/// tokenizer, a test's fixed list); `cli` borrows every argument it keeps, so
/// the iterator's storage must outlive `cli`. The lists grow in `gpa`, which
/// `Cli.deinit` takes.
pub fn parse(cli: *Cli, gpa: Allocator, args: anytype, out: *Io.Writer, err: *Io.Writer) ParseError!?u8 {
    const paths_before = cli.paths.items.len;
    var n: u32 = 0;
    while (args.next()) |arg| : (n += 1) {
        if (n == args_max) {
            try err.print("error: more than {d} arguments\n", .{args_max});
            return 2;
        }
        // No flag is empty, so this is an input, and an input reaches
        // `preprocessor.readText`, which takes no empty path.
        if (arg.len == 0) return try missing(err, "an input file", "a path");
        if (switches.get(arg)) |s| {
            if (try takeSwitch(cli, gpa, s, arg, args, out, err)) |code| return code;
        } else if (valuedKey(arg)) |v| {
            if (try takeValued(cli, v, arg, arg[std.mem.findScalar(u8, arg, '=').? + 1 ..], err)) |code| return code;
        } else if (std.mem.startsWith(u8, arg, "-D")) {
            const d = if (arg.len > 2) arg[2..] else args.next() orelse return try missing(err, "-D", "NAME[=TEXT]");
            const name = d[0 .. std.mem.findScalar(u8, d, '=') orelse d.len];
            if (!isMacroName(name)) {
                try err.print("error: -D {s}: `{s}` is not a macro name (a simple identifier, IEEE 1364-2005 3.7.1)\n", .{ d, name });
                return 2;
            }
            try cli.defines.append(gpa, d);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // --allow=X / --warn=X / --deny=X / --forbid=X
            const applied = cli.levels.parseFlag(arg[2..]) catch |e| switch (e) {
                error.CannotAllowError => {
                    try err.print("error: `{s}`: an error code cannot be allowed or warned away — it is a statement about the program, not a preference\n", .{arg});
                    return 2;
                },
                error.Forbidden => {
                    try err.print("error: `{s}`: this code was already --forbid'd\n", .{arg});
                    return 2;
                },
            };
            if (!applied) {
                try err.print("error: unknown option `{s}`\n", .{arg});
                return 2;
            }
        } else try cli.paths.append(gpa, arg);
    }
    assert(cli.paths.items.len >= paths_before);
    assert(n <= args_max);
    return null;
}

/// Refuses the well-formed flags that conflict, whatever order they came in,
/// and settles what they derive: `--display=record` beside a testbench makes
/// it print the device's records, `--sim=verilog` without a `--std` reads as
/// IEEE 1364-2005, and `--emit-rtlil`/`--emit-osdi` make `-o` name their own
/// file rather than a device. Returns null to go on, or exit status 2 with
/// the reason on `err`, or the usage when the line names no input. Runs
/// once, after `parse` returned null.
pub fn resolve(cli: *Cli, err: *Io.Writer) Io.Writer.Error!?u8 {
    // `--sim=verilog` is IEEE 1364 Verilog and the other two are Verilog-AMS
    // keyword sets, so a `--std=` of the other family conflicts.
    if (cli.sim_flag) |f| {
        const is_1364 = @backingInt(cli.language) < @backingInt(vera.KeywordSet.vams_2_3);
        if (cli.std_flag) |s| if (is_1364 != (cli.sim == .verilog)) {
            try err.print("error: `{s}` and `{s}` conflict: {s}\n", .{ f, s, if (cli.sim == .verilog) "--sim=verilog compiles IEEE 1364 Verilog" else "Verilog-A is a Verilog-AMS keyword set" });
            return 2;
        };
        if (cli.sim == .verilog and cli.std_flag == null) cli.language = .v1364_2005;
    }
    if (cli.exe_flag) |f| if (cli.display_flag == Display.drop) {
        try err.print("error: `{s}` and `--display=drop` conflict: the testbench IS the display output, and `--display=drop` discards every print\n", .{f});
        return 2;
    };
    // §9.4 a testbench over the device a host gets: it prints the records
    // the device's `say` makes, whichever flag came first.
    if (cli.exe_flag != null and cli.display_flag == Display.record) cli.display = .record;
    if (cli.validate_contract and cli.exe_flag == null) {
        try err.writeAll("error: `--validate-contract` turns the checks on in an --emit-exe or --run testbench; --check always runs them\n");
        return 2;
    }
    const elab_other: ?[]const u8 = cli.codegen_flag orelse if (cli.lint_flag) "--lint" else if (cli.emit_rtlil) "--emit-rtlil" else null;
    if (cli.elab) if (elab_other) |f| {
        try err.print("error: `--elab` and `{s}` conflict: --elab stops after elaboration\n", .{f});
        return 2;
    };
    if (cli.lint_flag) if (cli.codegen_flag) |f| {
        try err.print("error: `--lint` and `{s}` conflict: --lint stops after the frontend and `{s}` needs codegen\n", .{ f, f });
        return 2;
    };
    if (cli.lsp) {
        if (cli.lint_flag or cli.codegen_flag != null) {
            try err.print("error: `--lsp` and `{s}` conflict: the server lints each open document itself\n", .{cli.codegen_flag orelse "--lint"});
            return 2;
        }
        if (cli.paths.items.len != 0) {
            try err.writeAll("error: `--lsp` takes no input file: the editor sends the documents\n");
            return 2;
        }
        return null;
    }
    if (cli.emit_verilog) if (cli.check or cli.emit_so or cli.exe_flag != null) {
        try err.writeAll("error: `--emit-verilog` builds no device: it takes neither --check, --emit-so, --emit-exe nor --run\n");
        return 2;
    };
    if (cli.emit_rtlil) {
        if (cli.check or cli.emit_so or cli.emit_zig_typed or cli.exe_flag != null or cli.emit_verilog) {
            try err.writeAll("error: `--emit-rtlil` builds no device: it takes neither --check, --emit-zig, --emit-so, --emit-verilog, --emit-exe nor --run\n");
            return 2;
        }
        cli.emit_zig = false; // `-o` names the RTLIL file
    }
    if (cli.emit_osdi) {
        if (cli.dyn_path != null or cli.emit_zig_typed or cli.exe_flag != null) {
            try err.writeAll("error: `--emit-osdi` builds under this vera's own OSDI dyn: it takes neither --dyn, --emit-zig, --emit-exe nor --run\n");
            return 2;
        }
        cli.emit_zig = false; // `-o` names the .osdi
    }
    // A testbench is its own artifact: beside it a library or a device text
    // was silently not built. `-o` names the executable, so only a typed
    // `--emit-zig` conflicts.
    if (cli.exe_flag) |f| if (cli.emit_so or cli.emit_zig_typed) {
        try err.print("error: `{s}` and `{s}` conflict: one run builds one artifact\n", .{ f, if (cli.emit_so) "--emit-so" else "--emit-zig" });
        return 2;
    };
    if (cli.paths.items.len == 0) {
        try err.writeAll(usage_text);
        return 2;
    }
    assert(!(cli.emit_rtlil and cli.emit_zig));
    assert(!(cli.emit_osdi and cli.emit_zig));
    return null;
}

/// Prints `error: <flag> needs <what>` on `w`; returns exit status 2.
pub fn missing(w: *Io.Writer, flag: []const u8, what: []const u8) Io.Writer.Error!u8 {
    assert(flag.len != 0);
    assert(what.len != 0);
    try w.print("error: {s} needs {s}\n", .{ flag, what });
    return 2;
}

// ---- private ----

/// Applies one `switches` row; reads its value from `args` when it takes one.
fn takeSwitch(cli: *Cli, gpa: Allocator, s: Switch, arg: []const u8, args: anytype, out: *Io.Writer, err: *Io.Writer) ParseError!?u8 {
    assert(arg.len != 0);
    assert(switches.get(arg) == s);
    switch (s) {
        .help => {
            try out.writeAll(usage_text);
            return 0;
        },
        .version => {
            try out.writeAll("vera " ++ vera_version ++ "\n");
            return 0;
        },
        .explain => {
            const name = args.next() orelse return try missing(err, "--explain", "a code, e.g. --explain W0650");
            const code = std.meta.stringToEnum(diag.Code, name) orelse {
                try err.print("error: unknown diagnostic code `{s}`\n", .{name});
                return 2;
            };
            try diag.explain(code, out, if (cli.color == .never) .off else .on);
            return 0;
        },
        .lint => cli.lint_flag = true,
        .elab => cli.elab = true,
        .lsp => cli.lsp = true,
        .emit_zig => {
            cli.emit_zig = true;
            cli.emit_zig_typed = true;
            cli.codegen_flag = arg;
        },
        .emit_verilog => {
            cli.emit_verilog = true;
            cli.codegen_flag = arg;
        },
        .emit_rtlil => {
            cli.emit_rtlil = true;
            cli.codegen_flag = arg;
        },
        .digital_pins => cli.digital_pins = try pathValue(args, err, arg, "a list of ports or a file") orelse return 2,
        .power_pins => cli.power_pins = true,
        .check => {
            cli.check = true;
            cli.codegen_flag = arg;
        },
        .emit_so => {
            cli.emit_so = true;
            cli.codegen_flag = arg;
        },
        .emit_osdi => {
            cli.emit_so = true;
            cli.emit_osdi = true;
            cli.codegen_flag = arg;
        },
        .emit_exe, .run => {
            // The testbench IS the display output, so asking for one and then
            // dropping the prints would build an artifact with nothing to say.
            cli.run_exe = cli.run_exe or s == .run;
            cli.display = .emit;
            cli.codegen_flag = arg;
            cli.exe_flag = arg;
        },
        .validate_contract => cli.validate_contract = true,
        .jac_f32 => cli.jac_f32 = true,
        .jac_f32_host => cli.jac_f32_host = true,
        .contract => cli.contract_path = try pathValue(args, err, arg, "a path") orelse return 2,
        .param => {
            const kv = args.next() orelse return try missing(err, "--param", "NAME=VALUE");
            const eq = std.mem.findScalar(u8, kv, '=') orelse return try missing(err, "--param", "NAME=VALUE");
            // A string parameter takes the text; a numeric one refuses a NaN
            // once its type is known (the analysis, the digital elaboration).
            const text = kv[eq + 1 ..];
            const value = std.fmt.parseFloat(f64, text) catch std.math.nan(f64);
            try cli.overrides.append(gpa, .{ .name = kv[0..eq], .value = value, .text = text });
        },
        .dyn => cli.dyn_path = try pathValue(args, err, arg, "a path") orelse return 2,
        .work_dir => cli.work_dir = try pathValue(args, err, arg, "a directory") orelse return 2,
        .debug_info => cli.debug_info = true,
        .zig => cli.zig_exe = try pathValue(args, err, arg, "a path") orelse return 2,
        .negative_timing => cli.negative_timing = true,
        .two_state => {
            cli.logic = .two;
            cli.logic_flag = arg;
        },
        .out => {
            cli.out_path = try pathValue(args, err, arg, "a path") orelse return 2;
            cli.emit_zig = true;
            cli.codegen_flag = arg;
        },
        .spice => cli.spice_path = try pathValue(args, err, arg, "a path") orelse return 2,
        .libmap => try cli.libmaps.append(gpa, try pathValue(args, err, arg, "a library map file") orelse return 2),
        .protect_keys => cli.protect_keys = try pathValue(args, err, arg, "a key file") orelse return 2,
        .library => try cli.search.append(gpa, args.next() orelse return try missing(err, "-L", "a library name")),
        .include => try cli.include_dirs.append(gpa, try pathValue(args, err, arg, "a directory") orelse return 2),
        .no_std_defs => cli.std_defs = false,
        .json => cli.json = true,
        .text => cli.json = false,
        .color_always => cli.color = .always,
        .color_never => cli.color = .never,
        .color_auto => cli.color = .auto,
    }
    return null;
}

/// The `valued` row whose `--name=` begins `arg`, if any.
fn valuedKey(arg: []const u8) ?Valued {
    assert(arg.len != 0);
    const eq = std.mem.findScalar(u8, arg, '=') orelse return null;
    return valued.get(arg[0 .. eq + 1]);
}

/// Applies one `valued` row to the `value` after its `=`.
fn takeValued(cli: *Cli, v: Valued, arg: []const u8, value: []const u8, err: *Io.Writer) Io.Writer.Error!?u8 {
    assert(valuedKey(arg) == v);
    assert(std.mem.endsWith(u8, arg, value));
    switch (v) {
        .vdd => {
            cli.vdd = std.fmt.parseFloat(f64, value) catch 0;
            if (!(cli.vdd > 0) or !std.math.isFinite(cli.vdd)) {
                try err.print("error: `{s}`: not a positive number\n", .{arg});
                return 2;
            }
        },
        .display => {
            const d = std.meta.stringToEnum(Display, value) orelse {
                try err.print("error: unknown option `{s}`\n", .{arg});
                return 2;
            };
            cli.display = d;
            cli.display_flag = d;
        },
        .optimize => cli.optimize = optimize_names.get(value) orelse {
            try err.print("error: `{s}`: not Debug|ReleaseSafe|ReleaseFast|ReleaseSmall\n", .{arg});
            return 2;
        },
        .state => {
            cli.logic = if (std.mem.eql(u8, value, "auto")) .auto else if (std.mem.eql(u8, value, "2")) .two else if (std.mem.eql(u8, value, "4")) .four else {
                try err.print("error: `{s}`: not auto|2|4\n", .{arg});
                return 2;
            };
            cli.logic_flag = arg;
        },
        .schedule => cli.schedule = std.meta.stringToEnum(native.Schedule, value) orelse {
            try err.print("error: `{s}`: not static|fifo\n", .{arg});
            return 2;
        },
        .event_budget => {
            cli.event_budget = std.fmt.parseInt(u64, value, 10) catch 0;
            if (cli.event_budget == 0) {
                try err.print("error: `{s}`: not a positive integer\n", .{arg});
                return 2;
            }
        },
        .zig_backend => cli.zig_backend = if (std.mem.eql(u8, value, "auto")) null else if (std.mem.eql(u8, value, "llvm")) .llvm else if (std.mem.eql(u8, value, "native")) .self_hosted else {
            try err.print("error: `{s}`: not auto|llvm|native\n", .{arg});
            return 2;
        },
        .expect_module => cli.expect_module = value,
        .std => {
            const set = vera.KeywordSet.fromSpecifier(value) orelse {
                try err.print("error: `{s}`: not a `begin_keywords version specifier\n", .{arg});
                return 2;
            };
            // VerA compiles Verilog-AMS as VAMS-2023 only. "VAMS-2.3" stays a
            // `begin_keywords specifier in source, which §10.6 requires.
            if (set == .vams_2_3) {
                try err.print("error: `{s}`: Verilog-AMS is compiled as VAMS-2023; use `begin_keywords \"VAMS-2.3\" in the source for its keyword set\n", .{arg});
                return 2;
            }
            cli.language = set;
            cli.std_flag = arg;
        },
        .sim => {
            cli.sim = vera.Sim.fromFlag(value) orelse {
                try err.print("error: `{s}`: not verilogAMS|verilogA|verilog\n", .{arg});
                return 2;
            };
            cli.sim_flag = arg;
        },
        .discipline_resolution => cli.discipline_resolution = std.meta.stringToEnum(vera.DisciplineResolution, value) orelse {
            try err.print("error: `{s}`: not basic|detail\n", .{arg});
            return 2;
        },
        .unknown_bound => {
            const b = std.fmt.parseFloat(f64, value) catch std.math.nan(f64);
            if (std.math.isNan(b)) {
                try err.print("error: `{s}` is not a number\n", .{arg});
                return 2;
            }
            cli.unknown_bound = b;
        },
    }
    return null;
}

/// The value after the path-valued `flag`, or null once `missing` printed
/// `error: <flag> needs <what>`: the line ended there, or the value is empty,
/// which names no file. Every path flag reads its value here, so an empty
/// one is refused before anything opens or spawns it (#47).
fn pathValue(args: anytype, err: *Io.Writer, flag: []const u8, what: []const u8) Io.Writer.Error!?[]const u8 {
    assert(switches.get(flag) != null);
    assert(what.len != 0);
    const v = args.next() orelse "";
    if (v.len != 0) return v;
    _ = try missing(err, flag, what);
    return null;
}

/// A simple identifier (IEEE 1364-2005 §3.7.1), what `define names.
fn isMacroName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) return false;
    return true;
}

test "parse: --help and -h print the usage on stdout, exit 0, and read no further" {
    for ([_][]const u8{ "--help", "-h" }) |flag| {
        var l: fixtures.Line = .init();
        defer l.deinit();
        try std.testing.expectEqual(@as(?u8, 0), try l.read(&.{ flag, "--no-such-flag" }));
        try std.testing.expectEqualStrings(usage_text, l.out.written());
        try std.testing.expectEqualStrings("", l.err.written());
    }
}

test "parse: --version prints contract.vera_version, which is build.zig.zon's .version" {
    // build.zig reads the manifest into `build_options.version`; contract.zig
    // ships alone to hosts, so it keeps the literal and this test holds the
    // two equal.
    try std.testing.expectEqualStrings(@import("build_options").version, vera_version);
    var l: fixtures.Line = .init();
    defer l.deinit();
    try std.testing.expectEqual(@as(?u8, 0), try l.read(&.{ "--version", "--no-such-flag" }));
    try std.testing.expectEqualStrings("vera " ++ vera_version ++ "\n", l.out.written());
    for ([_][]const u8{ "-v", "-V" }) |flag| {
        var short: fixtures.Line = .init();
        defer short.deinit();
        try std.testing.expectEqual(@as(?u8, 0), try short.read(&.{flag}));
        try std.testing.expectEqualStrings("vera " ++ vera_version ++ "\n", short.out.written());
    }
    try std.testing.expectEqualStrings("", l.err.written());
}

test "parse: --explain needs a known code, and prints it on stdout" {
    try fixtures.expectRefused(&.{"--explain"}, "error: --explain needs a code, e.g. --explain W0650\n");
    try fixtures.expectRefused(&.{ "--explain", "W9999" }, "error: unknown diagnostic code `W9999`\n");
    var l: fixtures.Line = .init();
    defer l.deinit();
    // `--color=never` first: plain text (docs/using/diagnostics.md).
    try std.testing.expectEqual(@as(?u8, 0), try l.read(&.{ "--color=never", "--explain", "W0650" }));
    try std.testing.expect(std.mem.startsWith(u8, l.out.written(), "W0650: "));
    try std.testing.expect(std.mem.findScalar(u8, l.out.written(), 0x1b) == null);
}

test "parse: a flag that takes a value refuses a line that ends before it" {
    const cases = [_][2][]const u8{
        .{ "--digital-pins", "error: --digital-pins needs a list of ports or a file\n" },
        .{ "--contract", "error: --contract needs a path\n" },
        .{ "--param", "error: --param needs NAME=VALUE\n" },
        .{ "--dyn", "error: --dyn needs a path\n" },
        .{ "--work-dir", "error: --work-dir needs a directory\n" },
        .{ "--zig", "error: --zig needs a path\n" },
        .{ "-o", "error: -o needs a path\n" },
        .{ "--spice", "error: --spice needs a path\n" },
        .{ "--libmap", "error: --libmap needs a library map file\n" },
        .{ "--protect-keys", "error: --protect-keys needs a key file\n" },
        .{ "-L", "error: -L needs a library name\n" },
        .{ "-I", "error: -I needs a directory\n" },
        .{ "-D", "error: -D needs NAME[=TEXT]\n" },
    };
    for (cases) |c| try fixtures.expectRefused(&.{c[0]}, c[1]);
}

test "parse: every path-valued flag refuses an empty path; any other is taken as typed" {
    const cases = [_][2][]const u8{
        .{ "--digital-pins", "error: --digital-pins needs a list of ports or a file\n" },
        .{ "--contract", "error: --contract needs a path\n" },
        .{ "--dyn", "error: --dyn needs a path\n" },
        .{ "--work-dir", "error: --work-dir needs a directory\n" },
        .{ "--zig", "error: --zig needs a path\n" },
        .{ "-o", "error: -o needs a path\n" },
        .{ "--spice", "error: --spice needs a path\n" },
        .{ "--libmap", "error: --libmap needs a library map file\n" },
        .{ "--protect-keys", "error: --protect-keys needs a key file\n" },
        .{ "-I", "error: -I needs a directory\n" },
    };
    for (cases) |c| try fixtures.expectRefused(&.{ c[0], "" }, c[1]);
    var l: fixtures.Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "--zig", "/opt/zig-0.17/zig" });
    try std.testing.expectEqualStrings("/opt/zig-0.17/zig", l.cli.zig_exe);
}

test "parse: the codegen flags set what they build and name themselves" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    try std.testing.expectEqual(@as(?u8, null), try l.read(&.{ "--emit-zig", "m.va" }));
    try std.testing.expect(l.cli.emit_zig and l.cli.emit_zig_typed);
    try std.testing.expectEqualStrings("--emit-zig", l.cli.codegen_flag.?);
    try std.testing.expectEqualStrings("m.va", l.cli.paths.items[0]);

    // `-o` implies the device text but is not `--emit-zig` typed.
    var o: fixtures.Line = .init();
    defer o.deinit();
    _ = try o.read(&.{ "-o", "dev.zig" });
    try std.testing.expect(o.cli.emit_zig and !o.cli.emit_zig_typed);
    try std.testing.expectEqualStrings("dev.zig", o.cli.out_path.?);
    try std.testing.expectEqualStrings("-o", o.cli.codegen_flag.?);

    var s: fixtures.Line = .init();
    defer s.deinit();
    _ = try s.read(&.{"--emit-osdi"});
    try std.testing.expect(s.cli.emit_so and s.cli.emit_osdi);
    try std.testing.expectEqualStrings("--emit-osdi", s.cli.codegen_flag.?);
}

test "parse: --run sticks once typed; the last of --emit-exe/--run names the testbench" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "--run", "--emit-exe" });
    try std.testing.expect(l.cli.run_exe);
    try std.testing.expectEqualStrings("--emit-exe", l.cli.exe_flag.?);
    try std.testing.expectEqual(Display.emit, l.cli.display);

    var e: fixtures.Line = .init();
    defer e.deinit();
    _ = try e.read(&.{"--emit-exe"});
    try std.testing.expect(!e.cli.run_exe);
}

test "parse: the last --display wins, as typed; any other mode is an unknown option" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "--display=drop", "--display=emit" });
    try std.testing.expectEqual(Display.emit, l.cli.display);
    try std.testing.expectEqual(@as(?Display, .emit), l.cli.display_flag);
    _ = try l.read(&.{"--display=record"});
    try std.testing.expectEqual(@as(?Display, .record), l.cli.display_flag);
    _ = try l.read(&.{"--display=drop"});
    try std.testing.expectEqual(Display.drop, l.cli.display);
    try std.testing.expectEqual(@as(?Display, .drop), l.cli.display_flag);
    try fixtures.expectRefused(&.{"--display=say"}, "error: unknown option `--display=say`\n");
    try fixtures.expectRefused(&.{"--display="}, "error: unknown option `--display=`\n");
}

test "parse: --vdd is a positive finite number" {
    for ([_][]const u8{ "--vdd=0", "--vdd=-1", "--vdd=nan", "--vdd=inf", "--vdd=", "--vdd=1.2V" }) |flag| {
        var buf: [64]u8 = undefined;
        try fixtures.expectRefused(&.{flag}, try std.mem.print(&buf, "error: `{s}`: not a positive number\n", .{flag}));
    }
    var l: fixtures.Line = .init();
    defer l.deinit();
    _ = try l.read(&.{"--vdd=3.3"});
    try std.testing.expectEqual(@as(f64, 3.3), l.cli.vdd);
}

test "parse: --param splits at the first `=` and keeps the text beside the number" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "--param", "r=1e3", "--param", "w=-0.5", "--param", "s=1=2" });
    try std.testing.expectEqual(@as(usize, 3), l.cli.overrides.items.len);
    try std.testing.expectEqualStrings("r", l.cli.overrides.items[0].name);
    try std.testing.expectEqual(@as(f64, 1000), l.cli.overrides.items[0].value);
    try std.testing.expectEqual(@as(f64, -0.5), l.cli.overrides.items[1].value);
    // The first `=` splits, so the value is `1=2`: a string, not a number.
    try std.testing.expectEqualStrings("1=2", l.cli.overrides.items[2].text);
    try std.testing.expect(std.math.isNan(l.cli.overrides.items[2].value));
    try fixtures.expectRefused(&.{ "--param", "r" }, "error: --param needs NAME=VALUE\n");
}

test "parse: a NaN --unknown-bound is not a number" {
    // A NaN compliance limit makes `[-|B|, |B|]` an interval
    // no comparison holds in, so the W0650 proof would rest on nothing.
    try fixtures.expectRefused(&.{"--unknown-bound=nan"}, "error: `--unknown-bound=nan` is not a number\n");
    var l: fixtures.Line = .init();
    defer l.deinit();
    _ = try l.read(&.{"--unknown-bound=100"});
    try std.testing.expectEqual(@as(?f64, 100), l.cli.unknown_bound);
    try fixtures.expectRefused(&.{"--unknown-bound=x"}, "error: `--unknown-bound=x` is not a number\n");
}

test "parse: --optimize takes the four Zig mode names as the flag always spelled them" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    const modes = [_]struct { []const u8, std.lang.Optimize }{
        .{ "--optimize=Debug", .debug },
        .{ "--optimize=ReleaseSafe", .safe },
        .{ "--optimize=ReleaseFast", .fast },
        .{ "--optimize=ReleaseSmall", .small },
    };
    for (modes) |m| {
        _ = try l.read(&.{m[0]});
        try std.testing.expectEqual(m[1], l.cli.optimize.?);
    }
    // 0.17's own tag names are not the flag's.
    try fixtures.expectRefused(&.{"--optimize=fast"}, "error: `--optimize=fast`: not Debug|ReleaseSafe|ReleaseFast|ReleaseSmall\n");
}

test "parse: --state/--two-state, --schedule and --zig-backend" {
    const Logic = native.Logic;
    var l: fixtures.Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "--two-state", "--state=4" });
    try std.testing.expectEqual(Logic.four, l.cli.logic);
    try std.testing.expectEqualStrings("--state=4", l.cli.logic_flag.?);
    _ = try l.read(&.{"--state=auto"});
    try std.testing.expectEqual(Logic.auto, l.cli.logic);
    _ = try l.read(&.{"--two-state"});
    try std.testing.expectEqual(Logic.two, l.cli.logic);
    try fixtures.expectRefused(&.{"--state=3"}, "error: `--state=3`: not auto|2|4\n");

    // IEEE 1364-2005 §15.5.4's option: off unless typed.
    _ = try l.read(&.{});
    try std.testing.expect(!l.cli.negative_timing);
    _ = try l.read(&.{"--negative-timing"});
    try std.testing.expect(l.cli.negative_timing);

    _ = try l.read(&.{"--schedule=fifo"});
    try std.testing.expectEqual(native.Schedule.fifo, l.cli.schedule);
    try fixtures.expectRefused(&.{"--schedule=lifo"}, "error: `--schedule=lifo`: not static|fifo\n");

    _ = try l.read(&.{"--zig-backend=native"});
    try std.testing.expectEqual(zigbuild.Backend.self_hosted, l.cli.zig_backend.?);
    // `auto` is the default again, not a third backend.
    _ = try l.read(&.{"--zig-backend=auto"});
    try std.testing.expect(l.cli.zig_backend == null);
    try fixtures.expectRefused(&.{"--zig-backend=gcc"}, "error: `--zig-backend=gcc`: not auto|llvm|native\n");
}

test "parse: --event-budget is a positive u64" {
    for ([_][]const u8{ "--event-budget=0", "--event-budget=-5", "--event-budget=x", "--event-budget=18446744073709551616" }) |flag| {
        var buf: [96]u8 = undefined;
        try fixtures.expectRefused(&.{flag}, try std.mem.print(&buf, "error: `{s}`: not a positive integer\n", .{flag}));
    }
    var l: fixtures.Line = .init();
    defer l.deinit();
    _ = try l.read(&.{"--event-budget=18446744073709551615"});
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), l.cli.event_budget);
}

test "parse: the language, library and reporting flags" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    _ = try l.read(&.{
        "--std=1364-2005",
        "--no-std-defs",
        "--diagnostics=json",
        "--diagnostics=text",
        "--color=always",
        "--discipline-resolution=detail",
        "--libmap",
        "a.map",
        "--libmap",
        "b.map",
        "-L",
        "lib1",
        "-I",
        "inc",
        "--expect-module=",
    });
    try std.testing.expectEqual(vera.KeywordSet.v1364_2005, l.cli.language);
    try std.testing.expect(!l.cli.std_defs and !l.cli.json);
    try std.testing.expect(l.cli.color == .always);
    try std.testing.expectEqual(vera.DisciplineResolution.detail, l.cli.discipline_resolution);
    try std.testing.expectEqual(@as(usize, 2), l.cli.libmaps.items.len);
    try std.testing.expectEqualStrings("b.map", l.cli.libmaps.items[1]);
    try std.testing.expectEqualStrings("lib1", l.cli.search.items[0]);
    try std.testing.expectEqualStrings("inc", l.cli.include_dirs.items[0]);
    // An empty expected name is a name; no module is called that.
    try std.testing.expectEqualStrings("", l.cli.expect_module.?);
    try fixtures.expectRefused(&.{"--std=1800-2017"}, "error: `--std=1800-2017`: not a `begin_keywords version specifier\n");
    try fixtures.expectRefused(&.{"--std=VAMS-2.3"}, "error: `--std=VAMS-2.3`: Verilog-AMS is compiled as VAMS-2023; use `begin_keywords \"VAMS-2.3\" in the source for its keyword set\n");
    try fixtures.expectRefused(&.{"--discipline-resolution=full"}, "error: `--discipline-resolution=full`: not basic|detail\n");
}

test "parse/resolve: --sim picks the language family, and conflicts with a --std of the other one" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    try std.testing.expectEqual(@as(?u8, null), try l.settle(&.{ "--sim=verilog", "m.v" }));
    try std.testing.expectEqual(vera.Sim.verilog, l.cli.sim);
    try std.testing.expectEqual(vera.KeywordSet.v1364_2005, l.cli.language);
    var a: fixtures.Line = .init();
    defer a.deinit();
    try std.testing.expectEqual(@as(?u8, null), try a.settle(&.{ "--sim=verilogA", "--std=VAMS-2023", "m.va" }));
    try std.testing.expectEqual(vera.Sim.verilog_a, a.cli.sim);
    // A 1364 set of the user's choice stays.
    var k: fixtures.Line = .init();
    defer k.deinit();
    try std.testing.expectEqual(@as(?u8, null), try k.settle(&.{ "--sim=verilog", "--std=1364-2001", "m.v" }));
    try std.testing.expectEqual(vera.KeywordSet.v1364_2001, k.cli.language);
    try fixtures.expectRefused(&.{"--sim=vhdl"}, "error: `--sim=vhdl`: not verilogAMS|verilogA|verilog\n");
    try fixtures.expectSettled(&.{ "--sim=verilog", "--std=VAMS-2023", "m.v" }, 2, "error: `--sim=verilog` and `--std=VAMS-2023` conflict: --sim=verilog compiles IEEE 1364 Verilog\n");
    try fixtures.expectSettled(&.{ "--std=1364-2005", "--sim=verilogA", "m.va" }, 2, "error: `--sim=verilogA` and `--std=1364-2005` conflict: Verilog-A is a Verilog-AMS keyword set\n");
}

test "parse: lint levels, and what may not be allowed or un-forbidden" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    _ = try l.read(&.{"--deny=W0650"});
    try std.testing.expectEqual(diag.Level.deny, l.cli.levels.get(.W0650));
    try fixtures.expectRefused(&.{"--allow=E0310"}, "error: `--allow=E0310`: an error code cannot be allowed or warned away — " ++
        "it is a statement about the program, not a preference\n");
    try fixtures.expectRefused(&.{ "--forbid=W0650", "--allow=W0650" }, "error: `--allow=W0650`: this code was already --forbid'd\n");
    try fixtures.expectRefused(&.{"--deny=W9999"}, "error: unknown option `--deny=W9999`\n");
    try fixtures.expectRefused(&.{"--no-such-flag"}, "error: unknown option `--no-such-flag`\n");
}

test "parse: an empty input file is refused before any file is read" {
    // `preprocessor.readText` asserts a non-empty path; the command line is
    // the trust boundary that keeps that contract (the path-valued flags:
    // the test above).
    try fixtures.expectRefused(&.{""}, "error: an input file needs a path\n");
    try fixtures.expectRefused(&.{ "top.v", "" }, "error: an input file needs a path\n");
    // There is no `--spice=` form: it is an unknown option, never a path.
    try fixtures.expectRefused(&.{ "--spice=", "m.va" }, "error: unknown option `--spice=`\n");
}

test "parse: every argument that is not a flag is an input, in order" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "top.v", "-", "lib.v" });
    try std.testing.expectEqual(@as(usize, 3), l.cli.paths.items.len);
    try std.testing.expectEqualStrings("-", l.cli.paths.items[1]);
}

test "resolve: no input prints the usage on stderr" {
    try fixtures.expectSettled(&.{"--lint"}, 2, usage_text);
}

test "resolve: each conflict is refused by name, in either order" {
    const Case = struct { a: []const u8, b: []const u8, says: []const u8 };
    const cases = [_]Case{
        .{ .a = "--emit-exe", .b = "--display=drop", .says = "error: `--emit-exe` and `--display=drop` conflict: the testbench IS the display output, and `--display=drop` discards every print\n" },
        // `--lint` names the codegen flag, whichever came last.
        .{ .a = "--lint", .b = "--check", .says = "error: `--lint` and `--check` conflict: --lint stops after the frontend and `--check` needs codegen\n" },
        .{ .a = "--emit-verilog", .b = "--emit-so", .says = "error: `--emit-verilog` builds no device: it takes neither --check, --emit-so, --emit-exe nor --run\n" },
        .{ .a = "--emit-rtlil", .b = "--run", .says = "error: `--emit-rtlil` builds no device: it takes neither --check, --emit-zig, --emit-so, --emit-verilog, --emit-exe nor --run\n" },
        .{ .a = "--emit-osdi", .b = "--emit-zig", .says = "error: `--emit-osdi` builds under this vera's own OSDI dyn: it takes neither --dyn, --emit-zig, --emit-exe nor --run\n" },
        .{ .a = "--lsp", .b = "--lint", .says = "error: `--lsp` and `--lint` conflict: the server lints each open document itself\n" },
        .{ .a = "--lsp", .b = "--check", .says = "error: `--lsp` and `--check` conflict: the server lints each open document itself\n" },
        .{ .a = "--elab", .b = "--run", .says = "error: `--elab` and `--run` conflict: --elab stops after elaboration\n" },
        .{ .a = "--elab", .b = "--lint", .says = "error: `--elab` and `--lint` conflict: --elab stops after elaboration\n" },
    };
    for (cases) |c| {
        try fixtures.expectSettled(&.{ c.a, c.b, "m.va" }, 2, c.says);
        try fixtures.expectSettled(&.{ c.b, c.a, "m.va" }, 2, c.says);
    }
    try fixtures.expectSettled(&.{ "--lsp", "m.va" }, 2, "error: `--lsp` takes no input file: the editor sends the documents\n");
    try fixtures.expectSettled(&.{ "--lsp", "-I", "inc" }, null, "");
    try fixtures.expectSettled(&.{ "--validate-contract", "m.va" }, 2, "error: `--validate-contract` turns the checks on in an --emit-exe or --run testbench; --check always runs them\n");
    try fixtures.expectSettled(&.{ "--emit-osdi", "--dyn", "d.zig", "m.va" }, 2, "error: `--emit-osdi` builds under this vera's own OSDI dyn: it takes neither --dyn, --emit-zig, --emit-exe nor --run\n");
    try fixtures.expectSettled(&.{ "--run", "--emit-osdi", "m.va" }, 2, "error: `--emit-osdi` builds under this vera's own OSDI dyn: it takes neither --dyn, --emit-zig, --emit-exe nor --run\n");
}

test "resolve: a testbench prints the device's records under --display=record, whichever came first" {
    for ([_][2][]const u8{ .{ "--display=record", "--emit-exe" }, .{ "--emit-exe", "--display=record" } }) |pair| {
        var l: fixtures.Line = .init();
        defer l.deinit();
        try std.testing.expectEqual(@as(?u8, null), try l.settle(&.{ pair[0], pair[1], "m.va" }));
        try std.testing.expectEqual(Display.record, l.cli.display);
    }
    // --validate-contract is legal beside a testbench.
    try fixtures.expectSettled(&.{ "--run", "--validate-contract", "m.va" }, null, "");
}

test "resolve: --emit-rtlil makes -o name the RTLIL file, not a device text" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    try std.testing.expectEqual(@as(?u8, null), try l.settle(&.{ "--emit-rtlil", "-o", "m.il", "m.v" }));
    try std.testing.expect(l.cli.emit_rtlil and !l.cli.emit_zig);
    try std.testing.expectEqualStrings("m.il", l.cli.out_path.?);
}

test "resolve: --emit-osdi makes -o name the library, not a device text" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    try std.testing.expectEqual(@as(?u8, null), try l.settle(&.{ "-o", "m.osdi", "--emit-osdi", "m.va" }));
    try std.testing.expect(!l.cli.emit_zig);
    try std.testing.expectEqualStrings("m.osdi", l.cli.out_path.?);
}

test "resolve: one run builds one artifact: a testbench beside a library or a typed device text" {
    // The header's rule, "conflicting flags (never last-one-wins)": before,
    // `--emit-exe --emit-so` built the testbench and dropped the library.
    try fixtures.expectSettled(&.{ "--emit-exe", "--emit-so", "m.va" }, 2, "error: `--emit-exe` and `--emit-so` conflict: one run builds one artifact\n");
    try fixtures.expectSettled(&.{ "--emit-zig", "--run", "m.va" }, 2, "error: `--run` and `--emit-zig` conflict: one run builds one artifact\n");
    // `-o` beside a testbench names the executable, and `--check` builds
    // nothing, so neither conflicts.
    try fixtures.expectSettled(&.{ "--emit-exe", "-o", "tb", "m.va" }, null, "");
    try fixtures.expectSettled(&.{ "--check", "--emit-exe", "m.va" }, null, "");
}

test "parse: the switches set their field and read no value" {
    var l: fixtures.Line = .init();
    defer l.deinit();
    try std.testing.expectEqual(@as(?u8, null), try l.read(&.{
        "--lsp",        "--power-pins", "--validate-contract", "--jac-f32",      "--jac-f32-host",
        "--debug-info", "--lint",       "--color=never",       "--emit-verilog", "m.va",
    }));
    const c = l.cli;
    try std.testing.expect(c.lsp and c.power_pins and c.validate_contract and c.jac_f32 and c.jac_f32_host and c.debug_info and c.lint_flag and c.emit_verilog);
    try std.testing.expect(c.color == .never);
    try std.testing.expectEqualStrings("--emit-verilog", c.codegen_flag.?);
    try std.testing.expectEqualStrings("m.va", c.paths.items[0]);
}

test "parse: `Cli.deinit` frees every list, whichever allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fixtures.parseLine, .{});
}
