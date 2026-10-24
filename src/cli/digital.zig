//! `vera` over a `.v` design: the parsed command line and the source -> a
//! `--run` transcript, an `--emit-exe` executable's path, or a contract
//! device (`--emit-zig`, `--check`, `--emit-so`, `--emit-osdi`), with the digital engine's
//! diagnostics on stderr. `main` dispatches here once the source is read and
//! the flags that conflict whatever the language have been refused.
//!
//! Clauses: IEEE 1364-2005 §13.2, §13.5.1 and §13.7.1 (libraries and their
//! search order), §3.2/§4.1 (what `--two-state` gives up), §9.7.2 (edges).

const std = @import("std");
const vera = @import("vera");
const digital = @import("sim").digital;
/// The native emitter (src/codegen/digital/): `--emit-exe` roots and `.v` devices.
const native = @import("digital");
const diag = vera.diag;
const Io = std.Io;
const args = @import("args.zig");
const report = @import("report.zig").report;
const missing = args.missing;

/// The `.v` half of `main`. `opt` and `backend` are the derived build mode;
/// `cli.contract_path` is set whenever `--emit-exe` or `--check` or
/// `--emit-so` was typed. Returns the process exit status: 2 for flags a `.v`
/// source cannot take, 1 for a refused or failed design.
pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    cli: *const args.Cli,
    source: []const u8,
    in_path: []const u8,
    opt: std.lang.Optimize,
    backend: vera.orchestrator.Backend,
    use_color: bool,
    out: *Io.Writer,
    err: *Io.Writer,
) !u8 {
    const json = cli.json;
    const device = cli.emit_zig or cli.check or cli.emit_so;
    if (!cli.emit_rtlil and ((cli.exe_flag == null) == !device or cli.lint_flag or (cli.out_path != null and !cli.emit_zig and !cli.emit_osdi))) {
        try err.writeAll("error: digital .v source takes --run or --emit-exe, or --emit-zig, --check or --emit-so for a contract device\n");
        return 2;
    }
    // Its net, value and code tables grow to the design's size; see BigArena.
    var arena: vera.BigArena = .init(gpa);
    defer arena.deinit();
    var digital_bag = diag.Bag.init(arena.allocator());
    digital_bag.levels = cli.levels;
    var opts: digital.Options = .{ .file_name = in_path, .include_dirs = cli.include_dirs.items, .io = io, .language = cli.language, .event_budget = cli.event_budget, .params = cli.overrides.items };
    if (!try libraries(arena.allocator(), io, cli.paths.items, cli.libmaps.items, cli.search.items, &opts, err, json, use_color)) return 1;
    if (cli.emit_rtlil) return emitRtlil(io, arena.allocator(), &digital_bag, source, opts, cli.out_path, out, err, json, use_color);
    if (device) return emitDevice(gpa, io, arena.allocator(), &digital_bag, source, opts, cli.schedule, if (cli.logic_flag != null) cli.logic else .four, .{
        .zig = cli.emit_zig,
        .check = cli.check,
        .so = cli.emit_so,
        .osdi = cli.emit_osdi,
        .out_path = cli.out_path,
        .contract = cli.contract_path,
        .dyn = cli.dyn_path,
        .work_dir = cli.work_dir,
        .zig_exe = cli.zig_exe,
        .optimize = opt,
        .backend = backend,
        .debug_info = cli.debug_info,
        .engine_cache = try engineCache(arena.allocator(), environ_map, cli.work_dir),
    }, out, err, json, use_color);
    const wd = cli.work_dir orelse ".zig-cache/vera-tb";
    if (!cli.run_exe) return emitDigital(gpa, io, arena.allocator(), &digital_bag, source, opts, .{
        .work_dir = wd,
        .contract = cli.contract_path.?,
        .name = std.fs.path.stem(in_path),
        .zig_exe = cli.zig_exe,
        .mixed = true,
        .optimize = opt,
        .backend = backend,
        .debug_info = cli.debug_info,
    }, cli.schedule, cli.logic, out, err, json, use_color);
    digital.run(arena.allocator(), source, opts, &digital_bag, out) catch |e| {
        try report(&digital_bag, err, json, use_color);
        if (e != error.DigitalFailed) try err.print("error: digital execution failed: {t}\n", .{e});
        return 1;
    };
    try report(&digital_bag, err, json, use_color);
    // A warning the run raised and --deny made an error still fails it.
    return if (digital_bag.failed()) 1 else 0;
}

/// `vera --emit-rtlil design.v`: the design as Yosys RTLIL (`native.rtlil`),
/// to `out_path` or stdout. A construct outside the synthesizable subset is
/// refused by name, with nothing written.
fn emitRtlil(io: Io, arena: std.mem.Allocator, bag: *diag.Bag, source: []const u8, opts: digital.Options, out_path: ?[]const u8, out: *Io.Writer, err: *Io.Writer, json: bool, use_color: bool) !u8 {
    var why: []const u8 = "";
    const text = native.rtlil.emit(arena, source, opts, bag, &why) catch |e| switch (e) {
        error.Refused => {
            try report(bag, err, json, use_color);
            try err.print("error: {s}: --emit-rtlil: {s}\n", .{ opts.file_name, why });
            return 1;
        },
        error.DigitalFailed => {
            try report(bag, err, json, use_color);
            return 1;
        },
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    try report(bag, err, json, use_color);
    if (bag.failed()) return 1;
    if (out_path) |p| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text }) catch |e| {
            try err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
            return 1;
        };
    } else try out.writeAll(text);
    return 0;
}

/// `vera --emit-exe design.v`: elaborate here, so a design the engine refuses
/// is refused now with `vera --run`'s diagnostics; then build the executable
/// `native.program` writes and print its path. A design that is not native says
/// so on stderr and embeds the interpreter.
fn emitDigital(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    bag: *diag.Bag,
    source: []const u8,
    opts: digital.Options,
    build: vera.tb.BuildOptions,
    schedule: native.Schedule,
    logic: native.Logic,
    out: *Io.Writer,
    err: *Io.Writer,
    json: bool,
    use_color: bool,
) !u8 {
    var sink: Io.Writer.Discarding = .init(&.{});
    var r = digital.elaborate(arena, source, opts, bag, &sink.writer) catch |e| {
        try report(bag, err, json, use_color);
        if (e != error.DigitalFailed) try err.print("error: digital elaboration failed: {t}\n", .{e});
        return 1;
    };
    try report(bag, err, json, use_color);
    if (bag.failed()) return 1;
    const prog = try native.program(arena, &r, .{
        .source = source,
        .file_name = opts.file_name,
        .include_dirs = opts.include_dirs,
        .language = opts.language,
        .lib = opts.lib,
        .more = opts.more,
        .search = opts.search,
    }, schedule, logic);
    if (prog.fallback) |why| {
        if (logic == .two) {
            try bag.add(.lower, .E1101, .{ .start = 0, .end = 0 }, "--two-state needs a native design in which no x or z carries meaning: {s}", .{why});
            try report(bag, err, json, use_color);
            return 1;
        }
        try err.print("note: {s}: not native ({s})\n", .{ opts.file_name, why });
    }
    if (logic == .two) try err.writeAll("note: --two-state is not IEEE 1364 §3.2/§4.1 4-state simulation; output differs wherever an x or z would have arisen\n");
    if (logic == .auto and prog.fallback == null) if (prog.four) |k| {
        try err.print("note: {s}: 4-state: {s}", .{ opts.file_name, k.why });
        if (k.tok) |t| {
            const loc = r.bag.locate(.{ .start = r.starts[t], .end = r.starts[t] }, null);
            const text = r.bag.fileText(loc.file);
            const line = 1 + std.mem.count(u8, text[0..@min(loc.offset, text.len)], "\n");
            try err.print(" ({s}:{d})", .{ r.bag.fileName(loc.file), line });
        }
        try err.writeAll("\n");
    } else try err.print("note: {s}: 2-state once a time step begins with no live x or z; 4-state until then\n", .{opts.file_name});
    const built = vera.tb.buildExe(gpa, io, null, prog.text, build) catch |e| {
        try err.print("error: {s}: building the executable failed: {t}\n", .{ opts.file_name, e });
        return 1;
    };
    defer built.deinit(gpa);
    switch (built) {
        .failed => |text| {
            try err.print("error: {s}: the generated executable does not compile — this is an engine bug:\n", .{opts.file_name});
            try err.writeAll(text);
            return 1;
        },
        .ok => |p| try out.print("{s}\n", .{p}),
    }
    return 0;
}

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
    backend: vera.orchestrator.Backend,
    debug_info: bool,
    /// Where `--emit-so` keeps the prebuilt engine (`engineCache`).
    engine_cache: []const u8,
};

/// `vera --emit-zig|--check|--emit-so|--emit-osdi design.v`: the top module
/// as a contract device (`native.emitDevice`). `--check` builds it beside a
/// root that validates it and calls every hook; `--emit-so` builds it over
/// the VerA tree `--contract` sits in, and `--emit-osdi` is `--emit-so`
/// under that tree's `lib/osdi_dyn.zig`.
fn emitDevice(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    bag: *diag.Bag,
    source: []const u8,
    opts: digital.Options,
    schedule: native.Schedule,
    logic: native.Logic,
    f: DeviceFlags,
    out: *Io.Writer,
    err: *Io.Writer,
    json: bool,
    use_color: bool,
) !u8 {
    if (logic != .four) {
        try bag.add(.lower, .E1103, .none, "a contract device is 4-state: {s}", .{if (logic == .auto)
            "--state=auto reruns the design from time 0 when an x or z returns, and a host owns the device's time"
        else
            "--state=2 would make its logic depend on the host program's root module"});
        try report(bag, err, json, use_color);
        return 1;
    }
    const dev = native.emitDevice(arena, source, opts, schedule, bag) catch |e| {
        try report(bag, err, json, use_color);
        if (e != error.DigitalFailed) try err.print("error: {s}: emitting the device failed: {t}\n", .{ opts.file_name, e });
        return 1;
    };
    try report(bag, err, json, use_color);
    // `native.emitDevice` adds W1155 after a successful emit; --deny makes
    // it an error, and an error writes no device.
    if (bag.failed()) return 1;
    if (f.check) {
        const built = vera.tb.buildExe(gpa, io, dev.zig, device_check, .{
            .work_dir = ".zig-cache/vera-check",
            .contract = f.contract.?,
            .name = dev.name,
            .zig_exe = f.zig_exe,
            .mixed = true,
        }) catch |e| {
            try err.print("error: {s}: checking the device failed: {t}\n", .{ opts.file_name, e });
            return 1;
        };
        defer built.deinit(gpa);
        if (built == .failed) {
            try err.print("error: {s}: the generated device does not compile — this is an engine bug:\n", .{opts.file_name});
            try err.writeAll(built.failed);
            return 1;
        }
    }
    if (f.so) {
        const wd = f.work_dir orelse if (f.osdi) ".zig-cache/vera-tb" else return missing(err, "--emit-so", "--work-dir DIR");
        const dyn = f.dyn orelse return missing(err, "--emit-so", "--dyn PATH");
        const tree = vera.orchestrator.treeOf(f.contract.?);
        const runtime = vera.orchestrator.runtime_modules;
        var modules: [2 + runtime.len]vera.orchestrator.Module = undefined;
        modules[0] = .{ .name = "contract", .root = f.contract.? };
        modules[1] = .{ .name = "dyn", .root = dyn, .deps = &.{"contract"} };
        for (runtime, modules[2..]) |rm, *m| m.* = .{ .name = rm.name, .root = try std.fs.path.join(arena, &.{ tree, rm.root }), .deps = rm.deps };
        var o: vera.orchestrator.Options = .{
            .work_dir = wd,
            .name = dev.name,
            .optimize = f.optimize,
            .backend = f.backend,
            .modules = &modules,
            .zig_exe = f.zig_exe,
            .debug_info = f.debug_info,
        };
        // The engine is built once per sources, compiler, target and flags;
        // only the design is built here (`rt/engine.zig`). The self-hosted
        // backend builds the whole engine as fast as it checks the cache
        // (measured 2026-10-01: v_inv 5.9 Gi either way), so only LLVM builds
        // link it prebuilt.
        if (f.backend.forHost() == .llvm) {
            const eng = vera.orchestrator.buildEngine(arena, io, o, f.engine_cache) catch |e| {
                try err.print("error: {s}: building the digital engine failed: {t}\n", .{ opts.file_name, e });
                return 1;
            };
            switch (eng) {
                .ok => |p| o.engine = p,
                .failed => |b| {
                    try err.print("error: {s}: the digital engine did not compile — this is an engine bug:\n", .{opts.file_name});
                    try b.renderToWriter(.{}, err);
                    return 1;
                },
            }
        }
        var r = vera.orchestrator.compileRelease(gpa, io, o, .{ .text = dev.zig }, 1) catch |e| {
            try err.print("error: {s}: building the device failed: {t}\n", .{ opts.file_name, e });
            return 1;
        };
        defer r.deinit(gpa);
        switch (r) {
            .ok => |a| if (f.osdi) {
                const dest = f.out_path orelse try arena.print("{s}.osdi", .{dev.name});
                Io.Dir.cwd().copyFile(a.so_path, Io.Dir.cwd(), dest, io, .{}) catch |e| {
                    try err.print("error: cannot write `{s}`: {t}\n", .{ dest, e });
                    return 1;
                };
                try out.print("{s}\n", .{dest});
            } else try out.print("{s}\n", .{a.so_path}),
            .failed => |b| {
                try err.print("error: {s}: the generated device did not compile:\n", .{opts.file_name});
                try b.renderToWriter(.{}, err);
                return 1;
            },
        }
    }
    if (f.zig) {
        if (f.out_path) |p| {
            Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = dev.zig }) catch |e| {
                try err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
                return 1;
            };
        } else try out.writeAll(dev.zig);
    }
    try out.flush();
    return 0;
}

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

/// IEEE 1364-2005 §13.2 reads the library maps, then fills `opts` with each
/// file after the first and the library every file maps into, and the
/// §13.5.1/§13.7.1 search order. False when it reported a refusal.
fn libraries(
    arena: std.mem.Allocator,
    io: Io,
    paths: []const []const u8,
    libmaps: []const []const u8,
    search: []const []const u8,
    opts: *digital.Options,
    err: *Io.Writer,
    json: bool,
    use_color: bool,
) !bool {
    var bag = diag.Bag.init(arena);
    const map = vera.libmap.load(arena, io, &bag, libmaps) catch |e| switch (e) {
        error.MapFailed => {
            try report(&bag, err, json, use_color);
            return false;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const libs = try arena.alloc([]const u8, paths.len);
    for (paths, libs) |p, *lib| {
        const real = Io.Dir.cwd().realPathFileAlloc(io, p, arena) catch |e| {
            try err.print("error: cannot read `{s}`: {t}\n", .{ p, e });
            return false;
        };
        lib.* = switch (map.libraryOf(real)) {
            .lib => |l| l,
            .ambiguous => |two| {
                try bag.add(.parse, .E0244, .none, "`{s}` matches file path specifications of libraries `{s}` and `{s}` (IEEE 1364-2005 §13.2.1.1)", .{ p, two[0], two[1] });
                try report(&bag, err, json, use_color);
                return false;
            },
        };
    }
    for (search) |l| if (map.declares(l) == null and !std.mem.eql(u8, l, "work")) {
        try bag.add(.parse, .E0244, .none, "-L {s}: no library map declares library `{s}` (IEEE 1364-2005 §13.7.1)", .{ l, l });
        try report(&bag, err, json, use_color);
        return false;
    };
    const more = try arena.alloc(digital.Unit, paths.len - 1);
    for (paths[1..], libs[1..], more) |p, l, *u| u.* = .{
        .name = p,
        .text = vera.Preprocessor.readText(io, .cwd(), p, arena) catch |e| {
            try vera.readFailed(err, p, e);
            return false;
        },
        .lib = l,
    };
    opts.lib = libs[0];
    opts.more = more;
    // ponytail: A.1.1's -incdir lists join the include path of every file,
    // not only their library's; per-library paths need `digital.Unit` to
    // carry its own.
    if (map.incdirs.len != 0) opts.include_dirs = try std.mem.concat(arena, []const u8, &.{ opts.include_dirs, map.incdirs });
    opts.search = if (search.len != 0) search else try map.order(arena);
    try report(&bag, err, json, use_color);
    return true;
}

/// The compiler cache the prebuilt digital engine lives in, shared by every
/// work directory: `globalCache`'s `vera-engine`, else the work directory's
/// own `.zig-cache`.
fn engineCache(arena: std.mem.Allocator, env: *const std.process.Environ.Map, work_dir: ?[]const u8) ![]const u8 {
    return try globalCache(arena, env, "vera-engine") orelse std.fs.path.join(arena, &.{ work_dir orelse ".", ".zig-cache" });
}

/// `sub` in Zig's global cache directory (`ZIG_GLOBAL_CACHE_DIR`, else
/// `XDG_CACHE_HOME/zig`, else `HOME/.cache/zig`, else Windows'
/// `LOCALAPPDATA/zig`); null when the environment names none.
pub fn globalCache(arena: std.mem.Allocator, env: *const std.process.Environ.Map, sub: []const u8) !?[]const u8 {
    const global = if (env.get("ZIG_GLOBAL_CACHE_DIR")) |d|
        d
    else if (env.get("XDG_CACHE_HOME")) |d|
        try std.fs.path.join(arena, &.{ d, "zig" })
    else if (env.get("HOME")) |d|
        try std.fs.path.join(arena, &.{ d, ".cache", "zig" })
    else if (env.get("LOCALAPPDATA")) |d|
        try std.fs.path.join(arena, &.{ d, "zig" })
    else
        return null;
    return try std.fs.path.join(arena, &.{ global, sub });
}

// ---------------------------------------------------------------------------
// Tests, over real files in a temporary directory: `libraries` resolves real
// paths, and a device emit reads its source back through `libraries`.
// ---------------------------------------------------------------------------

const testing = std.testing;

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

test "libraries: with no map every file is in `work`, the search order is `work`, the rest are units" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = try .init(a, &.{ .{ "top.v", "module top; endmodule\n" }, .{ "cell.v", "module cell; endmodule\n" } });
    defer t.tmp.cleanup();
    var err: Io.Writer.Allocating = .init(a);
    var opts: digital.Options = .{};
    try testing.expect(try libraries(a, testing.io, t.paths, &.{}, &.{}, &opts, &err.writer, false, false));
    try testing.expectEqualStrings("", err.written());
    try testing.expectEqualStrings("work", opts.lib);
    try testing.expectEqual(@as(usize, 1), opts.more.len);
    try testing.expectEqualStrings(t.paths[1], opts.more[0].name);
    try testing.expectEqualStrings("module cell; endmodule\n", opts.more[0].text);
    try testing.expectEqualStrings("work", opts.more[0].lib);
    try testing.expectEqual(@as(usize, 1), opts.search.len);
    try testing.expectEqualStrings("work", opts.search[0]);
}

test "libraries: -L names a declared library or `work`; anything else is E0244 (IEEE 1364-2005 §13.7.1)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = try .init(a, &.{.{ "top.v", "module top; endmodule\n" }});
    defer t.tmp.cleanup();
    var ok_err: Io.Writer.Allocating = .init(a);
    var opts: digital.Options = .{};
    try testing.expect(try libraries(a, testing.io, t.paths, &.{}, &.{"work"}, &opts, &ok_err.writer, false, false));
    try testing.expectEqualStrings("work", opts.search[0]);

    var err: Io.Writer.Allocating = .init(a);
    try testing.expect(!try libraries(a, testing.io, t.paths, &.{}, &.{"nolib"}, &opts, &err.writer, false, false));
    try testing.expect(std.mem.find(u8, err.written(), "E0244") != null);
    try testing.expect(std.mem.find(u8, err.written(), "-L nolib: no library map declares library `nolib`") != null);
}

test "libraries: a file that cannot be read is refused by path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = try .init(a, &.{.{ "top.v", "module top; endmodule\n" }});
    defer t.tmp.cleanup();
    const gone = try std.fs.path.join(a, &.{ std.fs.path.dirname(t.paths[0]).?, "gone.v" });
    var err: Io.Writer.Allocating = .init(a);
    var opts: digital.Options = .{};
    try testing.expect(!try libraries(a, testing.io, &.{ t.paths[0], gone }, &.{}, &.{}, &opts, &err.writer, false, false));
    try testing.expect(std.mem.startsWith(u8, err.written(), "error: cannot read `"));
}

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
    if (deny) try testing.expect(try cli.levels.parseFlag(testing.allocator, "deny=W1155"));
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var out: Io.Writer.Allocating = .init(arena);
    var err: Io.Writer.Allocating = .init(arena);
    const code = try run(testing.allocator, testing.io, &env, &cli, src, t.paths[0], .debug, .llvm, false, &out.writer, &err.writer);
    return .{ .code = code, .out = out.written(), .err = err.written() };
}

test "a .v device: W1155 warns and the device prints; --deny=W1155 makes it an error, exit 1 and no device" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const warned = try emitSeconds(arena.allocator(), false);
    try testing.expectEqual(@as(u8, 0), warned.code);
    try testing.expect(std.mem.find(u8, warned.err, "warning[W1155]") != null);
    try testing.expect(warned.out.len != 0);
    // main.zig's header: "1 on a diagnosed error". A denied warning is one.
    const denied = try emitSeconds(arena.allocator(), true);
    try testing.expect(std.mem.find(u8, denied.err, "error[W1155]") != null);
    try testing.expectEqual(@as(u8, 1), denied.code);
    try testing.expectEqualStrings("", denied.out);
}

test "run: a .v source takes exactly one of a testbench or a device" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const says = "error: digital .v source takes --run or --emit-exe, or --emit-zig, --check or --emit-so for a contract device\n";
    for ([_]args.Cli{
        .{}, // neither
        .{ .exe_flag = "--emit-exe", .check = true }, // both
        .{ .emit_zig = true, .lint_flag = true },
    }) |cli| {
        var out: Io.Writer.Allocating = .init(a);
        var err: Io.Writer.Allocating = .init(a);
        try testing.expectEqual(@as(u8, 2), try run(testing.allocator, testing.io, &env, &cli, "", "x.v", .debug, .llvm, false, &out.writer, &err.writer));
        try testing.expectEqualStrings(says, err.written());
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
