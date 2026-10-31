//! The Zig build driver: generated device text (`Output`) and testbench
//! runner text in, a versioned shared library (§8.3 device-side ABI), a
//! prebuilt engine object, a testbench binary or a `--check` verdict out,
//! each from a spawned `zig` child. Re-exports only; the files import each
//! other directly. Imports no compiler module: the spine hands it bytes.
//! `contract`: `DevicePart`, the pieces of a split build. `dynlib`: only the
//! tests that load what they built. No LRM clause beyond §8.3's ABI: the argv
//! and the protocol are Zig's.
//!
//! Contents:
//! - library builds: `Backend`, `Module`, `Split`, `Options`, `Output`,
//!   `Artifact`, `BuildError`, `buildLibrary`, `buildEngine`
//! - the device tree: `Tree`, `Engine`, `TreeError`, `writeTree`, `fileStem`
//! - testbenches: `BuildOptions`, `BuildResult`, `ExeError`, `StageError`,
//!   `Staged`, `buildExe`, `stage`, `buildBatch`, `batch_argv0`,
//!   `runtime_modules`, `treeOf`
//! - `--check`: `Check`, `Verdict`, `CheckError`, `typeCheck`

const argv = @import("argv.zig");
const check = @import("check.zig");
const exe = @import("exe.zig");
const library = @import("library.zig");
const shim = @import("shim.zig");
const tree = @import("tree.zig");

/// Which Zig code generator builds an artifact.
pub const Backend = argv.Backend;
/// One support module on the compiler command line.
pub const Module = argv.Module;
/// How a library build is cut into compiler processes.
pub const Split = argv.Split;
/// How a library build compiles and where it writes.
pub const Options = argv.Options;
/// The generated device text and its per-unit columns.
pub const Output = tree.Output;
/// A library or engine build's outcome: the built file's path, or the report.
pub const Artifact = library.Artifact;
/// Every way a library or engine build fails short of a report.
pub const BuildError = library.BuildError;
/// Builds a device into `lib<name>.<generation>.so`.
pub const buildLibrary = library.buildLibrary;
/// Builds `sim`'s runtime as a position-independent object for `Options.engine`.
pub const buildEngine = library.buildEngine;

/// Where `writeTree` writes and what its shim declares.
pub const Tree = tree.Tree;
/// Whether a library links `sim`'s prebuilt engine object.
pub const Engine = shim.Engine;
/// Every way `writeTree` fails.
pub const TreeError = tree.TreeError;
/// Writes the device tree a library build compiles, touching only changed files.
pub const writeTree = tree.writeTree;
/// A module name as a file-name stem: kept when short and plain, else a
/// plain prefix and a hash, so any §2.8.1 escaped name is a legal file name.
pub const fileStem = tree.fileStem;

/// How a testbench build builds and where it writes.
pub const BuildOptions = exe.BuildOptions;
/// A testbench build's outcome.
pub const BuildResult = exe.BuildResult;
/// Every way a testbench build fails short of a compiler report.
pub const ExeError = exe.ExeError;
/// Every way `stage` fails.
pub const StageError = exe.StageError;
/// A testbench's module files on disk.
pub const Staged = exe.Staged;
/// Builds the device and the runner into one native binary.
pub const buildExe = exe.buildExe;
/// Writes a testbench's module files without building.
pub const stage = exe.stage;
/// Builds several staged testbenches into one binary.
pub const buildBatch = exe.buildBatch;
/// The `argv[0]` prefix a batch binary dispatches on.
pub const batch_argv0 = exe.batch_argv0;
/// The `sim` runtime's module rows, roots relative to the VerA tree; must
/// match build.zig's `module_specs` for `sim` and what it imports.
pub const runtime_modules = exe.runtime_modules;
/// The VerA tree a `contract` root sits in (`<tree>/lib/contract.zig`).
pub const treeOf = exe.treeOf;

/// What `typeCheck` checks.
pub const Check = check.Check;
/// Whether a device type-checks against the contract.
pub const Verdict = check.Verdict;
/// Every way `typeCheck` fails short of a verdict.
pub const CheckError = check.CheckError;
/// `--check`: type-checks device text against the contract with `zig build-obj`.
pub const typeCheck = check.typeCheck;

test {
    @import("std").testing.refAllDecls(@This());
    _ = argv;
    _ = @import("artifact_cache.zig");
    _ = check;
    _ = exe;
    _ = library;
    _ = @import("server.zig");
    _ = shim;
    _ = tree;
}
