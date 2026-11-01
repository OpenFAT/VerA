//! `vera` over a `.v` design: the settled command line and the source -> a
//! `--run` transcript, an `--elab` check, `--emit-rtlil`'s RTLIL, an
//! `--emit-exe` executable's path, or a contract device (`--emit-zig`,
//! `--check`, `--emit-so`, `--emit-osdi`), with the digital engine's
//! diagnostics on stderr. `main` dispatches here once the source is read and
//! the flags its language cannot take have been refused. One `Job` holds what
//! every step of the run reads: the arena the design's tables grow in, the
//! bag, the digital options the library flags filled.
//!
//! Cites: IEEE 1364-2005 §13.2, §13.5.1 and §13.7.1 (libraries and their
//! search order), §12.1.3 (`--elab`), §3.2/§4.1 (what `--two-state` gives
//! up), §28 (`--protect-keys`).
//!
//! Contents:
//! - `pub fn run(gpa: Allocator, io: Io, environ_map: *const std.process.Environ.Map, cli: *const args.Cli, source: []const u8, in_path: []const u8, s: args.Settled, out: *Io.Writer, err: *Io.Writer) !u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vera = @import("vera");
const diag = vera.diag;
const BigArena = @import("base").BigArena;
const frontend = @import("frontend");
const zigbuild = @import("zigbuild");
const digital = @import("sim").digital;
/// The native emitter (src/codegen/digital/): `--emit-exe` roots and `.v` devices.
const native = @import("digital");
const args = @import("args.zig");
const report = @import("report.zig");
const globalCache = @import("global_cache.zig").globalCache;
const missing = args.missing;

/// What every step of one `.v` run reads; `run` owns it.
const Job = struct {
    gpa: Allocator,
    io: Io,
    /// The design's net, value and code tables; freed when `run` returns.
    arena: Allocator,
    bag: *diag.Bag,
    source: []const u8,
    opts: digital.Options,
    style: report.Style,
    out: *Io.Writer,
    err: *Io.Writer,

    fn reportBag(j: Job) !void {
        try report.report(j.bag, j.err, j.style);
    }
};

/// What `emitDevice` builds, and with what.
const DeviceFlags = struct {
    zig: bool,
    check: bool,
    so: bool,
    /// `--emit-osdi`: `so` under `lib/osdi_dyn.zig` (`dyn`), copied to
    /// `out_path` or `<module>.osdi`.
    osdi: bool,
    out_path: ?[]const u8,
    contract: ?[]const u8,
    dyn: ?[]const u8,
    work_dir: ?[]const u8,
    zig_exe: []const u8,
    optimize: std.lang.Optimize,
    backend: zigbuild.Backend,
    debug_info: bool,
    /// Where `--emit-so` keeps the prebuilt engine (`engineCache`).
    engine_cache: []const u8,
};

/// `--check`'s root beside a `.v` device: the contract's checks, and every
/// hook called once so each body is compiled.
const device_check =
    \\pub const vera_validate_contract = true;
    \\const contract = @import("contract");
    \\const D = @import("device");
    \\const n_u = @typeInfo(D.U).@"enum".field_names.len;
    \\const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});
    \\comptime {
    \\    contract.validate(D);
    \\    contract.validateHost(struct {}, D);
    \\}
    \\pub fn main() void {
    \\    const m: D.Model = .{};
    \\    var inst: D.Instance = .{};
    \\    var st = D.initState(&m, &inst);
    \\    const x: [n_u]f64 = @splat(0);
    \\    _ = D.eval(S, &x, &m, &inst, .{});
    \\    _ = D.updateState(S, &m, &inst, x, &st, .{});
    \\    _ = D.stateCtl(&m, &inst, &st, .commit);
    \\    _ = D.pendingBreakpoint(&inst, 0);
    \\}
    \\
;

/// The tests' sources and helpers; analysed only under `zig test`.
const fixtures = struct {
    const testing = std.testing;

    /// `libraries` over `paths` with no map and the search list `search`,
    /// writing `opts` and reporting on `err`.
    fn librariesFor(a: Allocator, paths: []const []const u8, search: []const []const u8, opts: *digital.Options, err: *Io.Writer) !bool {
        var bag = diag.Bag.init(a);
        var discard: Io.Writer.Discarding = .init(&.{});
        var j: Job = .{ .gpa = testing.allocator, .io = testing.io, .arena = a, .bag = &bag, .source = "", .opts = opts.*, .style = .{}, .out = &discard.writer, .err = err };
        const ok = try libraries(&j, paths, &.{}, search);
        opts.* = j.opts;
        return ok;
    }

    /// A temporary directory holding `files` (name, text), with each file's
    /// absolute path in `paths`, allocated in `arena`.
    const Tree = struct {
        tmp: testing.TmpDir,
        paths: []const []const u8,

        fn init(arena: std.mem.Allocator, files: []const [2][]const u8) !Tree {
            var tmp = testing.tmpDir(.{});
            errdefer tmp.cleanup();
            const paths = try arena.alloc([]const u8, files.len);
            for (files, paths) |f, *p| {
                try tmp.dir.writeFile(testing.io, .{ .sub_path = f[0], .data = f[1] });
                p.* = try tmp.dir.realPathFileAlloc(testing.io, f[0], arena);
            }
            return .{ .tmp = tmp, .paths = paths };
        }
    };

    /// `vera --emit-zig [--deny=W1155] v_seconds.v`, in process: the exit status
    /// and what it printed on each stream.
    fn emitSeconds(arena: std.mem.Allocator, deny: bool) !struct { code: u8, out: []const u8, err: []const u8 } {
        // tests/conformance/tests/verilog-ams/ch07_mixed_signal/v_seconds.v: no `timescale, so the
        // device's tick is 1 s and the emit warns W1155.
        const src = "module v_seconds(a, y);\n  input a;\n  output y;\n  assign y = a;\nendmodule\n";
        var t: Tree = try .init(arena, &.{.{ "v_seconds.v", src }});
        defer t.tmp.cleanup();
        var cli: args.Cli = .{ .emit_zig = true, .emit_zig_typed = true, .codegen_flag = "--emit-zig" };
        defer cli.deinit(testing.allocator);
        try cli.paths.append(testing.allocator, t.paths[0]);
        if (deny) try testing.expect(try cli.levels.parseFlag("deny=W1155"));
        var env: std.process.Environ.Map = .init(testing.allocator);
        defer env.deinit();
        var out: Io.Writer.Allocating = .init(arena);
        var err: Io.Writer.Allocating = .init(arena);
        const code = try run(testing.allocator, testing.io, &env, &cli, src, t.paths[0], .{ .optimize = .debug, .backend = .llvm, .style = .{} }, &out.writer, &err.writer);
        return .{ .code = code, .out = out.written(), .err = err.written() };
    }
};

/// The `.v` half of `main`. `cli.contract_path` is set whenever `--emit-exe`,
/// `--check` or `--emit-so` was typed. Returns the process exit status: 2 for
/// flags a `.v` source cannot take, 1 for a refused or failed design.
/// Asserts that `in_path` is `cli.paths[0]`.
pub fn run(
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    cli: *const args.Cli,
    source: []const u8,
    in_path: []const u8,
    s: args.Settled,
    out: *Io.Writer,
    err: *Io.Writer,
) !u8 {
    assert(cli.paths.items.len == 0 or std.mem.eql(u8, cli.paths.items[0], in_path));
    assert(!cli.lsp);
    const device = cli.emit_zig or cli.check or cli.emit_so;
    if (!cli.emit_rtlil and !cli.elab and ((cli.exe_flag == null) == !device or cli.lint_flag or (cli.out_path != null and !cli.emit_zig and !cli.emit_osdi))) {
        try err.writeAll("error: digital .v source takes --run or --emit-exe, or --emit-zig, --check or --emit-so for a contract device\n");
        return 2;
    }
    var arena_state: BigArena = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    bag.levels = cli.levels;
    var j: Job = .{
        .gpa = gpa,
        .io = io,
        .arena = arena,
        .bag = &bag,
        .source = source,
        .opts = .{ .file_name = in_path, .include_dirs = cli.include_dirs.items, .defines = cli.defines.items, .io = io, .language = cli.language, .event_budget = cli.event_budget, .params = cli.overrides.items, .negative_timing = cli.negative_timing },
        .style = s.style,
        .out = out,
        .err = err,
    };
    if (!try libraries(&j, cli.paths.items, cli.libmaps.items, cli.search.items)) return 1;
    if (cli.protect_keys) |p| {
        const text = frontend.preprocessor.readText(io, .cwd(), p, arena) catch |e| {
            try vera.readFailed(err, p, e);
            return 1;
        };
        j.opts.protect_keys = frontend.protect.parseKeys(arena, text) catch |e| {
            try err.print("error: --protect-keys {s}: not a key file ({s})\n", .{ p, @errorName(e) });
            return 1;
        };
    }
    if (cli.elab) {
        // IEEE 1364-2005 §12.1.3: elaboration is complete before time 0, so a
        // design that never finishes or reads an absent file still elaborates.
        _ = digital.elaborate(arena, source, j.opts, &bag, out) catch |e| {
            try j.reportBag();
            if (e != error.DigitalFailed) try err.print("error: digital elaboration failed: {t}\n", .{e});
            return 1;
        };
        try j.reportBag();
        return if (bag.failed()) 1 else 0;
    }
    if (cli.emit_rtlil) return emitRtlil(j, cli.out_path);
    if (device) return emitDevice(j, cli.schedule, if (cli.logic_flag != null) cli.logic else .four, .{
        .zig = cli.emit_zig,
        .check = cli.check,
        .so = cli.emit_so,
        .osdi = cli.emit_osdi,
        .out_path = cli.out_path,
        .contract = cli.contract_path,
        .dyn = cli.dyn_path,
        .work_dir = cli.work_dir,
        .zig_exe = cli.zig_exe,
        .optimize = s.optimize,
        .backend = s.backend,
        .debug_info = cli.debug_info,
        .engine_cache = try engineCache(arena, environ_map, cli.work_dir),
    });
    if (!cli.run_exe) return emitDigital(j, .{
        .work_dir = cli.work_dir orelse ".zig-cache/vera-tb",
        .contract = cli.contract_path.?,
        .name = std.fs.path.stem(in_path),
        .zig_exe = cli.zig_exe,
        .mixed = true,
        .optimize = s.optimize,
        .backend = s.backend,
        .debug_info = cli.debug_info,
    }, cli.schedule, cli.logic);
    digital.run(arena, source, j.opts, &bag, out) catch |e| {
        try j.reportBag();
        if (e != error.DigitalFailed) try err.print("error: digital execution failed: {t}\n", .{e});
        return 1;
    };
    try j.reportBag();
    // A warning the run raised and --deny made an error still fails it.
    return if (bag.failed()) 1 else 0;
}

// ---- private ----

/// IEEE 1364-2005 §13.2 reads the library maps, then fills `j.opts` with each
/// file after the first and the library every file maps into, and the
/// §13.5.1/§13.7.1 search order. False when it reported a refusal.
fn libraries(j: *Job, paths: []const []const u8, libmaps: []const []const u8, search: []const []const u8) !bool {
    assert(paths.len != 0);
    const arena = j.arena;
    const io = j.io;
    var bag = diag.Bag.init(arena);
    const style = j.style;
    const map = frontend.libmap.load(arena, io, &bag, libmaps) catch |e| switch (e) {
        error.MapFailed => {
            try report.report(&bag, j.err, style);
            return false;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const libs = try arena.alloc([]const u8, paths.len);
    for (paths, libs) |p, *lib| {
        const real = Io.Dir.cwd().realPathFileAlloc(io, p, arena) catch |e| {
            try j.err.print("error: cannot read `{s}`: {t}\n", .{ p, e });
            return false;
        };
        lib.* = switch (map.libraryOf(real)) {
            .lib => |l| l,
            .ambiguous => |two| {
                try bag.add(.parse, .E0244, .none, "`{s}` matches file path specifications of libraries `{s}` and `{s}` (IEEE 1364-2005 §13.2.1.1)", .{ p, two[0], two[1] });
                try report.report(&bag, j.err, style);
                return false;
            },
        };
    }
    for (search) |l| if (map.declares(l) == null and !std.mem.eql(u8, l, "work")) {
        try bag.add(.parse, .E0244, .none, "-L {s}: no library map declares library `{s}` (IEEE 1364-2005 §13.7.1)", .{ l, l });
        try report.report(&bag, j.err, style);
        return false;
    };
    const more = try arena.alloc(digital.Unit, paths.len - 1);
    for (paths[1..], libs[1..], more) |p, l, *u| u.* = .{
        .name = p,
        .text = frontend.preprocessor.readText(io, .cwd(), p, arena) catch |e| {
            try vera.readFailed(j.err, p, e);
            return false;
        },
        .lib = l,
    };
    j.opts.lib = libs[0];
    j.opts.more = more;
    // ponytail: A.1.1's -incdir lists join the include path of every file,
    // not only their library's; per-library paths need `digital.Unit` to
    // carry its own.
    if (map.incdirs.len != 0) j.opts.include_dirs = try std.mem.concat(arena, []const u8, &.{ j.opts.include_dirs, map.incdirs });
    j.opts.search = if (search.len != 0) search else try map.order(arena);
    try report.report(&bag, j.err, style);
    assert(j.opts.more.len == paths.len - 1);
    return true;
}

/// `vera --emit-rtlil design.v`: the design as Yosys RTLIL (`native.rtlil`),
/// to `out_path` or stdout. A construct outside the synthesizable subset is
/// refused by name, with nothing written.
fn emitRtlil(j: Job, out_path: ?[]const u8) !u8 {
    assert(j.source.len == 0 or j.opts.file_name.len != 0);
    var why: []const u8 = "";
    const text = native.rtlil.emit(j.arena, j.source, j.opts, j.bag, &why) catch |e| switch (e) {
        error.Refused => {
            try j.reportBag();
            try j.err.print("error: {s}: --emit-rtlil: {s}\n", .{ j.opts.file_name, why });
            return 1;
        },
        error.DigitalFailed => {
            try j.reportBag();
            return 1;
        },
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    try j.reportBag();
    if (j.bag.failed()) return 1;
    if (out_path) |p| {
        Io.Dir.cwd().writeFile(j.io, .{ .sub_path = p, .data = text }) catch |e| {
            try j.err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
            return 1;
        };
    } else try j.out.writeAll(text);
    return 0;
}

/// `vera --emit-exe design.v`: elaborate here, so a design the engine refuses
/// is refused now with `vera --run`'s diagnostics; then build the executable
/// `native.program` writes and print its path. A design that is not native
/// says so on stderr and embeds the interpreter.
fn emitDigital(j: Job, build: zigbuild.BuildOptions, schedule: native.Schedule, logic: native.Logic) !u8 {
    assert(build.mixed);
    assert(build.contract.len != 0);
    const err = j.err;
    const name = j.opts.file_name;
    var sink: Io.Writer.Discarding = .init(&.{});
    var r = digital.elaborate(j.arena, j.source, j.opts, j.bag, &sink.writer) catch |e| {
        try j.reportBag();
        if (e != error.DigitalFailed) try err.print("error: digital elaboration failed: {t}\n", .{e});
        return 1;
    };
    try j.reportBag();
    if (j.bag.failed()) return 1;
    const prog = try native.program(j.arena, &r, .{
        .source = j.source,
        .file_name = name,
        .include_dirs = j.opts.include_dirs,
        .defines = j.opts.defines,
        .language = j.opts.language,
        .lib = j.opts.lib,
        .more = j.opts.more,
        .search = j.opts.search,
    }, schedule, logic);
    if (prog.fallback) |why| {
        if (logic == .two) {
            try j.bag.add(.lower, .E1101, .{ .start = 0, .end = 0 }, "--two-state needs a native design in which no x or z carries meaning: {s}", .{why});
            try j.reportBag();
            return 1;
        }
        try err.print("note: {s}: not native ({s})\n", .{ name, why });
    }
    if (logic == .two) try err.writeAll("note: --two-state is not IEEE 1364 §3.2/§4.1 4-state simulation; output differs wherever an x or z would have arisen\n");
    if (logic == .auto and prog.fallback == null) if (prog.four) |k| {
        try err.print("note: {s}: 4-state: {s}", .{ name, k.why });
        if (k.tok) |t| {
            const loc = r.bag.locate(.{ .start = r.starts[t], .end = r.starts[t] }, .none);
            const text = r.bag.fileText(loc.file);
            const line = 1 + std.mem.count(u8, text[0..@min(loc.offset, text.len)], "\n");
            try err.print(" ({s}:{d})", .{ r.bag.fileName(loc.file), line });
        }
        try err.writeAll("\n");
    } else try err.print("note: {s}: 2-state once a time step begins with no live x or z; 4-state until then\n", .{name});
    const built = zigbuild.buildExe(j.gpa, j.io, null, prog.text, build) catch |e| {
        try err.print("error: {s}: building the executable failed: {t}\n", .{ name, e });
        return 1;
    };
    defer built.deinit(j.gpa);
    switch (built) {
        .failed => |text| {
            try err.print("error: {s}: the generated executable does not compile — this is an engine bug:\n", .{name});
            try err.writeAll(text);
            return 1;
        },
        .ok => |p| try j.out.print("{s}\n", .{p}),
    }
    return 0;
}

/// `vera --emit-zig|--check|--emit-so|--emit-osdi design.v`: the top module
/// as a contract device (`native.emitDevice`). `--check` builds it beside a
/// root that validates it and calls every hook; `--emit-so` builds it over
/// the VerA tree `--contract` sits in, and `--emit-osdi` is `--emit-so`
/// under that tree's `lib/osdi_dyn.zig`.
fn emitDevice(j: Job, schedule: native.Schedule, logic: native.Logic, f: DeviceFlags) !u8 {
    assert(f.zig or f.check or f.so);
    assert(!f.osdi or f.so);
    const err = j.err;
    const name = j.opts.file_name;
    if (logic != .four) {
        try j.bag.add(.lower, .E1103, .none, "a contract device is 4-state: {s}", .{if (logic == .auto)
            "--state=auto reruns the design from time 0 when an x or z returns, and a host owns the device's time"
        else
            "--state=2 would make its logic depend on the host program's root module"});
        try j.reportBag();
        return 1;
    }
    const dev = native.emitDevice(j.arena, j.source, j.opts, schedule, j.bag) catch |e| {
        try j.reportBag();
        if (e != error.DigitalFailed) try err.print("error: {s}: emitting the device failed: {t}\n", .{ name, e });
        return 1;
    };
    try j.reportBag();
    // `native.emitDevice` adds W1155 after a successful emit; --deny makes it
    // an error, and an error writes no device.
    if (j.bag.failed()) return 1;
    if (f.check) {
        const built = zigbuild.buildExe(j.gpa, j.io, dev.zig, device_check, .{
            .work_dir = ".zig-cache/vera-check",
            .contract = f.contract.?,
            .name = dev.name,
            .zig_exe = f.zig_exe,
            .mixed = true,
        }) catch |e| {
            try err.print("error: {s}: checking the device failed: {t}\n", .{ name, e });
            return 1;
        };
        defer built.deinit(j.gpa);
        if (built == .failed) {
            try err.print("error: {s}: the generated device does not compile — this is an engine bug:\n", .{name});
            try err.writeAll(built.failed);
            return 1;
        }
    }
    if (f.so) if (try buildLibrary(j, dev, f)) |code| return code;
    if (f.zig) {
        if (f.out_path) |p| {
            Io.Dir.cwd().writeFile(j.io, .{ .sub_path = p, .data = dev.zig }) catch |e| {
                try err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
                return 1;
            };
        } else try j.out.writeAll(dev.zig);
    }
    try j.out.flush();
    return 0;
}

/// `--emit-so`/`--emit-osdi` of a `.v` device: the library over the VerA
/// tree `--contract` sits in, its path on stdout. Null on success, else the
/// exit status with the reason on stderr.
fn buildLibrary(j: Job, dev: native.DeviceRoot, f: DeviceFlags) !?u8 {
    assert(f.so);
    assert(f.contract != null);
    const err = j.err;
    const name = j.opts.file_name;
    const wd = f.work_dir orelse if (f.osdi) ".zig-cache/vera-tb" else return try missing(err, "--emit-so", "--work-dir DIR");
    const dyn = f.dyn orelse return try missing(err, "--emit-so", "--dyn PATH");
    const tree = zigbuild.treeOf(f.contract.?);
    const runtime = zigbuild.runtime_modules;
    var modules: [2 + runtime.len]zigbuild.Module = undefined;
    modules[0] = .{ .name = "contract", .root = f.contract.? };
    modules[1] = .{ .name = "dyn", .root = dyn, .deps = &.{"contract"} };
    for (runtime, modules[2..]) |rm, *m| m.* = .{ .name = rm.name, .root = try std.fs.path.join(j.arena, &.{ tree, rm.root }), .deps = rm.deps };
    var o: zigbuild.Options = .{
        .work_dir = wd,
        .name = dev.name,
        .optimize = f.optimize,
        .backend = f.backend,
        .modules = &modules,
        .zig_exe = f.zig_exe,
        .debug_info = f.debug_info,
    };
    // The engine is built once per sources, compiler, target and flags; only
    // the design is built here (`rt/engine.zig`). The self-hosted backend
    // builds the whole engine as fast as it checks the cache (measured
    // 2026-10-01: v_inv 5.9 Gi either way), so only LLVM links it prebuilt.
    if (f.backend.forHost() == .llvm) {
        const eng = zigbuild.buildEngine(j.arena, j.io, o, f.engine_cache) catch |e| {
            try err.print("error: {s}: building the digital engine failed: {t}\n", .{ name, e });
            return 1;
        };
        switch (eng) {
            .ok => |p| o.engine = p,
            .failed => |b| {
                try err.print("error: {s}: the digital engine did not compile — this is an engine bug:\n", .{name});
                try b.renderToWriter(.{}, err);
                return 1;
            },
        }
    }
    var r = zigbuild.buildLibrary(j.gpa, j.io, o, .{ .text = dev.zig }, 1) catch |e| {
        try err.print("error: {s}: building the device failed: {t}\n", .{ name, e });
        return 1;
    };
    defer r.deinit(j.gpa);
    switch (r) {
        .ok => |so_path| if (f.osdi) {
            const dest = f.out_path orelse try j.arena.print("{s}.osdi", .{dev.name});
            Io.Dir.cwd().copyFile(so_path, Io.Dir.cwd(), dest, j.io, .{}) catch |e| {
                try err.print("error: cannot write `{s}`: {t}\n", .{ dest, e });
                return 1;
            };
            try j.out.print("{s}\n", .{dest});
        } else try j.out.print("{s}\n", .{so_path}),
        .failed => |b| {
            try err.print("error: {s}: the generated device did not compile:\n", .{name});
            try b.renderToWriter(.{}, err);
            return 1;
        },
    }
    return null;
}

/// The compiler cache the prebuilt digital engine lives in, shared by every
/// work directory: `globalCache`'s `vera-engine`, else the work directory's
/// own `.zig-cache`.
fn engineCache(arena: Allocator, env: *const std.process.Environ.Map, work_dir: ?[]const u8) Allocator.Error![]const u8 {
    const dir = try globalCache(arena, env, "vera-engine") orelse try std.fs.path.join(arena, &.{ work_dir orelse ".", ".zig-cache" });
    assert(dir.len != 0);
    return dir;
}

// ---------------------------------------------------------------------------
// Tests, over real files in a temporary directory: `libraries` resolves real
// paths, and a device emit reads its source back through `libraries`.
// ---------------------------------------------------------------------------

test "libraries: with no map every file is in `work`, the search order is `work`, the rest are units" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: fixtures.Tree = try .init(a, &.{ .{ "top.v", "module top; endmodule\n" }, .{ "cell.v", "module cell; endmodule\n" } });
    defer t.tmp.cleanup();
    var err: Io.Writer.Allocating = .init(a);
    var opts: digital.Options = .{};
    try std.testing.expect(try fixtures.librariesFor(a, t.paths, &.{}, &opts, &err.writer));
    try std.testing.expectEqualStrings("", err.written());
    try std.testing.expectEqualStrings("work", opts.lib);
    try std.testing.expectEqual(@as(usize, 1), opts.more.len);
    try std.testing.expectEqualStrings(t.paths[1], opts.more[0].name);
    try std.testing.expectEqualStrings("module cell; endmodule\n", opts.more[0].text);
    try std.testing.expectEqualStrings("work", opts.more[0].lib);
    try std.testing.expectEqual(@as(usize, 1), opts.search.len);
    try std.testing.expectEqualStrings("work", opts.search[0]);
}

test "libraries: -L names a declared library or `work`; anything else is E0244 (IEEE 1364-2005 §13.7.1)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: fixtures.Tree = try .init(a, &.{.{ "top.v", "module top; endmodule\n" }});
    defer t.tmp.cleanup();
    var ok_err: Io.Writer.Allocating = .init(a);
    var opts: digital.Options = .{};
    try std.testing.expect(try fixtures.librariesFor(a, t.paths, &.{"work"}, &opts, &ok_err.writer));
    try std.testing.expectEqualStrings("work", opts.search[0]);

    var err: Io.Writer.Allocating = .init(a);
    try std.testing.expect(!try fixtures.librariesFor(a, t.paths, &.{"nolib"}, &opts, &err.writer));
    try std.testing.expect(std.mem.find(u8, err.written(), "E0244") != null);
    try std.testing.expect(std.mem.find(u8, err.written(), "-L nolib: no library map declares library `nolib`") != null);
}

test "libraries: a file that cannot be read is refused by path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: fixtures.Tree = try .init(a, &.{.{ "top.v", "module top; endmodule\n" }});
    defer t.tmp.cleanup();
    const gone = try std.fs.path.join(a, &.{ std.fs.path.dirname(t.paths[0]).?, "gone.v" });
    var err: Io.Writer.Allocating = .init(a);
    var opts: digital.Options = .{};
    try std.testing.expect(!try fixtures.librariesFor(a, &.{ t.paths[0], gone }, &.{}, &opts, &err.writer));
    try std.testing.expect(std.mem.startsWith(u8, err.written(), "error: cannot read `"));
}

test "a .v device: W1155 warns and the device prints; --deny=W1155 makes it an error, exit 1 and no device" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const warned = try fixtures.emitSeconds(arena.allocator(), false);
    try std.testing.expectEqual(@as(u8, 0), warned.code);
    try std.testing.expect(std.mem.find(u8, warned.err, "warning[W1155]") != null);
    try std.testing.expect(warned.out.len != 0);
    // main.zig's header: "1 on a diagnosed error". A denied warning is one.
    const denied = try fixtures.emitSeconds(arena.allocator(), true);
    try std.testing.expect(std.mem.find(u8, denied.err, "error[W1155]") != null);
    try std.testing.expectEqual(@as(u8, 1), denied.code);
    try std.testing.expectEqualStrings("", denied.out);
}

test "run: a .v source takes exactly one of a testbench or a device" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const says = "error: digital .v source takes --run or --emit-exe, or --emit-zig, --check or --emit-so for a contract device\n";
    for ([_]args.Cli{
        .{}, // neither
        .{ .exe_flag = "--emit-exe", .check = true }, // both
        .{ .emit_zig = true, .lint_flag = true },
    }) |cli| {
        var out: Io.Writer.Allocating = .init(a);
        var err: Io.Writer.Allocating = .init(a);
        try std.testing.expectEqual(@as(u8, 2), try run(std.testing.allocator, std.testing.io, &env, &cli, "", "x.v", .{ .optimize = .debug, .backend = .llvm, .style = .{} }, &out.writer, &err.writer));
        try std.testing.expectEqualStrings(says, err.written());
    }
}

test engineCache {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const join = std.fs.path.join;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    // Nothing set: the work directory's own cache, `.` without one.
    try std.testing.expectEqualStrings(try join(a, &.{ ".", ".zig-cache" }), try engineCache(a, &env, null));
    try std.testing.expectEqualStrings(try join(a, &.{ "wd", ".zig-cache" }), try engineCache(a, &env, "wd"));
    // Each variable outranks the ones set before it, as Zig's own lookup.
    try env.put("LOCALAPPDATA", "/l");
    try std.testing.expectEqualStrings(try join(a, &.{ "/l", "zig", "vera-engine" }), try engineCache(a, &env, "wd"));
    try env.put("HOME", "/h");
    try std.testing.expectEqualStrings(try join(a, &.{ "/h", ".cache", "zig", "vera-engine" }), try engineCache(a, &env, "wd"));
    try env.put("XDG_CACHE_HOME", "/x");
    try std.testing.expectEqualStrings(try join(a, &.{ "/x", "zig", "vera-engine" }), try engineCache(a, &env, "wd"));
    try env.put("ZIG_GLOBAL_CACHE_DIR", "/g");
    try std.testing.expectEqualStrings(try join(a, &.{ "/g", "vera-engine" }), try engineCache(a, &env, "wd"));
}
