//! The program root's opt-in in, two build-time facts out: whether the
//! contract's conformance checks run (`validating`), and the pieces a split
//! `--emit-so` build compiles a device in (`DevicePart`).
//! Cites: none (VerA's own build protocol).
//!
//! Contents:
//! - `pub const validating: bool`
//! - `pub const DevicePart = enum { setup, state, eval }`

const std = @import("std");

/// Whether this program asked for the contract's conformance checks: its root
/// module declares `pub const vera_validate_contract = true`. Off by default:
/// VerA's devices follow the contract by construction, and the checks exist
/// for developing VerA. `zig build test` turns them on (`tools/zrunner.zig`),
/// the fixture suite in every testbench, `vera --validate-contract` in one,
/// and `vera --check` always. Gates `validate`, `validateHost`'s obligations,
/// `checkFamily` and a Debug device's `su_ok` assert; `validateHost`'s
/// version check runs regardless. Measured (2026-10-01, one cold build, -j1): the
/// checks are 0.4-1.8% of a device build's instructions (mos1 2.454 -> 2.417
/// Gi, bsim4va eval 8.100 -> 7.958, psp103 eval 14.183 -> 14.125).
pub const validating: bool = blk: {
    const root = @import("root");
    break :blk @hasDecl(root, "vera_validate_contract") and root.vera_validate_contract;
};

/// The pieces `vera --emit-so` builds a large device in (`orchestrator.Part`):
/// one compiler process and object each, in parallel, linked into one
/// library. A `dyn` host may declare
/// `pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: DevicePart) void`
/// beside `exportDevice`; the split build then calls it once per part, each
/// in its own object, so it must export every symbol from exactly one part
/// (a call into another part goes through `@extern`). `.setup`: `setup`,
/// `derive`, `initState`, `stateCtl`, `pendingBreakpoint`; `.state`:
/// `updateState`; `.eval`: `eval`, `evalQ`, `q`. A host without it gets
/// `exportDevice` in the `.setup` object, and the others export nothing.
/// A large `setup` comes as chunks (`D.setup_chunks`, `n` of them, which
/// `setup` calls in order); a host that also declares
/// `pub fn SetupValue(comptime D: type) type`, the `V` it passes `D.setup`,
/// gets each chunk compiled in an object of its own, in parallel. Calling
/// `setup` with another `V` then fails to link. Without it the chunks stay
/// in the object that calls `setup`.
pub const DevicePart = enum { setup, state, eval };

comptime {
    // `orchestrator.Part` mirrors these three tags in this order.
    std.debug.assert(@typeInfo(DevicePart).@"enum".field_names.len == 3);
    std.debug.assert(@backingInt(DevicePart.setup) == 0);
}
