//! The simulator half of `zig build test-vpi`: a design plus a C application
//! (its `vlog_startup_routines`, LRM §12.33.2) -> the application's exit code.
//! No argument elaborates tests/verilog-ams/ch11_vpi/vpi_design.va; `<design.va> <app>` runs the
//! analog analyses the app's banner asks for (or, for `*! external` lines, runs
//! its calls at host-set points with no solution: `External`, which a
//! `*! library <design.va>` line gives a second device library with its own
//! design and a `*! instances <n>` line n instances of each); `<design.v>` runs the digital
//! engine with time and value-change callbacks. Applications are real C against
//! src/vpi/vpi_user.h, so the ABI itself is under test.

const std = @import("std");
const builtin = @import("builtin");
const DynLib = @import("dynlib").DynLib;
const vera = @import("vera");
const vpi = @import("vpi");
const sim = @import("sim");
const host_options = @import("vpi_host_options");

const Io = std.Io;

/// C's `main`, because this file is built ONCE as a static library and linked
/// into one executable per application: the application is the C half, and a
/// Zig executable per fixture would recompile the whole engine per fixture.
/// The C runtime's, on Windows: `_O_BINARY` keeps an application's `printf`
/// from writing `\r\n`, so its stdout is the bytes build.zig expects.
extern "c" fn _setmode(fd: c_int, mode: c_int) c_int;

export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    if (builtin.os.tag == .windows) {
        _ = _setmode(1, 0x8000);
        _ = _setmode(2, 0x8000);
    }
    // §12.17: the invocation a vpi_get_vlog_info() reports is this one.
    vpi.setInvocation(argc, @ptrCast(@constCast(argv)));
    // §12.26's log file: the application's name with `.log`, in the cwd.
    var log_buf: [256]u8 = undefined;
    const app_name = std.fs.path.basename(std.mem.span(argv[0]));
    vpi.setLogFile(std.mem.print(&log_buf, "{s}.log", .{app_name}) catch "vera.log") catch {};
    const code = host(if (argc > 1) std.mem.span(argv[1]) else null, if (argc > 2) std.mem.span(argv[2]) else null) catch |e| {
        std.debug.print("vpi_host: {t}\n", .{e});
        return 1;
    };
    return code;
}

fn host(design: ?[]const u8, app: ?[]const u8) !u8 {
    if (design) |path| return if (std.mem.endsWith(u8, path, ".va")) analogHost(path, app) else digitalHost(path);

    // The design is compiled at `.lint`: P01 models DECLARATIONS, so nothing
    // below stage 5 is needed and no `zig` child has to be spawned to run the
    // acceptance test.
    var res = vera.compileSource(std.heap.page_allocator, @embedFile("vpi_design"), .lint) catch |err| {
        std.debug.print("vpi_host: the design did not compile: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer res.deinit();

    try vpi.open(std.heap.page_allocator, &res);
    defer vpi.close();

    // §12.33.2, then cbEndOfCompile: the acceptance test registers at
    // startup (IEEE 1364-2005 §26.2.4) and asserts everything from there.
    vpi.runStartupRoutines();
    vpi.callback.endOfCompile();
    return 0;
}

/// An analog design, opened as `vpi.open` models it. When the application's
/// banner asks for analyses, the device is built as a shared library and
/// `vpi.analog_run` walks them. The include path is the design's directory and
/// the corpus's `include/` two above it (`tests/<lang>/<chapter>/x.va`), where
/// the suite keeps `check.vh`.
fn analogHost(path: []const u8, app: ?[]const u8) !u8 {
    const io = Io.Threaded.global_single_threaded.io();
    const gpa = std.heap.page_allocator;
    const source = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(source);
    const dir = std.fs.path.dirname(path) orelse ".";
    const up = try std.fs.path.join(gpa, &.{ dir, "..", "..", "include" });
    defer gpa.free(up);
    var res = vera.compileSourceOpts(gpa, source, .lint, .{ .file_name = path, .include_dirs = &.{ dir, up } }) catch |e| {
        std.debug.print("vpi_host: `{s}` did not compile: {t}\n", .{ path, e });
        return 1;
    };
    defer res.deinit();
    try vpi.open(gpa, &res);
    defer vpi.close();

    // The analyses the application asks for (`*! analysis` lines in its
    // banner, grammar at `readAnalyses`). None: declarations only.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const analyses = if (app) |c| try readAnalyses(arena, io, c) else &.{};
    const points = if (app) |c| try readPoints(arena, io, c) else &.{};
    if (analyses.len != 0 and points.len != 0) return error.BadAnalysis;
    const second = if (app) |c| try bannerWord(arena, io, c, "*! library") else null;
    const instances = if (app) |c| (if (try bannerWord(arena, io, c, "*! instances")) |w| try std.fmt.parseInt(usize, w, 10) else 1) else 1;
    // A second library and several instances are the external host's shape.
    if ((second != null or instances != 1) and points.len == 0) return error.BadAnalysis;
    // §12.33.2 the registrations come before the device is built: a call's
    // type is its function's sysfunctype (§12.32.1), which compiling needs.
    vpi.runStartupRoutines();
    var loaded: ?DynLib = null;
    defer if (loaded) |*l| l.close();
    var loaded2: ?DynLib = null;
    defer if (loaded2) |*l| l.close();
    // The design's own library, on the installed design; a second one with
    // its own (VerA #84). Detached before the libraries close and the
    // design does: these defers run first.
    var binding: vpi.analog_run.Binding = .{};
    defer binding.detach();
    var binding2: vpi.analog_run.Binding = .{};
    defer binding2.detach();
    if (analyses.len != 0 or points.len != 0) {
        // Building the library spawns `zig`, which the global single-threaded
        // Io cannot do (no allocator, no environment): a real one, over this
        // process's own environment.
        var threaded: Io.Threaded = .init(gpa, .{
            .environ = .{
                .block = switch (builtin.os.tag) {
                    .windows => .global, // the process's own block, read by std
                    else => .{ .slice = std.mem.span(@as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ))) },
                },
            },
        });
        defer threaded.deinit();
        const lib_path = buildAnalogLib(gpa, arena, threaded.io(), path, std.fs.path.stem(app.?), source, &.{ dir, up }, try vpi.systf.intAnalogNames(arena)) catch |e| {
            std.debug.print("vpi_host: `{s}` has no analog library: {t}\n", .{ path, e });
            return 1;
        };
        loaded = try DynLib.open(lib_path);
        const real = try bindLib(&loaded.?);
        try binding.attach(if (points.len != 0) External.lib(real) else real, null);
        if (second) |name| {
            const path2 = try std.fs.path.join(arena, &.{ dir, name });
            const source2 = try Io.Dir.cwd().readFileAlloc(io, path2, arena, .limited(16 * 1024 * 1024));
            var res2 = vera.compileSourceOpts(gpa, source2, .lint, .{ .file_name = path2, .include_dirs = &.{ dir, up } }) catch |e| {
                std.debug.print("vpi_host: `{s}` did not compile: {t}\n", .{ path2, e });
                return 1;
            };
            defer res2.deinit();
            // Its own work directory: two libraries built into one race.
            const stem2 = try arena.print("{s}-library", .{std.fs.path.stem(app.?)});
            const lib2_path = buildAnalogLib(gpa, arena, threaded.io(), path2, stem2, source2, &.{ dir, up }, try vpi.systf.intAnalogNames(arena)) catch |e| {
                std.debug.print("vpi_host: `{s}` has no analog library: {t}\n", .{ path2, e });
                return 1;
            };
            loaded2 = try DynLib.open(lib2_path);
            const lib2 = External.lib(try bindLib(&loaded2.?));
            try binding2.attach(lib2, try vpi.buildDesign(gpa, &res2));
        }
    }

    vpi.callback.endOfCompile();
    if (points.len != 0) {
        const all = [_]*vpi.analog_run.Binding{ &binding, &binding2 };
        return External.run(points, all[0..if (second != null) 2 else 1], instances);
    }
    if (analyses.len == 0) return 0;
    vpi.callback.startOfSimulation();
    for (analyses) |a| binding.run(a) catch |e| {
        std.debug.print("vpi_host: the {t} analysis of `{s}` failed: {t}\n", .{ a.kind, path, e });
        return 1;
    };
    vpi.callback.endOfSimulation();
    return 0;
}

/// The banner's `*! analysis <op | tran <start> <stop> [<max step>] |
/// ac <fstart> <fstop> <points>>`, one per line, run in order. Numbers take
/// SPICE's scale suffixes, as the banners write them (`tran 0 5m`). An `ac`
/// sweep's points are evenly spaced, both ends included.
fn readAnalyses(arena: std.mem.Allocator, io: Io, c_path: []const u8) ![]const vpi.analog_run.Analysis {
    const text = try Io.Dir.cwd().readFileAlloc(io, c_path, arena, .limited(1 << 20));
    var out: std.ArrayList(vpi.analog_run.Analysis) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "*! analysis")) continue;
        var words = std.mem.tokenizeAny(u8, line["*! analysis".len..], " \t");
        const kind = words.next() orelse return error.BadAnalysis;
        if (std.mem.eql(u8, kind, "op")) {
            try out.append(arena, .{ .kind = .op });
        } else if (std.mem.eql(u8, kind, "tran")) {
            const start = try spiceNumber(words.next() orelse return error.BadAnalysis);
            const stop = try spiceNumber(words.next() orelse return error.BadAnalysis);
            const step = if (words.next()) |w| try spiceNumber(w) else 0;
            try out.append(arena, .{ .kind = .tran, .start = start, .stop = stop, .max_step = step });
        } else if (std.mem.eql(u8, kind, "ac")) {
            const fstart = try spiceNumber(words.next() orelse return error.BadAnalysis);
            const fstop = try spiceNumber(words.next() orelse return error.BadAnalysis);
            const points = try std.fmt.parseInt(u32, words.next() orelse return error.BadAnalysis, 10);
            if (points == 0 or fstart <= 0 or fstop < fstart) return error.BadAnalysis;
            try out.append(arena, .{ .kind = .ac, .fstart = fstart, .fstop = fstop, .points = points });
        } else return error.UnsupportedAnalysis;
    }
    return out.items;
}

/// The first word after `key` on the banner's first line opening with it,
/// or null when no line does (`*! library <file.va>`, `*! instances <n>`).
fn bannerWord(arena: std.mem.Allocator, io: Io, c_path: []const u8, key: []const u8) !?[]const u8 {
    const text = try Io.Dir.cwd().readFileAlloc(io, c_path, arena, .limited(1 << 20));
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        var words = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        return words.next() orelse error.BadAnalysis;
    }
    return null;
}

/// The banner's `*! external <op | tran | ac> <t> <dt> <freq>` lines: the
/// points `External.run` stands a calltf on, in order.
fn readPoints(arena: std.mem.Allocator, io: Io, c_path: []const u8) ![]const External.Point {
    const text = try Io.Dir.cwd().readFileAlloc(io, c_path, arena, .limited(1 << 20));
    var out: std.ArrayList(External.Point) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "*! external")) continue;
        var words = std.mem.tokenizeAny(u8, line["*! external".len..], " \t");
        const kind = std.meta.stringToEnum(vpi.analog_run.Kind, words.next() orelse return error.BadAnalysis) orelse return error.UnsupportedAnalysis;
        var v: [3]f64 = undefined;
        for (&v) |*x| x.* = try spiceNumber(words.next() orelse return error.BadAnalysis);
        try out.append(arena, .{ .kind = kind, .t = v[0], .dt = v[1], .freq = v[2] });
    }
    return out.items;
}

/// ESPice's shape (VerA #83, #84): a host that solves the circuit itself and
/// binds VerA only to run the application's calltf. Each `Lib` is a built
/// library's call table with no solution (`n_u = n_rows = n_shares = 0`), so
/// `vpi_get_analog_value` refuses NOSOLUTION; its hop is unused, since this
/// host calls `Binding.call` directly, as its `contract.SystfHost.call`
/// would. It sets each point with `analog_run.setPoint`, then, per library
/// and per instance, calls every call once with no arguments.
const External = struct {
    const Point = struct { kind: vpi.analog_run.Kind, t: f64, dt: f64, freq: f64 };
    const none = [0]f64{};

    fn zero() callconv(.c) usize {
        return 0;
    }
    fn x() callconv(.c) [*]const f64 {
        return &none;
    }
    fn ignore(_: ?*anyopaque, _: ?vpi.analog_run.HostCall, _: ?vpi.analog_run.HostOut) callconv(.c) void {}
    fn lib(real: vpi.analog_run.Lib) vpi.analog_run.Lib {
        var l = real;
        l.n_u = zero;
        l.n_rows = zero;
        l.n_shares = zero;
        l.x = x;
        l.systf = ignore;
        return l;
    }
    fn run(points: []const Point, bindings: []const *vpi.analog_run.Binding, instances: usize) u8 {
        vpi.callback.startOfSimulation();
        for (points) |p| {
            vpi.analog_run.setPoint(.{ .kind = p.kind }, p.t, p.dt, p.freq);
            for (bindings) |b| for (0..instances) |i| for (0..b.lib.?.n_systf()) |k| {
                _ = b.call(i, k, &.{}, &.{});
            };
        }
        vpi.analog_run.setPoint(null, 0, 0, 0);
        vpi.callback.endOfSimulation();
        return 0;
    }
};

fn spiceNumber(w: []const u8) !f64 {
    const scales = [_]struct { s: []const u8, v: f64 }{
        .{ .s = "meg", .v = 1e6 }, .{ .s = "f", .v = 1e-15 }, .{ .s = "p", .v = 1e-12 },
        .{ .s = "n", .v = 1e-9 },  .{ .s = "u", .v = 1e-6 },  .{ .s = "m", .v = 1e-3 },
        .{ .s = "k", .v = 1e3 },   .{ .s = "g", .v = 1e9 },   .{ .s = "t", .v = 1e12 },
    };
    for (scales) |sc| if (std.ascii.endsWithIgnoreCase(w, sc.s)) {
        return (try std.fmt.parseFloat(f64, w[0 .. w.len - sc.s.len])) * sc.v;
    };
    return std.fmt.parseFloat(f64, w);
}

/// The design's device and the fixed solver as a shared library
/// (`vera.tb.renderVpiLib`), compiled with the §5.6 rows published
/// (`vpi_contribs`) and the display tasks real, into the build's work root.
/// Built under the APPLICATION's name: several applications run one design
/// at once under `zig build`, and two compilers writing one directory race.
fn buildAnalogLib(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, path: []const u8, app_stem: []const u8, source: []const u8, include: []const []const u8, int_systfs: []const []const u8) ![]const u8 {
    var bag = vera.diag.Bag.init(arena);
    var res = vera.compileSourceOpts(gpa, source, .build, .{
        .file_name = path,
        .include_dirs = include,
        .display = .emit,
        .vpi_contribs = true,
        .int_systfs = int_systfs,
        .diags = &bag,
    }) catch |e| {
        try vera.diag.render(&bag, stderrWriter(), .{});
        return e;
    };
    defer res.deinit();
    const device = try res.generateDevice();
    if (res.device_has_compile_error) return error.CodegenRefused;
    const stem = std.fs.path.stem(path);
    var d = try vera.tb.parse(arena, source);
    d.validate_contract = true;
    const runner = try vera.tb.renderVpiLib(arena, stem, d);
    const work = try std.fs.path.join(arena, &.{ host_options.work_root, app_stem });
    const t = &builtin.target;
    const out = try arena.print("{s}/{s}{s}{s}", .{ work, t.libPrefix(), stem, t.dynamicLibSuffix() });
    const built = try vera.tb.buildExe(gpa, io, device, runner, .{
        .work_dir = work,
        .contract = host_options.contract,
        .name = res.mir.name,
        .out_path = out,
        .zig_exe = host_options.zig_exe,
        .shared_lib = true,
    });
    defer built.deinit(gpa);
    switch (built) {
        .ok => return out,
        .failed => |text| {
            std.debug.print("vpi_host: the analog library for `{s}` did not compile:\n{s}\n", .{ path, text });
            return error.LibraryFailed;
        },
    }
}

fn stderrWriter() *Io.Writer {
    const S = struct {
        var buf: [4096]u8 = undefined;
        var w: ?Io.File.Writer = null;
    };
    if (S.w == null) S.w = Io.File.stderr().writer(Io.Threaded.global_single_threaded.io(), &S.buf);
    return &S.w.?.interface;
}

fn bindLib(l: *DynLib) !vpi.analog_run.Lib {
    var out: vpi.analog_run.Lib = undefined;
    const s = @typeInfo(vpi.analog_run.Lib).@"struct";
    inline for (s.field_names, s.field_types) |name, F| {
        @field(out, name) = l.lookup(F, "vera_vpi_" ++ name) orelse return error.MissingSymbol;
    }
    return out;
}

fn digitalHost(path: []const u8) !u8 {
    const io = Io.Threaded.global_single_threaded.io();
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ebuf: [4096]u8 = undefined;
    var ew = Io.File.stderr().writer(io, &ebuf);
    const err = &ew.interface;
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    const source = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |e| {
        try err.print("vpi_host: cannot read `{s}`: {t}\n", .{ path, e });
        try err.flush();
        return 2;
    };
    // §12.33.2 first: IEEE 1364-2005 §26.2.4 allows only the two
    // registration routines there, and elaboration reads the systfs they
    // register (§20.4) and sizes them (§26.1.1).
    vpi.runStartupRoutines();
    var bag = vera.diag.Bag.init(arena);
    const dir = std.fs.path.dirname(path) orelse ".";
    var run = sim.digital.elaborate(arena, source, .{ .file_name = path, .include_dirs = &.{dir}, .io = io, .systf = vpi.systf.hook, .stmt_sites = true }, &bag, out) catch |e| {
        try vera.diag.render(&bag, err, .{});
        try err.print("vpi_host: `{s}` did not elaborate: {t}\n", .{ path, e });
        try err.flush();
        return 1;
    };
    try vpi.openDigital(std.heap.page_allocator, &run);
    defer vpi.close();

    // §12.31.4's "end of simulation data structure compilation or build",
    // then time 0.
    vpi.callback.endOfCompile();
    vpi.run.simulate() catch |e| {
        if (vpi.systf.misuse) |name| {
            try out.flush();
            try err.print("vpi_host: `{s}` is registered as a system task and called as a function (IEEE 1364-2005 §20.3)\n", .{name});
            try err.flush();
            return 1;
        }
        try out.flush();
        try vera.diag.render(&bag, err, .{});
        try err.print("vpi_host: the run of `{s}` failed: {t}\n", .{ path, e });
        try err.flush();
        return 1;
    };
    try out.flush();
    return 0;
}
