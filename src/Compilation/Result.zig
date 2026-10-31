//! One analysed source: the MIR, lowering's tables, the elaborated AST, the
//! proof's verdict and the diagnostics' file table, all in one arena. In:
//! what `analyze.zig` built. Out: `generate`'s device text (codegen, LRM §5,
//! §8.3), which the caller owns.
//!
//! Owns every allocation of the analysis. The preprocessed text, tokens,
//! AST, MIR and lowering's tables live in `arena`; only
//! `verdict.unit_modes` is the gpa's. `deinit` frees both. The value is
//! freely movable; `arena` itself is on the heap because the AST and the SSA
//! builder kept an `Allocator` whose `ptr` is its address.
//!
//! Cites: §6.2 (`module`), §9.4 (`display`), §9.15/§9.16 (`unit_paths`),
//! IEEE 1364-2005 §26.3.3 (`diags`, the VPI's vpiLineNo).
//!
//! Contents:
//! - fields `arena`, `source`, `file`, `module`, `unit_paths`, `mir`,
//!   `lowered`, `diags`, `verdict`, `display`, `nesting`
//! - `pub const Codegen = struct`, `pub const Device = struct`,
//!   `Device.deinit(d: *Device, gpa: Allocator) void`
//! - `pub fn deinit(r: *Result, gpa: Allocator) void`
//! - `pub fn generate(r: *const Result, gpa: Allocator, opts: Codegen, bag: ?*diag.Bag) device.Error!Device`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const BigArena = @import("base").BigArena;
const deep_stack = @import("base").deep_stack;
const diag = @import("diag");
const Ast = @import("frontend").Ast;
const Unit = @import("elab").design.Unit;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const proof = @import("prove").proof;
const device = @import("device");

/// Owns every slice and pointer below except `verdict.unit_modes`.
arena: *BigArena,
/// The preprocessed source; every AST and MIR string borrows from it.
source: []const u8,
/// The parsed and elaborated AST, which `lowered` does not hold: the VPI's
/// object model walks it, and no compiler stage after lowering reads it.
file: *const Ast.SourceFile,
/// The module lowered (§6.2), elaboration's flattened top.
module: ?*const Ast.ModuleDecl,
/// §9.15/§9.16 the module and instance path of each inlined analog block,
/// by `Ast.AnalogBlock.unit` (`elab.Design.units`).
unit_paths: std.MultiArrayList(Unit).Slice,
/// The top module's MIR, if-converted and proven. Nothing writes it again.
mir: *const Mir,
/// Lowering's output. Nothing after lowering can reach a symbol table, a
/// scope or the SSA builder.
lowered: *const Lowered,
/// The analysis' own diagnostics: its file table and source map turn a
/// `Lowered.tok_starts` offset into a file and line. The caller's bag got a
/// detached copy of the same rows.
diags: *const diag.Bag,
/// One float mode per unit; `unit_modes` is gpa-owned.
verdict: proof.Verdict,
/// The §9.4 mode lowering ran under; `generate` builds the device for it.
display: device.Display,
/// The source's nesting depth (`Parser.deepest`): codegen's walks run on a
/// `deep_stack` reserved for it.
nesting: u32,

/// What `generate` emits beyond what the analysis fixed.
pub const Codegen = struct {
    /// Emits `pub const jac_f32 = true`: the device tolerates a host scalar
    /// whose derivative half is single precision.
    jac_f32: bool = false,
    /// Also emits `pub const jac_f32_host = true`: the host should take that
    /// permission on its CPU instantiation too. Implies `jac_f32`.
    jac_f32_host: bool = false,
    /// Also emits `vpiContribs` and `vpiShares`, the §5.6 contribution rows a
    /// Clause 12 analog host reads.
    vpi_contribs: bool = false,
};

/// A generated device.zig. `output.text` is the caller's (gpa); the per-unit
/// file map in `output` borrows from the `Result` and lives until its `deinit`.
pub const Device = struct {
    output: device.Output,
    /// Codegen refused a construct, in an `@compileError` unit or in metadata
    /// outside the units: the text is not a usable device. It is kept so a
    /// caller can name what was refused.
    refused: bool,

    /// Frees the text; invalidates `output.text`.
    pub fn deinit(d: *Device, gpa: Allocator) void {
        gpa.free(d.output.text);
        d.* = undefined;
    }
};

const Result = @This();

/// Frees the arena and the verdict; invalidates every slice borrowed from
/// the result. `gpa` is the allocator `analyze` was given.
pub fn deinit(r: *Result, gpa: Allocator) void {
    r.verdict.deinit(gpa);
    r.arena.deinit();
    gpa.destroy(r.arena);
    r.* = undefined;
}

/// Runs codegen and returns the device text, which the caller owns and frees
/// with `Device.deinit(gpa)`. Each call emits again; codegen's scratch tables
/// grow the result's arena. A codegen diagnostic (E0515) goes to `bag`. A
/// stack the system will not reserve for `nesting` is `error.OutOfMemory`.
/// Asserts that the verdict accepted the model, which `analyze` guarantees.
pub fn generate(r: *const Result, gpa: Allocator, opts: Codegen, bag: ?*diag.Bag) device.Error!Device {
    assert(r.verdict.ok());
    assert(r.verdict.unit_modes.len == proof.unitCount(r.lowered));
    const d = deep_stack.run(r.nesting, device.generate, .{
        gpa,
        r.arena.allocator(),
        r.mir,
        r.lowered,
        r.verdict,
        device.Options{
            .display = r.display,
            .jac_f32 = opts.jac_f32,
            .jac_f32_host = opts.jac_f32_host,
            .vpi_contribs = opts.vpi_contribs,
            .diags = bag,
        },
    }) catch |err| switch (err) {
        // The analysis already ran a stack this deep, so this is rare.
        error.DeepStackUnavailable => return error.OutOfMemory,
        else => |e| return e,
    };
    assert(d.output.text.len != 0);
    return .{ .output = d.output, .refused = d.compile_error };
}
