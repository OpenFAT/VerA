//! The request and outcome of one `Compilation.compile`: which targets a
//! command line asks for and how `zig` runs (in), what was built and what
//! to print (out). Plain values; the spine fills `Outcome`.
//!
//! Cites: IEEE 1364-2005 §17.10 (`Outcome.plusargs`), §4.6.4.6 and §9.17
//! (what `Request.osdi` refuses).
//!
//! Contents:
//! - `pub const CompileError = Allocator.Error || Io.Writer.Error || TypeCheckError`
//! - `pub const Request = struct` (`Request.Verilog`, `Request.Exe`,
//!   `Request.Build`), `Request.lints(req: Request) bool`
//! - `pub const Outcome = struct` (`Outcome.Report`), `Outcome.deinit(o: *Outcome, gpa: Allocator) void`,
//!   `Outcome.done(o: *Outcome, status: u8) void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zigbuild = @import("zigbuild");
const Settings = @import("Settings.zig");
const Result = @import("Result.zig");
const analysis = @import("analyze.zig");

/// Every way `compile` fails, as opposed to refusing (`Outcome.status`):
/// memory, a message the arena could not hold, or a `zig` child that could
/// not be run for `--check`. `o` is filled as far as the call got.
pub const CompileError = Allocator.Error || Io.Writer.Error || TypeCheckError;

/// What one `compile` call builds: the analysis' settings, then one field per
/// target. With no target on, the call is `vera --lint`: the analysis, then
/// the diagnostics.
pub const Request = struct {
    /// `file_name` names the source in every message. `compile` fills the
    /// SPICE fields from `spice_path`, appends the testbench's shape cards
    /// after `param_overrides`, sets `empty_unit_ok` for a request that
    /// builds nothing, and makes `display` `.record` and
    /// `discipline_resolution` `.detail` when the testbench asks.
    options: Settings = .{},
    /// What codegen emits for `check`, `exe`, `so` and `zig`.
    codegen: Result.Codegen = .{},
    /// `--spice`: an annex E.2 netlist, read whole beside the source.
    spice_path: ?[]const u8 = null,
    /// `--emit-verilog`: the behavioural module, and nothing else.
    verilog: ?Verilog = null,
    /// `--emit-osdi`, with `so` and the OSDI dyn as `build.dyn`: refuses what
    /// OSDI 0.4 cannot carry (E1099; W1098 warns) before `so` builds, and
    /// copies the library to `out_path`, else `<module>.osdi`.
    osdi: bool = false,
    /// `--expect-module`: refuses a top module of another name.
    expect_module: ?[]const u8 = null,
    /// `--check`: type-checks the device under the contract's checks.
    check: bool = false,
    /// `--emit-exe`/`--run`: builds the testbench `Outcome.exe` names.
    exe: ?Exe = null,
    /// `--emit-so`: builds the device into a library (`Outcome.path`).
    so: bool = false,
    /// `--emit-zig`: the device text, in `out_path` or on `Outcome.text`.
    zig: bool = false,
    /// `-o`: where `zig`, `verilog`, `exe` or `osdi` writes its artifact.
    out_path: ?[]const u8 = null,
    /// How `check`, `exe` and `so` run `zig`.
    build: Build = .{},

    /// `--emit-verilog`'s pins and supply.
    pub const Verilog = struct {
        /// `--digital-pins`: a file of port names when one exists, else the list.
        digital_pins: ?[]const u8 = null,
        power_pins: bool = false,
        /// Logic-high potential in volts.
        vdd: f64 = 1.8,
    };

    /// `--emit-exe`'s testbench settings.
    pub const Exe = struct {
        /// `--validate-contract`: the contract's checks on in the testbench.
        validate_contract: bool = false,
    };

    /// The `zig` children's settings.
    pub const Build = struct {
        /// The `contract` module root. `check`, `exe` and `so` need it.
        contract: ?[]const u8 = null,
        /// The `dyn` module root (`so`).
        dyn: ?[]const u8 = null,
        /// Scratch and artifact directory; `exe` and `osdi` default to
        /// `.zig-cache/vera-tb`, and `so` without `osdi` needs one.
        work_dir: ?[]const u8 = null,
        zig_exe: []const u8 = "zig",
        optimize: std.lang.Optimize = .fast,
        backend: zigbuild.Backend = .llvm,
        /// Keep DWARF in a release artifact.
        debug_info: bool = false,
        /// `zigbuild.Options.artifact_cache` for an `osdi` build.
        artifact_cache: ?[]const u8 = null,
    };

    /// Whether the request builds nothing: `vera --lint`.
    pub fn lints(req: Request) bool {
        return req.verilog == null and !req.check and req.exe == null and !req.so and !req.zig;
    }
};

/// What `compile` did, for its caller to print: stdout gets `path`, then
/// `text`; stderr gets `err` and the bag in the order `report` says. Every
/// slice lives in the arena `compile` was given or in `device`, which
/// `deinit` frees. Start it as `.{}`.
pub const Outcome = struct {
    /// Exit status: 0 built, 1 refused or failed, 2 a request this source
    /// cannot take.
    status: u8 = 0,
    /// The library `so` built (`osdi`: where it was copied).
    path: ?[]const u8 = null,
    /// The device (`zig`) or the Verilog module (`verilog`) when no
    /// `out_path` took it.
    text: []const u8 = "",
    /// The testbench `exe` built.
    exe: ?[]const u8 = null,
    /// The testbench's `//! plusargs` (IEEE 1364 §17.10), the argv `--run`
    /// gives `exe` after its path.
    plusargs: []const []const u8 = &.{},
    /// The refusal; empty when there is none.
    err: []const u8 = "",
    /// Whether the bag's diagnostics are printed, and where.
    report: Report = .none,
    /// The analysis, once one succeeded.
    result: ?Result = null,
    /// The generated device, once codegen ran; `text` may borrow it.
    device: ?Result.Device = null,

    /// Where the bag's diagnostics go relative to `err` on stderr.
    pub const Report = union(enum) {
        /// `err` alone: the call stopped before the diagnostics were final.
        none,
        /// `err`, then the bag.
        after,
        /// The analysis failed: the bag, then this error's name unless the
        /// bag explains it (`CompileFailed`, `NoModule`).
        failed: analysis.Error,
    };

    /// Frees `device` and `result`; invalidates every slice borrowed from
    /// them. `gpa` is the one `compile` was given.
    pub fn deinit(o: *Outcome, gpa: Allocator) void {
        if (o.device) |*d| d.deinit(gpa);
        if (o.result) |*r| r.deinit(gpa);
        o.* = undefined;
    }

    /// Sets the exit status, once per `compile`. Asserts that it is one of
    /// the statuses `status` documents and that none was set before.
    pub fn done(o: *Outcome, status: u8) void {
        assert(status <= 2);
        assert(o.status == 0); // One verdict per call.
        o.status = status;
    }
};

/// `zigbuild.typeCheck`'s failures: the OS errors of a child process and its
/// pipe. Inferred until zigbuild names it (`CheckError`).
const TypeCheckError = @typeInfo(@typeInfo(@TypeOf(zigbuild.typeCheck)).@"fn".return_type.?).error_union.error_set;
