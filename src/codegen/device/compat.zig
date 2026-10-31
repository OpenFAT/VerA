//! Pass-1 shim, delete in pass 2: the device module's old public names, each
//! mapped onto the new API so the full-tree oracles keep building while the
//! callers (`src/Compilation.zig`, `src/cli/args.zig`) still use them. Every
//! mapping is listed in the api file (`api/device.md`).
//! Cites: none.
//!
//! Contents:
//! - `pub const codegen = struct`
//! - `pub const cg_display = struct`
//! - `pub const cg_filters = struct`
//! - `pub const cg_limit = struct`
//! - members: `codegen.Error`, `codegen.Display`, `codegen.Options`, `codegen.Output`,
//!   `codegen.Harness`, `codegen.kernel_text`, `codegen.generate`, `codegen.Gen`,
//!   `codegen.Gen.indWidth`, `cg_display.sayRecords`, `cg_filters.FilterPlan`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const proof = @import("prove").proof;
const new = @import("codegen.zig");

/// Old `device.codegen`.
pub const codegen = struct {
    /// Now `device.Error`.
    pub const Error = new.Error;
    /// Now `device.Display`.
    pub const Display = new.Display;
    /// Now `device.Options`.
    pub const Options = new.Options;
    /// Now `device.Output`.
    pub const Output = new.Output;
    /// Now `device.Harness`.
    pub const Harness = @import("codegen/harness.zig").Harness;
    /// Now `device.kernel_text`.
    pub const kernel_text = @import("codegen/kernel_text.zig");

    /// Old `codegen.generate`: now `device.generate`, which returns
    /// `Device{ .output, .compile_error }` instead of writing `fatal_out`.
    pub fn generate(
        gpa: Allocator,
        arena: Allocator,
        mir: *const Mir,
        lowered: *const Lowered,
        verdict: proof.Verdict,
        fatal_out: *bool,
        opts: new.Options,
    ) new.Error!new.Output {
        const device = try new.generate(gpa, arena, mir, lowered, verdict, opts);
        fatal_out.* = device.compile_error;
        return device.output;
    }

    /// Old `codegen.Gen`, of which only `indWidth` was used outside.
    pub const Gen = struct {
        /// Now `device.indentWidth`.
        pub const indWidth = new.Gen.indWidth;
    };
};

/// Old `device.cg_display`, of which only `sayRecords` was used outside.
pub const cg_display = struct {
    /// Now `device.sayRecords`.
    pub const sayRecords = @import("cg_say.zig").sayRecords;
};

/// Old `device.cg_filters`: named only in `Compilation.zig`'s refAllDecls list.
pub const cg_filters = struct {
    /// Internal now; named so the old refAllDecls still has a decl to check.
    pub const FilterPlan = @import("cg_filters.zig").FilterPlan;
};

/// Old `device.cg_limit`: no caller outside the module used it.
pub const cg_limit = struct {};
