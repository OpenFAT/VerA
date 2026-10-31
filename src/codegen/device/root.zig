//! Device module root: proven MIR in, device.zig text out (`generate`);
//! `zigbuild` builds it. Re-exports only. Depends on `ir`, `prove`, `diag`,
//! `kernels` (the text spliced into every device) and `zigbuild` (`Output`);
//! the test support (`Harness`) takes `frontend` and `analog` to parse and
//! lower source, and one test takes `dynlib` to load what it built. Neither
//! the testbench (`exe`) nor `--emit-verilog` (`verilog`) is reachable from
//! here.
//! Cites: none of its own (see `codegen.zig`).
//!
//! Contents:
//! - `pub const Harness = @import("codegen/harness.zig").Harness`
//! - `pub const kernel_text = @import("codegen/kernel_text.zig")`
//! - `pub const generate = codegen_file.generate`
//! - `pub const Options = codegen_file.Options`
//! - `pub const Device = codegen_file.Device`
//! - `pub const Error = codegen_file.Error`
//! - `pub const Display = codegen_file.Display`
//! - `pub const Output = codegen_file.Output`
//! - `pub const sayRecords = cg_say.sayRecords`
//! - `pub const indentWidth = codegen_file.Gen.indWidth`
//! - `pub const codegen = compat.codegen`
//! - `pub const cg_display = compat.cg_display`
//! - `pub const cg_filters = compat.cg_filters`
//! - `pub const cg_limit = compat.cg_limit`

const codegen_file = @import("codegen.zig");
const cg_say = @import("cg_say.zig");
const compat = @import("compat.zig");

/// Test support: a source lowered and generated (codegen/harness.zig).
pub const Harness = @import("codegen/harness.zig").Harness;

/// The runtime kernels a device carries, as Zig source text.
pub const kernel_text = @import("codegen/kernel_text.zig");

/// Emits a device from proven MIR; see `codegen.generate`.
pub const generate = codegen_file.generate;

/// Settings that change what is generated.
pub const Options = codegen_file.Options;

/// `generate`'s result: the device text and whether any part was refused.
pub const Device = codegen_file.Device;

/// Every way `generate` fails.
pub const Error = codegen_file.Error;

/// §9.4: whether display tasks are dropped, recorded or emitted.
pub const Display = codegen_file.Display;

/// The generated device and its per-unit ranges (`zigbuild.Output`).
pub const Output = codegen_file.Output;

/// §9.4: whether a `.record` device's `say` records display call `inst`.
pub const sayRecords = cg_say.sayRecords;

/// The spaces the emitter indents `n` levels with (capped, so deep nesting
/// stays linear in text).
pub const indentWidth = codegen_file.Gen.indWidth;

/// Pass-1 shim: the old `device.codegen` namespace. Delete in pass 2.
pub const codegen = compat.codegen;

/// Pass-1 shim: the old `device.cg_display` namespace. Delete in pass 2.
pub const cg_display = compat.cg_display;

/// Pass-1 shim: the old `device.cg_filters` namespace. Delete in pass 2.
pub const cg_filters = compat.cg_filters;

/// Pass-1 shim: the old `device.cg_limit` namespace. Delete in pass 2.
pub const cg_limit = compat.cg_limit;

// ---- private ----

test {
    @import("std").testing.refAllDecls(@This());
    _ = codegen_file;
    _ = @import("cg_display.zig");
    _ = @import("cg_filters.zig");
    _ = @import("cg_limit.zig");
    _ = @import("cg_strcap.zig");
}
