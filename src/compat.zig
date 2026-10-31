//! Compat, delete in pass 2: the `vera` module's pre-rewrite API over the new
//! one, so `src/vpi`, `tests/suite.zig`, `tests/unit.zig` and `tests/fuzz.zig`
//! build unchanged until they migrate (`api/vera.md` maps every name). Old
//! `Options` in, the old `CompileResult` out: `compileSourceOpts` is
//! `Compilation.analyze` plus the codegen cache the old result kept.
//!
//! Cites: none (no behaviour of its own).
//!
//! Contents:
//! - `pub const Target`, `pub const Error`, `pub const Options`,
//!   `pub const CompileResult` (`deinit`, `generateDevice`, `generateOutput`)
//! - `pub const BigArena`, `pub const Preprocessor`, `pub const libmap`,
//!   `pub const codegen`, `pub const orchestrator`, `pub const tb`,
//!   `pub const Elaborate`
//! - `pub fn compileSource(gpa: Allocator, source: []const u8, target: Target) Error!CompileResult`
//! - `pub fn compileSourceOpts(gpa: Allocator, source: []const u8, target: Target, opts: Options) Error!CompileResult`
//! - `pub fn buildArtifact(gpa: Allocator, io: std.Io, result: *CompileResult, o: orchestrator.Options, generation: u32) !orchestrator.Result`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const proof = @import("prove").proof;
const Settings = @import("Compilation/Settings.zig");
const Result = @import("Compilation/Result.zig");
const analysis = @import("Compilation/analyze.zig");

/// Old: `BigArena` re-export. New: `@import("base").BigArena`.
pub const BigArena = @import("base").BigArena;
/// Old: `Preprocessor` re-export. New: `@import("frontend").Preprocessor`.
pub const Preprocessor = @import("frontend").Preprocessor;
/// Old: `libmap` re-export. New: `@import("frontend").libmap`.
pub const libmap = @import("frontend").libmap;
/// Old: `codegen` re-export. New: `@import("device").codegen`.
pub const codegen = @import("device").codegen;
/// Old: `orchestrator` re-export. New: `@import("zigbuild")`.
pub const orchestrator = @import("zigbuild");
/// Old: `tb` re-export. New: `@import("exe")`.
pub const tb = @import("exe");
/// Old: `Elaborate` re-export. New: `@import("elab").Elaborate`.
pub const Elaborate = @import("elab").Elaborate;

/// Old: how far the pipeline runs. New: `analyze` always runs through the
/// proof, and any `Result` can `generate`; only `buildArtifact` read this.
pub const Target = enum { lint, build };

/// Old: `compileSource`'s and `generateDevice`'s failures together. New:
/// `Compilation.AnalyzeError` and `codegen.Error`.
pub const Error = codegen.Error || error{ CompileFailed, NoModule, NothingToElaborate, NoArtifact };

/// Old: `Settings` plus the bag (now `analyze`'s parameter) and the codegen
/// switches (now `Result.Codegen`).
pub const Options = struct {
    file_name: []const u8 = "<source>",
    include_dirs: []const []const u8 = &.{},
    param_overrides: []const Elaborate.ParamOverride = &.{},
    discipline_resolution: Elaborate.DisciplineResolution = .basic,
    std_defs: bool = true,
    defines: []const []const u8 = &.{},
    empty_unit_ok: bool = false,
    require_std_includes: bool = false,
    language: @FieldType(Settings, "language") = @import("frontend").token.default_keyword_set,
    sim: @FieldType(Settings, "sim") = .verilog_ams,
    diags: ?*diag.Bag = null,
    lint: diag.Levels = .empty,
    proof: proof.Options = .{},
    spice_netlist: []const u8 = "",
    spice_path: []const u8 = "",
    display: codegen.Display = .drop,
    jac_f32: bool = false,
    jac_f32_host: bool = false,
    vpi_contribs: bool = false,
    int_systfs: []const []const u8 = &.{},
};

/// Old: the result with its gpa, its target and a cached device. New:
/// `Compilation.Result` (`deinit(gpa)`) and `Result.generate`'s `Device`.
pub const CompileResult = struct {
    gpa: Allocator,
    arena: *BigArena,
    source: []const u8,
    mir: *const Mir,
    lowered: *const Lowered,
    file: *const Ast.SourceFile,
    module: ?*const Ast.ModuleDecl = null,
    unit_paths: []const Elaborate.UnitPath = &.{},
    diags: *const diag.Bag,
    verdict: proof.Verdict,
    target: Target,
    device: codegen.Output = .{ .text = "" },
    device_has_compile_error: bool = false,
    codegen_opts: codegen.Options = .{},
    nesting: u32 = 0,

    /// Old: `deinit()`. New: `Result.deinit(gpa)`, and `Device.deinit(gpa)`.
    pub fn deinit(self: *CompileResult) void {
        self.gpa.free(self.device.text);
        var r = self.view();
        r.deinit(self.gpa);
        self.* = undefined;
    }

    /// Old: codegen, cached. New: `Result.generate(gpa, opts, bag).output.text`.
    pub fn generateDevice(self: *CompileResult) codegen.Error![]const u8 {
        return (try self.generateOutput()).text;
    }

    /// Old: codegen once, cached on the result. New: `Result.generate`,
    /// whose `Device` the caller owns.
    pub fn generateOutput(self: *CompileResult) codegen.Error!codegen.Output {
        if (self.device.text.len == 0) {
            const c = self.codegen_opts;
            const d = try self.view().generate(self.gpa, .{
                .jac_f32 = c.jac_f32,
                .jac_f32_host = c.jac_f32_host,
                .vpi_contribs = c.vpi_contribs,
            }, c.diags);
            self.device = d.output;
            self.device_has_compile_error = d.refused;
        }
        assert(self.device.text.len != 0);
        return self.device;
    }

    fn view(self: *const CompileResult) Result {
        return .{
            .arena = self.arena,
            .source = self.source,
            .file = self.file,
            .module = self.module,
            .unit_paths = self.unit_paths,
            .mir = self.mir,
            .lowered = self.lowered,
            .diags = self.diags,
            .verdict = self.verdict,
            .display = self.codegen_opts.display,
            .nesting = self.nesting,
        };
    }
};

/// Old: `compileSourceOpts` with default options. New: `analyze(gpa, source, .{}, null)`.
pub fn compileSource(gpa: Allocator, source: []const u8, target: Target) Error!CompileResult {
    return compileSourceOpts(gpa, source, target, .{});
}

/// Old: the analysis with the bag in `opts.diags`. New: `analyze(gpa,
/// source, settings, bag)`; the codegen switches go to `Result.generate`.
pub fn compileSourceOpts(gpa: Allocator, source: []const u8, target: Target, opts: Options) Error!CompileResult {
    const r = try analysis.analyze(gpa, source, .{
        .file_name = opts.file_name,
        .include_dirs = opts.include_dirs,
        .defines = opts.defines,
        .std_defs = opts.std_defs,
        .require_std_includes = opts.require_std_includes,
        .language = opts.language,
        .sim = opts.sim,
        .param_overrides = opts.param_overrides,
        .discipline_resolution = opts.discipline_resolution,
        .empty_unit_ok = opts.empty_unit_ok,
        .spice_netlist = opts.spice_netlist,
        .spice_path = opts.spice_path,
        .lint = opts.lint,
        .proof = opts.proof,
        .display = opts.display,
        .int_systfs = opts.int_systfs,
    }, opts.diags);
    return .{
        .gpa = gpa,
        .arena = r.arena,
        .source = r.source,
        .mir = r.mir,
        .lowered = r.lowered,
        .file = r.file,
        .module = r.module,
        .unit_paths = r.unit_paths,
        .diags = r.diags,
        .verdict = r.verdict,
        .target = target,
        .nesting = r.nesting,
        .codegen_opts = .{
            .display = opts.display,
            .jac_f32 = opts.jac_f32,
            .jac_f32_host = opts.jac_f32_host,
            .vpi_contribs = opts.vpi_contribs,
            .diags = opts.diags,
        },
    };
}

/// Old: generates the device and builds it cold into `lib<name>.<generation>.so`.
/// New: `Compilation.compile` with `Request.so`, or `orchestrator.compileRelease`
/// on `Result.generate`'s output. Fails with `error.NoArtifact` on a `.lint` result.
pub fn buildArtifact(
    gpa: Allocator,
    io: std.Io,
    result: *CompileResult,
    o: orchestrator.Options,
    generation: u32,
    // Inferred: the orchestrator's failures are the OS errors of a child.
) !orchestrator.Result {
    if (result.target == .lint) return error.NoArtifact;
    return orchestrator.compileRelease(gpa, io, o, try result.generateOutput(), generation);
}

test buildArtifact {
    // `.lint` is refused before codegen or the orchestrator runs, so these
    // options are never read: no directory, no child process.
    const gpa = std.testing.allocator;
    var res = try compileSource(gpa, "module res(p, n); inout p, n; electrical p, n; analog I(p, n) <+ V(p, n);\nendmodule\n", .lint);
    defer res.deinit();
    try std.testing.expectError(error.NoArtifact, buildArtifact(gpa, std.testing.io, &res, .{
        .work_dir = "",
        .name = "res",
        .optimize = .debug,
        .backend = .self_hosted,
        .modules = &.{},
    }, 0));
    try std.testing.expectEqual(@as(usize, 0), res.device.text.len);
}

test "generateDevice runs codegen once and hands back the cached text" {
    const gpa = std.testing.allocator;
    var res = try compileSource(gpa, "module res(p, n); inout p, n; electrical p, n; analog I(p, n) <+ V(p, n);\nendmodule\n", .build);
    defer res.deinit();
    // The pipeline itself never runs codegen.
    try std.testing.expectEqual(@as(usize, 0), res.device.text.len);
    const first = try res.generateDevice();
    try std.testing.expect(first.len != 0);
    try std.testing.expect(!res.device_has_compile_error);
    // The same slice, not an equal copy: the second call ran no codegen.
    const second = try res.generateDevice();
    try std.testing.expect(first.ptr == second.ptr and first.len == second.len);
    const out = try res.generateOutput();
    try std.testing.expect(out.text.ptr == first.ptr);
}
