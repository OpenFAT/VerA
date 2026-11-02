//! The one test compilation that imports every module (`modules`, and
//! `refAllDecls` over all of them: Zig analyses lazily, so an unreferenced
//! `pub` decl is otherwise never type-checked), the unit tests that reach a
//! module only through its public API (one namespace per module; a test of a
//! file's private declarations stays beside that file), and the claims that
//! span two modules neither of which imports the other: `contract_names` and
//! `exhaustive_tests`.
//!
//! Each namespace is its own file, `unit/<namespace>.zig`, named as the
//! namespace so its tests keep their names (`unit.parser_tests.test...`);
//! it keeps its own imports. This file declares only the namespaces and the
//! test below.
//!
//! Contents:
//! - `pub const fuzz_targets`
//! - `pub const kernel_tests`
//! - `pub const integer_tests`
//! - `pub const proof_tests`
//! - `pub const ssa_tests`
//! - `pub const prove_oom_tests`
//! - `pub const zigbuild_tests`
//! - `pub const lower_tests`
//! - `pub const rtlil_tests`
//! - `pub const diag_tests`
//! - `pub const preprocessor_tests`
//! - `pub const sim_digital_tests`
//! - `pub const codegen_tests`
//! - `pub const verilog_tests`
//! - `pub const digital_tests`
//! - `pub const exe_tests`
//! - `pub const vpi_tests`
//! - `pub const oom_tests`
//! - `pub const ulp_tests`
//! - `pub const vpi_negative_tests`
//! - `pub const contract_tests`

/// Every module, `pub` so the `refAllDecls` test below reaches each one.
pub const modules = @import("unit/modules.zig");

/// The in-process fuzz targets, replayed with seeded inputs by zrunner's
/// `fuzz`; their own root for `zig build fuzz`.
pub const fuzz_targets = @import("fuzz.zig");

/// Every `contract.<name>` the backend emits must be a decl contract.zig has.
///
/// Codegen writes the reference as text into a device it never compiles, and
/// the engine never links contract.zig, so a renamed decl would otherwise
/// surface as a compile error inside a generated device on the host's side.
pub const contract_names = @import("unit/contract_names.zig");
pub const parser_tests = @import("unit/parser_tests.zig");
pub const kernel_tests = @import("unit/kernel_tests.zig");
pub const integer_tests = @import("unit/integer_tests.zig");
pub const proof_tests = @import("unit/proof_tests.zig");
pub const ssa_tests = @import("unit/ssa_tests.zig");
pub const prove_oom_tests = @import("unit/prove_oom_tests.zig");
pub const zigbuild_tests = @import("unit/zigbuild_tests.zig");
pub const lower_tests = @import("unit/lower_tests.zig");
pub const rtlil_tests = @import("unit/rtlil_tests.zig");
pub const diag_tests = @import("unit/diag_tests.zig");
pub const preprocessor_tests = @import("unit/preprocessor_tests.zig");
pub const sim_digital_tests = @import("unit/sim_digital_tests.zig");
pub const codegen_tests = @import("unit/codegen_tests.zig");
pub const verilog_tests = @import("unit/verilog_tests.zig");
pub const digital_tests = @import("unit/digital_tests.zig");
pub const exe_tests = @import("unit/exe_tests.zig");
pub const vpi_tests = @import("unit/vpi_tests.zig");
pub const exhaustive_tests = @import("unit/exhaustive_tests.zig");
pub const oom_tests = @import("unit/oom_tests.zig");
pub const ulp_tests = @import("unit/ulp_tests.zig");

/// The call side of the VPI negative-input table (`tests/vpi_negative/`
/// holds the entry points a C application calls): what an application's
/// derivtf returns and what a device library hands back reach VerA as input,
/// and each refusal is a `vpi_chk_error` code and a 0 or empty answer, never
/// a crash (IEEE 1364-2005 §27.4; rw-vpi found all three unchecked by hand).
/// They are driven in process because no C application can reach the
/// library side: VerA builds and loads the device itself.
pub const vpi_negative_tests = @import("unit/vpi_negative_tests.zig");

/// `contract`'s public functions, as a host calls them; a test of a
/// contract file's private declarations stays beside that file.
pub const contract_tests = @import("unit/contract_tests.zig");

test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(modules);
}
