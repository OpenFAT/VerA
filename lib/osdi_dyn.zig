//! The `--dyn` host `vera --emit-osdi` builds a device under: a VerA device
//! (lib/contract.zig) in, an OSDI 0.4 shared object out, so a simulator
//! that loads OpenVAF's `.osdi` files (ngspice `pre_osdi`) loads VerA's.
//! Exports `OSDI_VERSION_MAJOR`/`MINOR`, `OSDI_NUM_DESCRIPTORS` (1),
//! `OSDI_DESCRIPTORS`, `OSDI_DESCRIPTOR_SIZE` and the `osdi_log` slot the
//! simulator fills.
//!
//! Layout and semantics: OpenVAF-Reloaded `openvaf/osdi/header/osdi_0_4.h`
//! and `openvaf/osdi/src/load.rs` at fdf2522b70f4, and ngspice-45
//! `src/osdi/` (osdiregistry.c, osdisetup.c, osdiload.c, osdinoise.c,
//! osdiparam.c), which reads the 0.3 prefix of the descriptor and steps
//! through the array by `OSDI_DESCRIPTOR_SIZE`.
//!
//! The mapping onto the contract (each row's file in `osdi_dyn/`):
//!   nodes        every unknown of `U` (ports first, so the first
//!                `num_ports` are the terminals); a `.current`/`.flow`
//!                unknown is an OSDI flow node (ngspice `CKTmkCur`)
//!                (tables.zig, descriptor.zig)
//!   Jacobian     every (row, col) in `jac_pattern | q_pattern`, plus the
//!                `jac_const` and `ac_dyn_slots` entries (tables.zig)
//!   params       every scalar real, integer or string `Model` field that
//!                is a §3.4 parameter (no `__` in its name), listed TWICE:
//!                as an instance parameter and as a model parameter, since
//!                the contract does not say which a parameter is. An
//!                instance value overrides the card's. `$mfactor` is an
//!                instance parameter when `Instance` has `mfactor`
//!                (tables.zig, params.zig)
//!   eval         one `evalQ` (or `eval`) over the sparse reference family
//!                at the limited point: `seed` under ngspice's INIT_LIM,
//!                `limit` against the previous limited point under
//!                ENABLE_LIM. The residuals and Jacobian are kept in the
//!                instance; the `load_*` calls stamp them, and the RHS is
//!                linearized at the limited point (OpenVAF's lim_rhs)
//!                (eval.zig, load.zig)
//!   noise        one OSDI source per `noise_gens` row, its PSD
//!                coeff²·(white + flicker/f^ef + table) from `noisePsd` at the
//!                last evaluated point (load.zig)
//!   $mfactor     §6.3.6's scaling, which the device leaves to its host:
//!                KCL rows (and noise power) times `Instance.mfactor`
//!                (eval.zig, load.zig)
//!   temperature  each instance runs on its own `Model` row: the card,
//!                the instance's own parameters and `temperature__`, then
//!                `derive`, `checkShape`, `checkRange`, `setup`,
//!                `setupInstance` (setup.zig)
//!   collapse     a 0 V short (`D.collapse`) merges its two nodes, an OSDI
//!                collapsible pair, as OpenVAF's do, and its flow unknown
//!                collapses into ground (`collapse_applied`); a flow
//!                unknown whose branch a card switches off
//!                (`<flow>__retained` = 0 after `derive`) collapses into
//!                ground too. A short kept as a flow unknown is a
//!                zero-diagonal row, which SPARSE 1.3 pivots around at
//!                about 3,500x the factor time (psp103, 51-stage ring)
//!                (tables.zig, setup.zig)
//!   static request  `updateState`'s `request_reject_at` in a static solve
//!                ("iterate again", `contract.UpdateResult`) is
//!                EVAL_RET_FLAG_LIM: ngspice counts the iterate unconverged
//!                (eval.zig)
//!   breakpoints  `pendingBreakpoint` bounds the step after each point
//!                (`bound_step_offset`, with the device's own `$bound_step`):
//!                see `eval.boundStep`
//!
//! A `.v` design's contract device (`rt.Device`, `vera --emit-osdi design.v`)
//! takes the same mapping: its pins are the terminals, its bridge card
//! (vdd, vth, rout, ...) the parameters.
//!
//! Not mapped, each because OSDI 0.4 has no slot for it (docs/specification/Vague_Decisions.md
//! VD-102): opvars; correlated noise (`NoiseGen.source` shared by rows,
//! `PsdTerm.corr_with`): each row is an independent source, and `vera`
//! warns W1098; a transient step rejection a device asks for
//! (`request_reject_at`), which `vera` refuses (E1099) before building this;
//! the late-event query (`stateCtl(.query)`), so a crossing is never moved
//! back to a step that ends near it; a Verilog-A device's display records
//! (`say`); and acceptance itself: OSDI has no accept
//! callback, so `updateState` and `stateCtl(.commit)` run at every iterate
//! of a static solve and, in a transient, at the last point evaluated before
//! the simulator moves time forward (a rejected step retries at an earlier
//! time, so it is never committed). A `.v` device prints what a committed
//! step ran, to stderr, at those commits.
//!
//! Host-only: never imported by the device text, so the device stays
//! GPU-compilable.
//!
//! Clauses: LRM §3.4 (parameters, shape refusal), §3.4.2 (range refusal), §4.6.4 and §4.6.4.6 (noise),
//! §5.4.2 (a switched-off branch's flow collapses), §6.3.6 (`$mfactor`),
//! §9.15 (`$simparam`), §9.17.3 (limiting and seeds), §9.19
//! (`$port_connected`).
//!
//! Contents (the `dyn` hooks `zigbuild`'s shim calls by name):
//! - `pub const vera_validate_contract: bool`
//! - `pub fn exportDevice(comptime D: type, comptime name: []const u8) void`
//! - `pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: contract.DevicePart) void`
//! - `pub fn SetupValue(comptime D: type) type`

const std = @import("std");
const assert = std.debug.assert;
const contract = @import("contract");
const abi = @import("osdi_dyn/abi.zig");
const descriptor = @import("osdi_dyn/descriptor.zig");
const tables = @import("osdi_dyn/tables.zig");

/// Turns on the contract's conformance checks (`contract.validating`) for
/// every library built under this host: the build's root is `zigbuild`'s
/// shim, which forwards this flag from `dyn`.
pub const vera_validate_contract = true;

/// The `dyn` hook `vera --emit-so` calls: exports device `D` as the one
/// OSDI descriptor, named `name` (the module's name, which a `.model` card
/// names). Asserts at compile time that `name` is not empty.
pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    exportDescriptor(D, name, .whole);
}

/// The split build's hook (`contract.DevicePart`): `.setup` holds the
/// descriptor and the once-per-instance callbacks; `.eval` the ones the
/// simulator calls every iterate and `.state` `load_noise`, which the
/// descriptor reaches through hidden symbols, so the three compile in
/// parallel. `evalQ` is most of a large device's LLVM time and the noise PSD
/// a large share of the rest; nothing in `.setup` runs per iterate. Asserts
/// at compile time that `name` is not empty.
pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: contract.DevicePart) void {
    switch (part) {
        .setup => exportDescriptor(D, name, .split),
        .eval, .state => descriptor.Library(D, name, true).exportHot(part),
    }
}

/// The value family `D.setup` runs on here, so a split build compiles each
/// `D.setup_chunks` chunk in an object of its own (`contract.SetupValue`).
pub fn SetupValue(comptime D: type) type {
    return tables.Tables(D).Val;
}

// ---- private ----

/// Exports the descriptor of `D` and the library's version words and log
/// slot. Under `.split` the descriptor names the per-iterate callbacks by
/// symbol (`exportDevicePart`).
fn exportDescriptor(comptime D: type, comptime name: []const u8, comptime build: enum { whole, split }) void {
    comptime assert(name.len > 0);
    const Lib = descriptor.Library(D, name, build == .split);
    contract.validateHost(Lib, D);
    comptime assert(Lib.descriptors.len == abi.osdi_num_descriptors);
    @export(&abi.osdi_version_major, .{ .name = "OSDI_VERSION_MAJOR" });
    @export(&abi.osdi_version_minor, .{ .name = "OSDI_VERSION_MINOR" });
    @export(&abi.osdi_num_descriptors, .{ .name = "OSDI_NUM_DESCRIPTORS" });
    @export(&abi.osdi_descriptor_size, .{ .name = "OSDI_DESCRIPTOR_SIZE" });
    @export(&Lib.descriptors, .{ .name = "OSDI_DESCRIPTORS" });
    @export(&abi.osdi_log, .{ .name = "osdi_log" });
}

test {
    _ = abi;
    _ = descriptor;
    _ = @import("osdi_dyn/eval.zig");
    _ = @import("osdi_dyn/params.zig");
}
