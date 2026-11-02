//! The `vera` module: a Verilog-A/AMS source and a `Request` in, the
//! artifacts the request names out (a device, a testbench, a library, a
//! behavioural Verilog module) plus the text `vera` prints. `compile` below
//! is the spine `vera` calls for a `.va`: read the testbench's `//!`
//! directives and the SPICE netlist, `analyze` (twice when a shape card
//! moves a parameter, §3.4), check `--param`, then one step per target in a
//! fixed order: `--emit-verilog`, the OSDI checks, `--expect-module`,
//! codegen, `--check`, `--emit-exe`, `--emit-so`/`--emit-osdi`, `--emit-zig`.
//! It prints nothing: the `Outcome` says what to print and the exit status.
//! A library caller that wants the MIR or a device without the targets calls
//! `analyze` and `Result.generate` itself. `build.zig`'s `module_specs`
//! makes every stage module a dependency of this one, never the reverse.
//!
//! Cites: §3.4, §4.6.4.6, §6.2, §9.4, §9.17, annex E.1.1; IEEE 1364-2005
//! §17.10 (plusargs). The stages cite their own (`Compilation/analyze.zig`).
//!
//! Contents:
//! - `pub const version`, `pub const diag`, `pub const Display`,
//!   `pub const ParamOverride`, `pub const DisciplineResolution`,
//!   `pub const KeywordSet`, `pub const Sim`
//! - `pub const Settings`, `pub const Result`, `pub const Device`,
//!   `pub const Codegen`, `pub const AnalyzeError`, `pub const analyze`
//! - `pub const ReadError`, `pub const readFailed`, `pub const CompileError`,
//!   `pub const Request`, `pub const Outcome`
//! - `pub fn compile(gpa: Allocator, io: Io, arena: Allocator, source: []const u8, req: Request, bag: *diag.Bag, o: *Outcome) CompileError!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const frontend = @import("frontend");
const zigbuild = @import("zigbuild");
const exe = @import("exe");
const analysis = @import("Compilation/analyze.zig");
const request = @import("Compilation/request.zig");
const read_failed = @import("Compilation/read_failed.zig");
const osdi = @import("Compilation/osdi.zig");
const verilog = @import("Compilation/verilog.zig");
const testbench = @import("Compilation/testbench.zig");
const library = @import("Compilation/library.zig");
// The tests' own: the stages a test inspects.
const proof = @import("prove").proof;
const deep_stack = @import("base").deep_stack;

/// The VerA release (`contract.vera_version`), which every generated device
/// carries and `vera --version` prints.
pub const version = @import("kernels").vera_version;
/// Diagnostic codes, the `Bag` every stage reports into, and rendering.
pub const diag = @import("diag");
/// §9.4's display modes (`Settings.display`).
pub const Display = @import("device").Display;
/// A `--param name=value` compile-time override (`Settings.param_overrides`, §3.4).
pub const ParamOverride = @import("base").ParamOverride;
/// §7.4.4 resolution mode (`Settings.discipline_resolution`).
pub const DisciplineResolution = @import("base").DisciplineResolution;
/// The settings of one analysis.
pub const Settings = @import("Compilation/Settings.zig");
/// One analysed source; `Result.generate` makes its device.
pub const Result = @import("Compilation/Result.zig");

/// The keyword set a `--std=` selects (`Settings.language`).
pub const KeywordSet = frontend.keyword.KeywordSet;
/// The language family a `--sim=` selects (`Settings.sim`).
pub const Sim = frontend.keyword.Sim;
/// A generated device.zig, owned by the caller.
pub const Device = Result.Device;
/// What `Result.generate` emits beyond what the analysis fixed.
pub const Codegen = Result.Codegen;
/// Every way `analyze` fails.
pub const AnalyzeError = analysis.Error;
/// Source text to a proven `Result`; see `Compilation/analyze.zig`.
pub const analyze = analysis.analyze;

/// What reading a source file can fail with (`frontend.preprocessor.readText`).
pub const ReadError = read_failed.ReadError;
/// Writes the one line `vera` prints for a source that could not be read.
pub const readFailed = read_failed.readFailed;

/// Every way `compile` fails, as opposed to refusing (`Outcome.status`).
pub const CompileError = request.CompileError;
/// What one `compile` call builds.
pub const Request = request.Request;
/// What `compile` did, for its caller to print.
pub const Outcome = request.Outcome;

/// The tests' sources and helpers; Zig analyses this only for `zig test`.
const fixtures = struct {
    const resistor =
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1000.0 from (0.0:inf);
        \\  analog I(p, n) <+ V(p, n) / r;
        \\endmodule
    ;
    fn compileBadWithDiags(gpa: Allocator) !void {
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        const src = "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n";
        _ = analyze(gpa, src, .{}, &bag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        return error.TestUnexpectedResult;
    }
    /// A module whose analog block holds `pre`, then `n` copies of `open`, `mid`,
    /// `n` copies of `close`, and `post`.
    fn deepSource(gpa: Allocator, n: usize, c: DeepCase) ![]u8 {
        var src: std.ArrayList(u8) = .empty;
        errdefer src.deinit(gpa);
        try src.appendSlice(gpa, "module deep(p, n); inout p, n; electrical p, n; real r; integer k; analog begin ");
        try src.appendSlice(gpa, c.pre);
        for (0..n) |_| try src.appendSlice(gpa, c.open);
        try src.appendSlice(gpa, c.mid);
        for (0..n) |_| try src.appendSlice(gpa, c.close);
        try src.appendSlice(gpa, c.post);
        try src.appendSlice(gpa, " I(p, n) <+ r * V(p, n); end endmodule");
        return src.toOwnedSlice(gpa);
    }
    /// `device = false`: lint only, because the "10,000-level ?: chain" test
    /// below takes that shape through codegen at the same depth.
    const DeepCase = struct { pre: []const u8 = "", open: []const u8, mid: []const u8, close: []const u8 = "", post: []const u8 = "", device: bool = true };
    const netlist =
        \\.SUBCKT RDIV IN OUT
        \\R1 IN OUT 1K
        \\.ENDS RDIV
        \\
    ;
    const unbounded_exp =
        \\module amp(a, c); inout a, c; electrical a, c;
        \\  analog I(a, c) <+ exp(V(a, c));
        \\endmodule
        \\
    ;
    /// Lints `src` with `display` and returns how many W0850 rows have a
    /// headline containing `needle` ("" counts every W0850 row).
    fn countW0850(src: []const u8, display: Display, needle: []const u8) !usize {
        const gpa = std.testing.allocator;
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var res = try analyze(gpa, src, .{ .display = display }, &bag);
        defer res.deinit(gpa);
        var n: usize = 0;
        for (0..bag.count()) |i| {
            const e = bag.at(i);
            if (e.code == .W0850 and std.mem.find(u8, e.message, needle) != null) n += 1;
        }
        return n;
    }
};

// A single-threaded build runs every walk on the caller's stack: there is no reservation to refuse.
comptime {
    if (!@import("builtin").single_threaded) _ = threaded;
}

const threaded = struct {
    test "a later stage whose stack cannot be reserved is E0241, naming the depth" {
        const gpa = std.testing.allocator;
        const src = try fixtures.deepSource(gpa, 10, .{ .open = "begin ", .mid = "r = 1.0;", .close = " end" });
        defer gpa.free(src);
        deep_stack.refuse_for_test = true;
        defer deep_stack.refuse_for_test = false;
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        try std.testing.expectError(error.CompileFailed, analyze(gpa, src, .{}, &bag));
        try std.testing.expectEqual(diag.Code.E0241, bag.at(0).code);
        try std.testing.expect(std.mem.find(u8, bag.at(0).message, "levels deep") != null);
    }
};

/// The compile spine: `source` through the analysis, then one step per
/// target `req` asks for, in the fixed order of the file header. `bag`
/// receives every diagnostic; it must be fresh from `Bag.init(gpa)`, and the
/// caller `deinit`s it after `o`. `o` is filled even when this returns an
/// error: `o.report` then says whether the bag is final. `arena` holds every
/// message and slice in `o` and must outlive it. Spawns `zig` for `check`,
/// `exe` and `so`, writes `out_path`, prints nothing.
/// Asserts that `bag` and `o` are fresh, and that `contract` is set when a
/// `check`, `exe` or `so` step is reached.
pub fn compile(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    source: []const u8,
    req: Request,
    bag: *diag.Bag,
    o: *Outcome,
) CompileError!void {
    assert(bag.isEmpty());
    assert(o.result == null);
    assert(req.options.file_name.len != 0);
    var ew: Io.Writer.Allocating = .init(arena);
    const err = &ew.writer;
    defer o.err = ew.written();
    const in_path = req.options.file_name;

    // --emit-exe's `//!` directives, read up front: a `//! param` card of a
    // SHAPE parameter is a compile-time value (below).
    const spec: exe.Spec = if (req.exe == null) .{} else exe.Spec.parse(arena, source, null) catch |e| {
        try err.print("error: {s}: `//!` directive: {t}\n", .{ in_path, e });
        return o.done(2);
    };

    // E.1.1's antecedent, made true from the command line: "if a simulator
    // ... is also able to read SPICE netlists ... certain objects defined in
    // that flavor of SPICE netlist can be referenced". Read whole: a `+`
    // continuation makes a card longer than a line. Without `--spice`, a
    // testbench's own `//! spice` cards are the netlist, read beside the source.
    const netlist: []const u8 = if (req.spice_path) |p|
        frontend.preprocessor.readText(io, .cwd(), p, arena) catch |e| {
            try readFailed(err, p, e);
            return o.done(2);
        }
    else
        spec.harness.spice;
    var settings = req.options;
    settings.spice_netlist = netlist;
    settings.spice_path = req.spice_path orelse if (spec.harness.spice.len != 0) in_path else "";
    // A check accepts a source_text with no module; a device request does not.
    settings.empty_unit_ok = req.check or req.lints();
    if (spec.harness.display_record) settings.display = .record;
    if (spec.harness.discipline_resolution == .detail) settings.discipline_resolution = .detail;

    o.result = analyze(gpa, source, settings, bag) catch |e| switch (e) {
        // Checked, and nothing to build: what the bag holds are warnings.
        error.NothingToElaborate => {
            o.report = .after;
            return o.done(0);
        },
        else => {
            o.report = .{ .failed = e };
            return o.done(1);
        },
    };

    // §3.4 the testbench's card values for shape parameters are compile-time
    // values; a `--param` of the same name wins. The second pass reports
    // everything again, so the first pass' bag is dropped.
    const typed = req.options.param_overrides;
    const overrides = try withShapeCards(arena, typed, spec.bench.params, &o.result.?);
    if (overrides.len != typed.len) {
        bag.deinit(gpa);
        bag.* = .init(gpa);
        settings.param_overrides = overrides;
        const again = analyze(gpa, source, settings, bag) catch |e| {
            o.report = .{ .failed = e };
            return o.done(1);
        };
        o.result.?.deinit(gpa);
        o.result = again;
    }
    const result = &o.result.?;
    if (try refuseParams(err, typed, result)) return o.done(2);

    // Warnings on a successful analysis go out after every exit below:
    // codegen reports too (E0515), and the bag is printed whole.
    o.report = .after;
    if (req.lints()) return;
    if (req.verilog) |v| return verilog.emit(gpa, io, arena, result, v, req.out_path, in_path, err, o);

    // What OSDI 0.4 cannot carry is named before a library is built.
    if (req.osdi) {
        try osdi.check(bag, result.lowered);
        if (bag.failed()) return o.done(1);
    }

    // The catalogue that consumes the generated file keys devices by the name
    // the BUILD chose, while the netlist dispatch and the generated type come
    // from the MODULE name: a mismatch silently breaks lookup downstream.
    // A vendored file declaring several modules (VBIC's 4T/5T) trips this;
    // a module selector is the fix.
    if (req.expect_module) |want| if (!std.mem.eql(u8, result.mir.name, want)) {
        try err.print("error: {s}: Verilog-A module is `{s}` but `{s}` was expected — rename one of them\n", .{ in_path, result.mir.name, want });
        return o.done(1);
    };

    o.device = result.generate(gpa, req.codegen, bag) catch |e| {
        try err.print("error: {s}: codegen failed: {t}\n", .{ in_path, e });
        return o.done(1);
    };
    // A refusal: writing the file anyway would move the message to whoever
    // compiles it, away from the .va.
    if (o.device.?.refused) {
        try err.print("error: {s}: codegen refused a construct; generated output is not usable\n", .{in_path});
        return o.done(1);
    }
    const text = o.device.?.output.text;

    // --check type-checks the device here, where its .va can still be named.
    // --emit-so runs the same check only after its build fails.
    if (req.check) {
        if (try zigbuild.typeCheck(gpa, io, .{
            .zig_exe = req.build.zig_exe,
            .contract = req.build.contract.?,
            .device = text,
            .source_path = in_path,
        }, err) == .fails) return o.done(1);
    }
    if (req.exe) |x| return testbench.build(gpa, io, arena, req, x, &spec, result, text, bag, err, o);
    if (req.so) {
        try library.build(gpa, io, arena, req, result, o.device.?.output, err, o);
        if (o.status != 0) return;
    }
    if (req.zig) {
        if (req.out_path) |p| {
            Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text }) catch |e| {
                try err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
                return o.done(1);
            };
        } else o.text = text;
    }
}

// ---- private ----

/// The typed `--param`s, then each testbench shape card no `--param` names
/// (`exe.shapeCards`), in the arena. The same length as `typed` when the
/// testbench moves no shape parameter.
fn withShapeCards(arena: Allocator, typed: []const ParamOverride, cards: []const exe.Binding, result: *const Result) Allocator.Error![]const ParamOverride {
    var all: std.ArrayList(ParamOverride) = .empty;
    try all.appendSlice(arena, typed);
    for (try exe.shapeCards(arena, cards, result.lowered)) |card| {
        for (all.items) |ov| {
            if (std.mem.eql(u8, ov.name, card.name)) break;
        } else try all.append(arena, card);
    }
    assert(all.items.len >= typed.len);
    return all.items;
}

/// Refuses a `--param` that names no top-module, non-local parameter, or
/// gives a numeric one a non-number: a misspelling would otherwise compile
/// the default shape. True when it wrote the refusal on `err`.
fn refuseParams(err: *Io.Writer, typed: []const ParamOverride, result: *const Result) Io.Writer.Error!bool {
    for (typed) |ov| {
        const p = for (result.lowered.params.items) |p| {
            if (std.mem.eql(u8, p.name, ov.name) and !p.is_local) break p;
        } else {
            try err.print("error: --param {s}: `{s}` declares no parameter `{s}` that --param may set\n", .{ ov.name, result.mir.name, ov.name });
            return true;
        };
        assert(!p.is_local);
        const numeric = p.ty != .string and (p.folded == null or p.folded.? != .str);
        if (numeric and std.math.isNan(ov.value)) {
            try err.print("error: --param {s}={s}: `{s}` is not a number\n", .{ ov.name, ov.text, ov.text });
            return true;
        }
    }
    return false;
}

test "lint: source → MIR, arena freed clean" {
    const gpa = std.testing.allocator;
    var res = try analyze(gpa, fixtures.resistor, .{}, null);
    defer res.deinit(gpa);

    try std.testing.expectEqualStrings("res", res.mir.name);
    try std.testing.expectEqual(@as(u16, 2), res.lowered.num_ports);
    try std.testing.expect(res.verdict.ok());
    try std.testing.expectEqual(proof.unitCount(res.lowered), res.verdict.unit_modes.len);
}

test compile {
    // The targets that spawn no `zig`: `--lint`, `--emit-zig` to stdout, a
    // misspelt `--param` (status 2, before the diagnostics are final) and a
    // failed compilation (the bag explains it, so no error name).
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { src: []const u8, req: Request, status: u8, report: std.meta.Tag(Outcome.Report), text: bool, err: []const u8 };
    for ([_]Case{
        .{ .src = fixtures.resistor, .req = .{}, .status = 0, .report = .after, .text = false, .err = "" },
        .{ .src = fixtures.resistor, .req = .{ .zig = true }, .status = 0, .report = .after, .text = true, .err = "" },
        .{
            .src = fixtures.resistor,
            .req = .{ .options = .{ .file_name = "res.va", .param_overrides = &.{.{ .name = "rr", .value = 1 }} } },
            .status = 2,
            .report = .none,
            .text = false,
            .err = "error: --param rr: `res` declares no parameter `rr` that --param may set\n",
        },
        .{ .src = "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n", .req = .{}, .status = 1, .report = .failed, .text = false, .err = "" },
        // Refused before any pipeline stage.
        .{ .src = fixtures.resistor, .req = .{ .spice_path = "/nonexistent/x.sp" }, .status = 2, .report = .none, .text = false, .err = "error: cannot read `/nonexistent/x.sp`: FileNotFound\n" },
        // Refused after the compile, before codegen or a `zig` child.
        .{ .src = fixtures.resistor, .req = .{ .zig = true, .expect_module = "cap" }, .status = 1, .report = .after, .text = false, .err = "error: <source>: Verilog-A module is `res` but `cap` was expected — rename one of them\n" },
        .{ .src = fixtures.resistor, .req = .{ .so = true }, .status = 2, .report = .after, .text = false, .err = "error: --emit-so needs --work-dir DIR\n" },
        .{ .src = fixtures.resistor, .req = .{ .so = true, .build = .{ .work_dir = "wd" } }, .status = 2, .report = .after, .text = false, .err = "error: --emit-so needs --dyn PATH\n" },
        .{ .src = fixtures.resistor, .req = .{ .verilog = .{} }, .status = 0, .report = .after, .text = true, .err = "" },
    }) |c| {
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var o: Outcome = .{};
        defer o.deinit(gpa);
        try compile(gpa, std.testing.io, arena, c.src, c.req, &bag, &o);
        try std.testing.expectEqual(c.status, o.status);
        try std.testing.expectEqual(c.report, std.meta.activeTag(o.report));
        try std.testing.expectEqual(c.text, o.text.len != 0);
        try std.testing.expectEqualStrings(c.err, o.err);
        try std.testing.expect(o.path == null and o.exe == null);
    }
}

test "IEEE 1364 §19.1 cell membership survives the preprocessor" {
    // The module's cell tag survives after the directives are gone from the
    // text. No fixture can check this: §19.1 tags a module and changes no
    // value a model can print.
    const gpa = std.testing.allocator;
    {
        var res = try analyze(gpa, "`celldefine\n" ++ fixtures.resistor ++ "\n`endcelldefine\n", .{}, null);
        defer res.deinit(gpa);
        try std.testing.expect(res.mir.is_cell);
    }
    {
        var res = try analyze(gpa, fixtures.resistor, .{}, null);
        defer res.deinit(gpa);
        try std.testing.expect(!res.mir.is_cell);
    }
    {
        // §10.1 scope: the region ends at the closing directive, so a module
        // below `endcelldefine is not a cell.
        var res = try analyze(gpa, "`celldefine\n`endcelldefine\n" ++ fixtures.resistor, .{}, null);
        defer res.deinit(gpa);
        try std.testing.expect(!res.mir.is_cell);
    }
}

test "--sim=verilogA: annex C.4's `default_discipline is E0250, and the rest compiles" {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    try std.testing.expectError(error.CompileFailed, analyze(gpa, "`default_discipline logic\n" ++ fixtures.resistor, .{ .sim = .verilog_a }, &bag));
    try std.testing.expectEqual(diag.Code.E0250, bag.at(0).code);
    var res = try analyze(gpa, fixtures.resistor, .{ .sim = .verilog_a }, null);
    res.deinit(gpa);
}

test "diagnostics outlive the compilation arena" {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    try std.testing.expectError(error.CompileFailed, analyze(gpa, "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n", .{}, &bag));
    // The arena is gone by now; reading the messages must still be valid.
    try std.testing.expect(!bag.isEmpty());
    try std.testing.expect(bag.failed());
    for (0..bag.count()) |i| try std.testing.expect(diag.info(bag.at(i).code).title.len != 0);

    // So must rendering, which reads the file text the bag detached.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try diag.render(&bag, &aw.writer, .{});
    try std.testing.expect(std.mem.find(u8, aw.writer.buffered(), "-->") != null);
}

test "an allocation failure while detaching diagnostics leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fixtures.compileBadWithDiags, .{});
}

test "a clean compilation reports no diagnostics but still hands back the bag" {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    var res = try analyze(gpa, "module r(p, n); inout p, n; electrical p, n;\n" ++
        "  parameter real rs = 1.0 from (0:inf);\n" ++
        "  analog I(p, n) <+ V(p, n) / rs;\n" ++
        "endmodule\n", .{}, &bag);
    defer res.deinit(gpa);
    try std.testing.expect(!bag.failed());
    // A fully-ranged resistor is provably finite, so not even W0650 fires.
    try std.testing.expect(bag.isEmpty());
    try std.testing.expectEqual(proof.FloatMode.optimized, res.verdict.unit_modes[0]);
}

test "lint levels: --deny promotes a warning into a hard failure" {
    const gpa = std.testing.allocator;
    const src =
        \\module amp(a, c); inout a, c; electrical a, c;
        \\  analog I(a, c) <+ exp(V(a, c));
        \\endmodule
        \\
    ;

    // Default: W0650 fires, but a warning does not fail a compilation.
    {
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var res = try analyze(gpa, src, .{}, &bag);
        defer res.deinit(gpa);
        try std.testing.expect(!bag.failed());
        try std.testing.expectEqual(@as(u32, 1), bag.warn_count);
    }

    // --deny=W0650: same diagnostic, now an error, and the compile fails.
    {
        var levels: diag.Levels = .empty;
        try levels.set(.W0650, .deny);

        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        try std.testing.expectError(error.CompileFailed, analyze(gpa, src, .{ .lint = levels }, &bag));
        try std.testing.expect(bag.failed());
        try std.testing.expectEqual(@as(u32, 1), bag.err_count);
    }

    // --allow=W0650: not collected at all, and still a clean compile.
    {
        var levels: diag.Levels = .empty;
        try levels.set(.W0650, .allow);

        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var res = try analyze(gpa, src, .{ .lint = levels }, &bag);
        defer res.deinit(gpa);
        try std.testing.expect(bag.isEmpty());
        // Silencing the lint does not change the generated code.
        try std.testing.expectEqual(proof.FloatMode.strict, res.verdict.unit_modes[0]);
    }
}

test "determinism: a no-op recompile reproduces identical device.zig" {
    const gpa = std.testing.allocator;
    var a = try analyze(gpa, fixtures.resistor, .{}, null);
    defer a.deinit(gpa);
    var b = try analyze(gpa, fixtures.resistor, .{}, null);
    defer b.deinit(gpa);
    var da = try a.generate(gpa, .{}, null);
    defer da.deinit(gpa);
    var db = try b.generate(gpa, .{}, null);
    defer db.deinit(gpa);
    try std.testing.expectEqualStrings(da.output.text, db.output.text);
}

test "nesting has no bound: 10,000 levels lint and generate a device" {
    // Every stage after the parse recurses per AST level and runs on a
    // `deep_stack` sized from `Parser.deepest`; 10,000 levels is past the
    // 8 MiB stack the pipeline had (it overflowed near 3,000). 100,000 took
    // 70 s in Debug, half of `zig build test`'s critical path. The if
    // and ?: chains are the worst case of the per-branch walks: every level
    // pushes a prover guard fact on one congruence class (`V(p) > 1`), climbs
    // the SSA arms above it and the setup plan's dominators, each quadratic
    // in the depth until #29 (Debug, 2026-10-15: about 20 s and 0.6-2.2 GB a
    // lint here).
    const gpa = std.testing.allocator;
    for ([_]fixtures.DeepCase{
        .{ .pre = "r = 1.0", .open = "", .mid = "", .close = " + 1.0", .post = ";" },
        .{ .pre = "r = ", .open = "(", .mid = "1.0", .close = ")", .post = ";" },
        .{ .pre = "r = ", .open = "-(", .mid = "1.0", .close = ")", .post = ";" }, // A.8.3: a unary operand is a primary
        .{ .pre = "k = ", .open = "{", .mid = "1'b1", .close = "}", .post = "; r = k;" },
        .{ .open = "begin ", .mid = "r = 1.0;", .close = " end" },
        .{ .pre = "r = ", .open = "V(p) > 1 ? 1 : ", .mid = "0", .post = ";", .device = false },
        .{ .open = "if (V(p) > 1) r = 1; else ", .mid = "r = 0;", .device = false },
        .{ .pre = "r = 0; ", .open = "if (V(p) > 1) ", .mid = "r = 1;", .device = false },
    }) |c| {
        const src = try fixtures.deepSource(gpa, 10_000, c);
        defer gpa.free(src);
        var res = try analyze(gpa, src, .{}, null);
        defer res.deinit(gpa);
        if (c.device) {
            var dev = try res.generate(gpa, .{}, null);
            defer dev.deinit(gpa);
            try std.testing.expect(!dev.refused);
        }
    }
}

test "10,000 sequential ifs compile: SSA, the prover and codegen walk them on no native stack per if" {
    // Each `if` is a join the next one's block is dominated by, so the
    // dominator tree, the SSA read of `x` and the emitted chain are all
    // 10,000 deep. `sqrt` keeps every diamond out of if-conversion (its
    // domain needs the guard, which the prover reads off the edge); `+ 1.0`
    // is converted to selects, which leaves a chain of jumps instead.
    const gpa = std.testing.allocator;
    for ([_]bool{ true, false }) |guarded| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "module seq(p); inout p; electrical p; real x;\nanalog begin\nx = 0.0;\n");
        for (1..10_001) |i| {
            if (guarded)
                try src.print(gpa, "if (V(p) > -{d}.0) x = x + sqrt(V(p) + {d}.0);\n", .{ i, i })
            else
                try src.print(gpa, "if (V(p) > -{d}.0) x = x + 1.0;\n", .{i});
        }
        try src.appendSlice(gpa, "I(p) <+ x;\nend\nendmodule\n");
        var res = try analyze(gpa, src.items, .{}, null);
        defer res.deinit(gpa);
        var dev = try res.generate(gpa, .{}, null);
        defer dev.deinit(gpa);
        const text = dev.output.text;
        try std.testing.expect(!dev.refused);
        const branches = std.mem.count(u8, text, "} else {");
        try std.testing.expectEqual(@as(usize, if (guarded) 10_000 else 0), branches);
    }
}

test "10,000-level ?: chain, else-if chain and nested ifs: device text is linear in the nesting" {
    // The parser and lowering run on a `deep_stack`, codegen on heap stacks
    // (`cfg.emitTree`, `Gen.max_indent`), and the prover, the SSA reads and
    // the setup plan are linear in it (#29), so none of them bounds the depth.
    const gpa = std.testing.allocator;
    // ponytail: 10,000 levels, not 100,000 (72 s in Debug): the indentation
    // cap and the size bound hold at any depth; a quadratic pass shows as a
    // slow test only at the larger one.
    const n = 10_000;
    for ([_]enum { ternary, else_if, nested }{ .ternary, .else_if, .nested }) |shape| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "module deep(p); inout p; electrical p; real x;\nanalog begin\nx = 0.0;\n");
        switch (shape) {
            .ternary => {
                try src.appendSlice(gpa, "x = ");
                for (1..n + 1) |i| try src.print(gpa, "V(p) > -{d}.0 ? ", .{i});
                try src.appendSlice(gpa, "1.0");
                for (1..n + 1) |i| try src.print(gpa, " : {d}.0", .{n + 1 - i});
                try src.appendSlice(gpa, ";\n");
            },
            .else_if => {
                for (1..n + 1) |i| try src.print(gpa, "{s}if (V(p) > {d}.0) x = {d}.0;\n", .{ if (i > 1) "else " else "", i, i });
                try src.appendSlice(gpa, "else x = 0.5;\n");
            },
            .nested => {
                for (1..n + 1) |i| try src.print(gpa, "if (V(p) > -{d}.0) begin x = x + 1.0;\n", .{i});
                for (0..n) |_| try src.appendSlice(gpa, "end\n");
            },
        }
        try src.appendSlice(gpa, "I(p) <+ x * V(p);\nend\nendmodule\n");
        var res = try analyze(gpa, src.items, .{}, null);
        defer res.deinit(gpa);
        var dev = try res.generate(gpa, .{}, null);
        defer dev.deinit(gpa);
        const text = dev.output.text;
        try std.testing.expect(!dev.refused);
        // 1000 levels measured 0.6-1.6 KB a level. Indentation that grew
        // with the depth is what the per-line check below catches.
        try std.testing.expect(text.len < 4096 * n);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            const lead = l.len - std.mem.trimStart(u8, l, " ").len;
            try std.testing.expect(lead <= @import("device").indentWidth(std.math.maxInt(u32)));
        }
    }
}

test "a source with no module of its own is NoModule, with or without the prelude" {
    // §6.2. `compileInArena` sets `builtin_modules` to the annex E prelude's
    // count; were it short, a Table E.1 primitive would be taken as the top
    // and this would compile.
    const gpa = std.testing.allocator;
    for ([_]bool{ true, false }) |std_defs| {
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        try std.testing.expectError(error.NoModule, analyze(gpa, "", .{ .std_defs = std_defs }, &bag));
        // Lowering finds no module and says so, once.
        var e1001: usize = 0;
        for (0..bag.count()) |i| {
            if (bag.at(i).code == .E1001) e1001 += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), e1001);
    }
}

test "a parse error is NoModule only when no module of the source's own was parsed" {
    // `endmodule` with no `module` is E0201; the parser recovers at top level,
    // so in the second source it still parses `res`, and the failure is the
    // diagnosed parse, not a missing module.
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NoModule, analyze(gpa, "endmodule\n", .{}, null));
    try std.testing.expectError(error.CompileFailed, analyze(gpa, "endmodule\n" ++ fixtures.resistor, .{}, null));
}

test "without the prelude, a source that includes the annex D files itself compiles" {
    // `std_defs = false` drops the prepended annex D.1/D.2 text but keeps
    // the Table E.1 primitives (E.2: built-ins), which are never the top: the
    // user's `res` is.
    const gpa = std.testing.allocator;
    var res = try analyze(gpa, "`include \"disciplines.vams\"\n" ++ fixtures.resistor, .{ .std_defs = false }, null);
    defer res.deinit(gpa);
    try std.testing.expectEqualStrings("res", res.mir.name);
    try std.testing.expect(res.verdict.ok());
}

test "without the prelude, the Table E.1 primitives are still built in" {
    // Oracle: annex E.2, the primitives are built-ins "in the same manner
    // ... as built-in primitives of gate- and switch-level modeling", not
    // annex D text. Their `electrical` ports bind to the source's own.
    const gpa = std.testing.allocator;
    const src =
        \\`include "disciplines.vams"
        \\module top(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  resistor #(.r(2.0)) r1(a, b);
        \\endmodule
    ;
    var res = try analyze(gpa, src, .{ .std_defs = false, .require_std_includes = true }, null);
    defer res.deinit(gpa);
    try std.testing.expectEqualStrings("top", res.mir.name);
}

test "a check of a unit of only connect modules or UDPs elaborates nothing and is not E1001" {
    // Oracle: A.1.2 `description` admits a udp_declaration and a
    // `connectmodule` module_declaration; neither is a §6.2.2 root (§7.6).
    const gpa = std.testing.allocator;
    const units = [_][]const u8{
        "",
        "primitive inv(o, a); output o; input a; table 0 : 1; 1 : 0; endtable endprimitive\n",
        "`include \"disciplines.vams\"\nconnectmodule c(a, b); input a; output b; electrical a, b; analog V(b) <+ V(a); endmodule\n",
    };
    for (units) |src| {
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        try std.testing.expectError(error.NothingToElaborate, analyze(gpa, src, .{ .empty_unit_ok = true }, &bag));
        try std.testing.expect(!bag.failed());
    }
    // IEEE 1364-2005 §8.1.1: the output is the first port. Without this the
    // unit above would accept `dump_mux4to1`'s undeclared output.
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    try std.testing.expectError(error.CompileFailed, analyze(gpa, "primitive p(o, a); output q; input a; table 0 : 1; endtable endprimitive\n", .{}, &bag));
    try std.testing.expectEqual(diag.Code.E1100, bag.at(0).code);
}

test "-D: a command-line macro is defined before the source; a bare name is 1" {
    // Oracle: §10.4 `define NAME TEXT, the meaning iverilog gives -D.
    const gpa = std.testing.allocator;
    const src = "`ifdef ON\n`include \"disciplines.vams\"\nmodule res(p, n); inout p, n; electrical p, n; parameter real r = `R; analog I(p, n) <+ V(p, n) / r * `ON; endmodule\n`endif\n";
    try std.testing.expectError(error.NoModule, analyze(gpa, src, .{ .defines = &.{"R=2.0"} }, null));
    var res = try analyze(gpa, src, .{ .defines = &.{ "ON", "R=2.0" } }, null);
    defer res.deinit(gpa);
    try std.testing.expectEqualStrings("res", res.mir.name);
}

test "annex E.2: a SPICE netlist's modules lead the file but are never the top" {
    // The `.SUBCKT` becomes `module rdiv`, placed before the source. Counted
    // among the builtins it is not a candidate top: `res` is. Were it left
    // out of the count, `rdiv` (first, and instantiated by nothing) would be
    // the top, and an empty source would compile.
    const gpa = std.testing.allocator;
    {
        var res = try analyze(gpa, fixtures.resistor, .{ .spice_netlist = fixtures.netlist }, null);
        defer res.deinit(gpa);
        try std.testing.expectEqualStrings("res", res.mir.name);
    }
    try std.testing.expectError(error.NoModule, analyze(gpa, "", .{ .spice_netlist = fixtures.netlist }, null));
}

test "a --deny fails the compilation even with no bag to report into, and frees it" {
    // The denied W0650 lands in the arena's own bag, which is freed with the
    // arena; the testing allocator fails the test on a leak.
    const gpa = std.testing.allocator;
    var levels: diag.Levels = .empty;
    try levels.set(.W0650, .deny);
    try std.testing.expectError(error.CompileFailed, analyze(gpa, fixtures.unbounded_exp, .{ .lint = levels }, null));
}

test "a failed compilation with no bag leaks nothing" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.CompileFailed, analyze(
        gpa,
        "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n",
        .{},
        null,
    ));
}

test "§9.4 W0850 names each task the requested device drops, and no other" {
    const strobe =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ V(p, n);
        \\    $strobe("v=%g", V(p, n));
        \\  end
        \\endmodule
        \\
    ;
    // §9.4.1 `$monitor` needs change detection across accepted points, state
    // a device does not keep, so `say` does not record it
    // (`device.sayRecords`; ch09_system_tasks/say_device_records.va).
    const monitor =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ V(p, n);
        \\    $monitor("%g", V(p));
        \\  end
        \\endmodule
        \\
    ;
    const severity =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  analog begin
        \\    if (V(p, n) > 1.0) $error("v=%g", V(p, n));
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
        \\
    ;
    const file =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  integer fd;
        \\  analog begin
        \\    fd = $fopen("vera_never_written.dat");
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
        \\
    ;
    // `.drop`: the print is gone, and the warning names the task alone.
    try std.testing.expectEqual(1, try fixtures.countW0850(strobe, .drop, "`$strobe`"));
    try std.testing.expectEqual(0, try fixtures.countW0850(strobe, .drop, "records"));
    // `.record`: `say` records `$strobe`, but not `$monitor`.
    try std.testing.expectEqual(0, try fixtures.countW0850(strobe, .record, ""));
    try std.testing.expectEqual(1, try fixtures.countW0850(monitor, .record, "records the printing tasks"));
    // `.emit`: the executable prints; nothing is dropped.
    try std.testing.expectEqual(0, try fixtures.countW0850(strobe, .emit, ""));
    try std.testing.expectEqual(0, try fixtures.countW0850(monitor, .emit, ""));
    // §9.7.3: `$error` reaches the host through the status channel whatever
    // the display mode, so it is never reported as dropped.
    try std.testing.expectEqual(0, try fixtures.countW0850(severity, .drop, ""));
    try std.testing.expectEqual(0, try fixtures.countW0850(severity, .record, ""));
    // §9.5.1: a device has no file table; `$fopen` answers the zero
    // descriptor under `.drop` and `.record` alike (a file task is no
    // printing task, so `say` does not take it).
    try std.testing.expectEqual(1, try fixtures.countW0850(file, .drop, "zero descriptor"));
    try std.testing.expectEqual(1, try fixtures.countW0850(file, .record, "zero descriptor"));
    try std.testing.expectEqual(0, try fixtures.countW0850(file, .emit, ""));
}

// Zig analyses lazily, so an unreferenced decl is never type-checked. This
// forces analysis of every top-level pub decl of every stage.
test "every top-level pub decl of every stage type-checks" {
    const fe = @import("frontend");
    inline for (.{ @This(), @import("base").BigArena, fe.token, fe.keyword, fe.preprocessor, fe.lexer, fe.Ast, fe.Parser, @import("ir").Mir, @import("prove").Analysis, @import("analog").Ssa, @import("elab"), @import("analog").Lower, @import("prove").proof, @import("ir").names, @import("device"), zigbuild, Settings, Result, request, analysis, osdi, verilog, testbench, library, read_failed }) |stage| {
        std.testing.refAllDecls(stage);
    }
}
