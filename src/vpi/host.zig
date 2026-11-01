//! `libvera-vpi.a`, the simulator a VPI application links against: a design
//! plus a C application (its `vlog_startup_routines`, LRM §12.33.2) -> the
//! application's exit code. Installed beside `vera` with `include/vpi_user.h`:
//! `zig cc app.c -I<prefix>/include <prefix>/lib/libvera-vpi.a -o app`, then
//! `./app <design>`. `<design.va> [<app.c>]` opens the analog design and runs
//! the analyses the app's banner asks for (or, for `*! external` lines, runs
//! its calls at host-set points with no solution: `External`, which a
//! `*! library <design.va>` line gives a second device library with its own
//! design and a `*! instances <n>` line n instances of each); `<design.v>` runs
//! the digital engine with time and value-change callbacks, decrypting its
//! §28 envelopes with the key file `$VERA_PROTECT_KEYS` names, if any.
//!
//! An analog library is built by spawning `zig` (`$VERA_ZIG`, else `zig` on
//! PATH) under `$VERA_VPI_WORK` (else `.zig-cache/vera-vpi` in the cwd), with
//! the contract this library was built with written out there.
//!
//! Contents: none (tests and file-private rows only)

const std = @import("std");
const builtin = @import("builtin");
const DynLib = @import("dynlib").DynLib;
const vera = @import("vera");
const exe = @import("exe");
const zigbuild = @import("zigbuild");
const protect = @import("frontend").protect;
const deep = @import("frontend").deep_stack;
const vpi = @import("vpi");
const sim = @import("sim");
const Io = std.Io;

/// C's `main`, because this file is built ONCE as a static library and linked
/// into one executable per application: the application is the C half, and a
/// Zig executable per application would recompile the whole engine per one.
/// The C runtime's, on Windows: `_O_BINARY` keeps an application's `printf`
/// from writing `\r\n`, so its stdout is the bytes a test expects.
extern "c" fn _setmode(fd: c_int, mode: c_int) c_int; // os: the C runtime's, declared on every target and called only on Windows

/// ESPice's shape (VerA #83, #84): a host that solves the circuit itself and
/// binds VerA only to run the application's calltf. Each `Lib` is a built
/// library's call table with no solution (`n_u = n_rows = n_shares = 0`), so
/// `vpi_get_analog_value` refuses NOSOLUTION; its hop is unused, since this
/// host calls `Binding.call` directly, as its `contract.SystfHost.call`
/// would. It sets each point with `analog.setPoint`, then, per library
/// and per instance, calls every call once with no arguments.
const External = struct {
    const Point = struct { kind: vpi.analog.Kind, t: f64, dt: f64, freq: f64 };
    const none = [0]f64{};

    // The stubs run only on a library bound to the installed design, after
    // the startup routines registered its calls (§12.33.2).
    fn zero() callconv(.c) usize {
        std.debug.assert(vpi.session.design != null);
        std.debug.assert(!vpi.session.starting);
        return 0;
    }
    fn x() callconv(.c) [*]const f64 {
        std.debug.assert(vpi.session.design != null);
        std.debug.assert(!vpi.session.starting);
        return &none;
    }
    fn ignore(_: ?*anyopaque, _: ?vpi.analog.HostCall, _: ?vpi.analog.HostOut) callconv(.c) void {
        std.debug.assert(vpi.session.design != null);
        std.debug.assert(!vpi.session.starting);
    }
    fn lib(real: vpi.analog.Lib) vpi.analog.Lib {
        var l = real;
        l.n_u = zero;
        l.n_rows = zero;
        l.n_shares = zero;
        l.x = x;
        l.systf = ignore;
        // No solution, and the device's own call table.
        std.debug.assert(l.n_u() == 0);
        std.debug.assert(l.n_systf == real.n_systf);
        return l;
    }
    fn run(points: []const Point, bindings: []const *vpi.Binding, instances: usize) u8 {
        std.debug.assert(bindings.len >= 1);
        std.debug.assert(bindings.len <= 2); // the design's library and one `*! library`
        vpi.callback_fire.startOfSimulation();
        for (points) |p| {
            vpi.analog.setPoint(.{ .kind = p.kind }, p.t, p.dt, p.freq);
            for (bindings) |b| for (0..instances) |i| for (0..b.lib.?.n_systf()) |k| {
                _ = b.call(i, k, &.{}, &.{});
            };
        }
        vpi.analog.setPoint(null, 0, 0, 0);
        vpi.callback_fire.endOfSimulation();
        std.debug.assert(vpi.analog.current == null);
        return 0;
    }
};

// ---- private ----

export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    std.debug.assert(vpi.session.design == null); // nothing opens a design before main
    if (builtin.os.tag == .windows) { // os: binary stdio is a Windows-only C runtime mode
        _ = _setmode(1, 0x8000);
        _ = _setmode(2, 0x8000);
    }
    if (argc < 2) {
        std.debug.print("usage: {s} <design.v | design.va [app.c]>\n", .{std.mem.span(argv[0])});
        return 2;
    }
    // §12.17: the invocation a vpi_get_vlog_info() reports is this one.
    vpi.session.setInvocation(argc, @ptrCast(@constCast(argv)));
    // §12.26's log file: the application's name with `.log`, in the cwd.
    var log_buf: [256]u8 = undefined;
    const app_name = std.fs.path.basename(std.mem.span(argv[0]));
    // A name past the buffer falls back to `vera.log`; only the copy can fail.
    vpi.print.setLogFile(std.mem.print(&log_buf, "{s}.log", .{app_name}) catch "vera.log") catch |e| {
        std.debug.print("vpi_host: {t}\n", .{e});
        return 1;
    };
    const design = std.mem.span(argv[1]);
    const app = if (argc > 2) std.mem.span(argv[2]) else null;
    const code = (if (std.mem.endsWith(u8, design, ".va")) analogHost(design, app) else deep.runGuarded(0, digitalHost, .{design})) catch |e| {
        std.debug.print("vpi_host: {t}\n", .{e});
        return 1;
    };
    std.debug.assert(vpi.session.design == null); // each host closes what it opened
    return code;
}

/// An analog design, opened as `vpi.session.open` models it. When the application's
/// banner asks for analyses, the device is built as a shared library and
/// `vpi.Binding.run` walks them. The include path is the design's directory and
/// the corpus's `include/` two above it (`tests/<lang>/<chapter>/x.va`), where
/// the suite keeps `check.vh`.
fn analogHost(path: []const u8, app: ?[]const u8) !u8 {
    std.debug.assert(std.mem.endsWith(u8, path, ".va"));
    std.debug.assert(vpi.session.design == null);
    const io = Io.Threaded.global_single_threaded.io();
    const gpa = std.heap.page_allocator;
    const source = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(source);
    const dir = std.fs.path.dirname(path) orelse ".";
    const up = try std.fs.path.join(gpa, &.{ dir, "..", "..", "include" });
    defer gpa.free(up);
    var res = vera.analyze(gpa, source, .{ .file_name = path, .include_dirs = &.{ dir, up } }, null) catch |e| {
        std.debug.print("vpi_host: `{s}` did not compile: {t}\n", .{ path, e });
        return 1;
    };
    defer res.deinit(gpa);
    try vpi.session.open(gpa, &res);
    defer vpi.session.close();

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
    vpi.session.runStartupRoutines();
    var loaded: ?DynLib = null;
    defer if (loaded) |*l| l.close();
    var loaded2: ?DynLib = null;
    defer if (loaded2) |*l| l.close();
    // The design's own library, on the installed design; a second one with
    // its own (VerA #84). Detached before the libraries close and the
    // design does: these defers run first.
    var binding: vpi.Binding = .{};
    defer binding.detach();
    var binding2: vpi.Binding = .{};
    defer binding2.detach();
    if (analyses.len != 0 or points.len != 0) {
        // Building the library spawns `zig`, which the global single-threaded
        // Io cannot do (no allocator, no environment): a real one, over this
        // process's own environment.
        var threaded: Io.Threaded = .init(gpa, .{
            .environ = .{
                .block = switch (builtin.os.tag) { // os: std reads the environment block differently on Windows
                    .windows => .global, // the process's own block, read by std
                    else => .{ .slice = std.mem.span(@as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ))) }, // os: the host links libc on every target
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
            var res2 = vera.analyze(gpa, source2, .{ .file_name = path2, .include_dirs = &.{ dir, up } }, null) catch |e| {
                std.debug.print("vpi_host: `{s}` did not compile: {t}\n", .{ path2, e });
                return 1;
            };
            defer res2.deinit(gpa);
            // Its own work directory: two libraries built into one race.
            const stem2 = try arena.print("{s}-library", .{std.fs.path.stem(app.?)});
            const lib2_path = buildAnalogLib(gpa, arena, threaded.io(), path2, stem2, source2, &.{ dir, up }, try vpi.systf.intAnalogNames(arena)) catch |e| {
                std.debug.print("vpi_host: `{s}` has no analog library: {t}\n", .{ path2, e });
                return 1;
            };
            loaded2 = try DynLib.open(lib2_path);
            const lib2 = External.lib(try bindLib(&loaded2.?));
            try binding2.attach(lib2, try vpi.session.buildDesign(gpa, &res2));
        }
    }

    vpi.callback_fire.endOfCompile();
    if (points.len != 0) {
        const all = [_]*vpi.Binding{ &binding, &binding2 };
        return External.run(points, all[0..if (second != null) 2 else 1], instances);
    }
    if (analyses.len == 0) return 0;
    // VAMS §8.4 a mixed-signal design: its digital half runs beside the
    // analog solve (`Binding.runMixed`), and VPI reads its variables.
    if (exe.mixedPlan(res.lowered, res.mir)) |mx| return mixedHost(arena, path, mx, analyses, &binding);
    vpi.callback_fire.startOfSimulation();
    for (analyses) |a| binding.run(a) catch |e| {
        std.debug.print("vpi_host: the {t} analysis of `{s}` failed: {t}\n", .{ a.kind, path, e });
        return 1;
    };
    vpi.callback_fire.endOfSimulation();
    return 0;
}

/// `analogHost`'s transient analyses of a mixed-signal design `mx`: the
/// digital half elaborated afresh from the compile's source, attached for
/// VPI's value reads (§12.10) and stepped by `sim.mixed.run` beside the
/// library. Refused, naming why: an analysis other than a transient, and
/// what `Binding.runMixed`'s analog side does not carry yet (an analog block
/// that reads a digital value, an explicit D2A event, an inserted connect
/// module, a digital read of an analog variable).
fn mixedHost(arena: std.mem.Allocator, path: []const u8, mx: exe.Mixed, analyses: []const vpi.analog.Analysis, binding: *vpi.Binding) !u8 {
    std.debug.assert(analyses.len != 0);
    std.debug.assert(binding.lib != null); // `analogHost` attached the design's library
    const why: ?[]const u8 = if (mx.inputs.len != 0 or mx.snaps.len != 0)
        "its analog block reads a digital value"
    else if (mx.events.len != 0)
        "it has an explicit D2A event"
    else if (mx.inserts.len != 0)
        "it inserts a connect module"
    else if (mx.reads.len != 0)
        "a digital expression reads an analog variable"
    else for (analyses) |a| {
        if (a.kind != .tran) break "only a transient analysis runs a mixed-signal design here";
    } else null;
    if (why) |w| {
        std.debug.print("vpi_host: `{s}` is a mixed-signal design, and {s}; VerA's VPI host does not run that yet\n", .{ path, w });
        return 1;
    }
    var bag = vera.diag.Bag.init(arena);
    var dout = Io.Writer.Allocating.init(arena);
    var dig = sim.digital.elaborate(arena, mx.source, .{ .mixed = .{ .top = mx.top, .timescales = mx.timescales } }, &bag, &dout.writer) catch |e| {
        try vera.diag.render(&bag, stderrWriter(), .{});
        std.debug.print("vpi_host: the digital half of `{s}` did not elaborate: {t}\n", .{ path, e });
        return 1;
    };
    vpi.run.attach(&dig);
    defer vpi.run.detach();
    // §12.10 the design's objects the digital half holds read its slots:
    // each named as the digital engine names it, relative to the root.
    const prefix = try std.mem.concat(arena, u8, &.{ mx.top, "." });
    for (vpi.session.design.?.objects) |*o| switch (o.kind) {
        .net, .reg, .integer, .real_var, .time_var => if (o.slot == .none) if (std.mem.startsWith(u8, o.full, prefix)) {
            if (dig.slotOf(o.full[prefix.len..])) |at| o.slot = .of(at);
        },
        else => {},
    };
    vpi.callback_fire.startOfSimulation();
    for (analyses) |a| binding.runMixed(a, &dig, sim.time.secondsAt(1, dig.time.finest), mx.probe_names, mx.probe_nodes) catch |e| {
        try vera.diag.render(&bag, stderrWriter(), .{});
        std.debug.print("vpi_host: the {t} analysis of `{s}` failed: {t}\n", .{ a.kind, path, e });
        return 1;
    };
    vpi.callback_fire.endOfSimulation();
    // The digital half's own §17.1 output, after the run.
    std.debug.print("{s}", .{dout.written()});
    return 0;
}

/// The banner's `*! analysis <op | tran <start> <stop> [<max step>] |
/// ac <fstart> <fstop> <points>>`, one per line, run in order. Numbers take
/// SPICE's scale suffixes, as the banners write them (`tran 0 5m`). An `ac`
/// sweep's points are evenly spaced, both ends included.
fn readAnalyses(arena: std.mem.Allocator, io: Io, c_path: []const u8) ![]const vpi.analog.Analysis {
    std.debug.assert(c_path.len != 0);
    const text = try Io.Dir.cwd().readFileAlloc(io, c_path, arena, .limited(1 << 20));
    var out: std.ArrayList(vpi.analog.Analysis) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var seen: usize = 0;
    while (lines.next()) |raw| : (seen += 1) {
        std.debug.assert(seen <= text.len); // a line per newline, and the last
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
    std.debug.assert(out.items.len <= seen);
    return out.items;
}

/// The first word after `key` on the banner's first line opening with it,
/// or null when no line does (`*! library <file.va>`, `*! instances <n>`).
fn bannerWord(arena: std.mem.Allocator, io: Io, c_path: []const u8, key: []const u8) !?[]const u8 {
    std.debug.assert(c_path.len != 0);
    std.debug.assert(std.mem.startsWith(u8, key, "*! ")); // a banner key
    const text = try Io.Dir.cwd().readFileAlloc(io, c_path, arena, .limited(1 << 20));
    var lines = std.mem.splitScalar(u8, text, '\n');
    var seen: usize = 0;
    while (lines.next()) |raw| : (seen += 1) {
        std.debug.assert(seen <= text.len); // a line per newline, and the last
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
    std.debug.assert(c_path.len != 0);
    const text = try Io.Dir.cwd().readFileAlloc(io, c_path, arena, .limited(1 << 20));
    var out: std.ArrayList(External.Point) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var seen: usize = 0;
    while (lines.next()) |raw| : (seen += 1) {
        std.debug.assert(seen <= text.len); // a line per newline, and the last
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "*! external")) continue;
        var words = std.mem.tokenizeAny(u8, line["*! external".len..], " \t");
        const kind = std.meta.stringToEnum(vpi.analog.Kind, words.next() orelse return error.BadAnalysis) orelse return error.UnsupportedAnalysis;
        var v: [3]f64 = undefined;
        for (&v) |*x| x.* = try spiceNumber(words.next() orelse return error.BadAnalysis);
        try out.append(arena, .{ .kind = kind, .t = v[0], .dt = v[1], .freq = v[2] });
    }
    std.debug.assert(out.items.len <= seen);
    return out.items;
}

fn spiceNumber(w: []const u8) !f64 {
    // A token from `tokenizeAny`: never empty, never spaced.
    std.debug.assert(w.len != 0);
    std.debug.assert(std.mem.findAny(u8, w, " \t") == null);
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
/// (`exe.writeVpiLib`), compiled with the §5.6 rows published
/// (`vpi_contribs`) and the display tasks real, into the build's work root.
/// Built under the APPLICATION's name: several applications run one design
/// at once under `zig build`, and two compilers writing one directory race.
fn buildAnalogLib(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, path: []const u8, app_stem: []const u8, source: []const u8, include: []const []const u8, int_systfs: []const []const u8) ![]const u8 {
    std.debug.assert(app_stem.len != 0); // one work directory per application
    std.debug.assert(include.len != 0);
    var bag = vera.diag.Bag.init(gpa);
    defer bag.deinit(gpa);
    var res = vera.analyze(gpa, source, .{
        .file_name = path,
        .include_dirs = include,
        .display = .emit,
        .int_systfs = int_systfs,
    }, &bag) catch |e| {
        try vera.diag.render(&bag, stderrWriter(), .{});
        return e;
    };
    defer res.deinit(gpa);
    var device = try res.generate(gpa, .{ .vpi_contribs = true }, &bag);
    defer device.deinit(gpa);
    if (device.refused) return error.CodegenRefused;
    const stem = std.fs.path.stem(path);
    const spec = try exe.Spec.parse(arena, source, null);
    var runner: Io.Writer.Allocating = .init(arena);
    // The facts `vera --emit-exe` renders this device's runner with, so the
    // two heads agree (the memory-backed arrays' `mem_bytes` included).
    var facts = try exe.compileFacts(arena, res.lowered, res.mir);
    facts.validate_contract = true;
    exe.writeVpiLib(&runner.writer, stem, &spec.bench, facts) catch return error.OutOfMemory;
    const work_root = if (std.c.getenv("VERA_VPI_WORK")) |w| std.mem.span(w) else ".zig-cache/vera-vpi"; // os: the host links libc on every target
    const work = try std.fs.path.join(arena, &.{ work_root, app_stem });
    // The contract this library speaks (`lib/contract.zig` and
    // `lib/contract/`), beside the device it is built against.
    for (@import("sim_sources").files) |f| {
        const rel = std.mem.cutPrefix(u8, f[0], "lib/") orelse continue;
        if (!std.mem.startsWith(u8, rel, "contract")) continue;
        const p = try std.fs.path.join(arena, &.{ work, rel });
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(p).?);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = f[1] });
    }
    const contract = try std.fs.path.join(arena, &.{ work, "contract.zig" });
    const t = &builtin.target;
    const out = try arena.print("{s}/{s}{s}{s}", .{ work, t.libPrefix(), stem, t.dynamicLibSuffix() });
    const built = try zigbuild.buildExe(gpa, io, device.output.text, runner.written(), .{
        .work_dir = work,
        .contract = contract,
        .name = res.mir.name,
        .out_path = out,
        .zig_exe = if (std.c.getenv("VERA_ZIG")) |z| std.mem.span(z) else "zig", // os: the host links libc on every target
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
    if (S.w == null) S.w = Io.File.stderr().writerStreaming(Io.Threaded.global_single_threaded.io(), &S.buf);
    std.debug.assert(S.w != null);
    std.debug.assert(S.w.?.interface.buffer.len == S.buf.len); // buffered, flushed by the renderer
    return &S.w.?.interface;
}

fn bindLib(l: *DynLib) !vpi.analog.Lib {
    // Bound to the installed design, after §12.33.2's registrations.
    std.debug.assert(vpi.session.design != null);
    std.debug.assert(!vpi.session.starting);
    var out: vpi.analog.Lib = undefined;
    const s = @typeInfo(vpi.analog.Lib).@"struct";
    inline for (s.field_names, s.field_types) |name, F| {
        @field(out, name) = l.lookup(F, "vera_vpi_" ++ name) orelse return error.MissingSymbol;
    }
    return out;
}

/// A digital design under the application, on the stack `main` reserved
/// (`deep_stack.runGuarded`): the engine's evaluation, as `vera --run`'s,
/// recurses on the source's nesting.
fn digitalHost(path: []const u8) !u8 {
    std.debug.assert(!std.mem.endsWith(u8, path, ".va"));
    std.debug.assert(vpi.session.design == null);
    const io = Io.Threaded.global_single_threaded.io();
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ebuf: [4096]u8 = undefined;
    var ew = Io.File.stderr().writerStreaming(io, &ebuf);
    const err = &ew.interface;
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writerStreaming(io, &obuf);
    const out = &ow.interface;

    const source = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |e| {
        try err.print("vpi_host: cannot read `{s}`: {t}\n", .{ path, e });
        try err.flush();
        return 2;
    };
    // §12.33.2 first: IEEE 1364-2005 §26.2.4 allows only the two
    // registration routines there, and elaboration reads the systfs they
    // register (§20.4) and sizes them (§26.1.1).
    vpi.session.runStartupRoutines();
    var bag = vera.diag.Bag.init(arena);
    const dir = std.fs.path.dirname(path) orelse ".";
    // `$VERA_PROTECT_KEYS` names a key file as `vera --protect-keys` reads it:
    // the IEEE 1364-2005 §28.2 keys for the design's decryption envelopes.
    var keys: protect.Keys = .{};
    if (std.c.getenv("VERA_PROTECT_KEYS")) |k| if (std.mem.span(k).len != 0) { // os: the host links libc on every target
        const kpath = std.mem.span(k);
        const text = Io.Dir.cwd().readFileAlloc(io, kpath, arena, .limited(1 << 20)) catch |e| {
            try err.print("vpi_host: cannot read VERA_PROTECT_KEYS `{s}`: {t}\n", .{ kpath, e });
            try err.flush();
            return 2;
        };
        keys = protect.parseKeys(arena, text) catch |e| {
            try err.print("vpi_host: VERA_PROTECT_KEYS `{s}`: not a key file ({t})\n", .{ kpath, e });
            try err.flush();
            return 2;
        };
    };
    var run = sim.digital.elaborate(arena, source, .{ .file_name = path, .include_dirs = &.{dir}, .io = io, .systf = vpi.systf.hook, .stmt_sites = true, .protect_keys = keys }, &bag, out) catch |e| {
        try vera.diag.render(&bag, err, .{});
        try err.print("vpi_host: `{s}` did not elaborate: {t}\n", .{ path, e });
        try err.flush();
        return 1;
    };
    try vpi.session.openDigital(std.heap.page_allocator, &run);
    defer vpi.session.close();

    // §12.31.4's "end of simulation data structure compilation or build",
    // then time 0.
    vpi.callback_fire.endOfCompile();
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
    // The warnings a run survives, as `vera --run` prints them: §17.2.9's
    // terminated load "issues an error message" (W1157).
    try vera.diag.render(&bag, err, .{});
    try err.flush();
    return 0;
}
