//! The Zig build driver: device text (`Output`) and testbench runner text in,
//! a versioned `.so` (§8.3 device-side ABI), a prebuilt engine object, a
//! testbench binary or a `--check` verdict out, each from a spawned `zig`
//! child. Re-exports only; the files import each other directly. Imports no
//! compiler module: the spine hands it bytes.
//! `contract`: `Part` is the host's `DevicePart`. `dynlib`: only the tests
//! that load what they built. No LRM clause beyond §8.3's ABI: the argv and
//! the protocol are Zig's.

const orchestrator = @import("orchestrator.zig");
const exe = @import("exe.zig");

/// Which Zig code generator builds an artifact.
pub const Backend = orchestrator.Backend;
/// One support module on the compiler command line.
pub const Module = orchestrator.Module;
/// How a `.so` build compiles and where it writes.
pub const Options = orchestrator.Options;
/// The generated device text and its per-unit ranges.
pub const Output = orchestrator.Output;
/// A `.so` build outcome.
pub const Result = orchestrator.Result;
/// The pieces a split build compiles in parallel (`contract.DevicePart`).
pub const Part = orchestrator.Part;
/// A module name as a file-name stem: kept when short and plain, else a
/// plain prefix and a hash, so any §2.8.1 escaped name is a legal file name.
pub const fileStem = orchestrator.fileStem;
/// Writes the device tree a `.so` build compiles, touching only changed files.
pub const writeTree = orchestrator.writeTree;
/// Builds a device into `lib<name>.<generation>.so`.
pub const compileRelease = orchestrator.compileRelease;
/// Builds `sim`'s runtime as a position-independent object for `Options.engine`.
pub const buildEngine = orchestrator.buildEngine;

/// How `buildExe` builds and where it writes.
pub const BuildOptions = exe.BuildOptions;
/// A testbench build outcome.
pub const BuildResult = exe.BuildResult;
/// Builds device.zig and the runner into one native binary.
pub const buildExe = exe.buildExe;
/// A testbench's module files on disk.
pub const Staged = exe.Staged;
/// Writes a testbench's module files without building.
pub const stage = exe.stage;
/// Builds several staged testbenches into one binary.
pub const buildBatch = exe.buildBatch;
/// The `sim` runtime's module rows, roots relative to the VerA tree; must
/// match build.zig's `module_specs` for `sim` and what it imports.
pub const runtime_modules = exe.runtime_modules;
/// The VerA tree a `contract` root sits in (`<tree>/lib/contract.zig`).
pub const treeOf = exe.treeOf;
/// The `argv[0]` prefix a batch binary dispatches on.
pub const batch_argv0 = exe.batch_argv0;
/// `--check`: type-checks device text against the contract with `zig build-obj`.
pub const typeCheck = @import("check.zig").typeCheck;

test {
    @import("std").testing.refAllDecls(@This());
    _ = orchestrator;
    _ = exe;
    _ = @import("shim.zig");
    _ = @import("server.zig");
}
