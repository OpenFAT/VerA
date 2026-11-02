//! §2.9 a `vera_timepoint` statement over a held history on a GPU target:
//! tests/conformance/tests/verilog-a/ch05_analog_behavior/vera_timepoint_held_history.va's `eval` and
//! `updateState` as one function (#82). NVPTX goes to PTX assembly, which
//! `tphist_host.zig` reads for the functions' `.local` stack depots; `zig
//! build test` builds this for NVPTX and AMDGCN, and no GPU runs it.

const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &.{ 0, 1 }, .{});

/// A plain export, not `callconv(.kernel)`: the NVPTX backend refuses the
/// LLVM alias a kernel export makes, and the assembly is what is checked.
export fn tphist_ops_kernel(x: *const [n_u]f64, m: *const D.Model, inst: *D.Instance, st: *D.State, out: *[n_u]f64) void {
    const sim: contract.SimState = .{ .t = 1e-9, .dt = 1e-9, .kind = .tran };
    const r = D.eval(S, x, m, inst, sim);
    inline for (r, 0..) |e, u| out[u] = e.v + e.ddxAt(0);
    _ = D.updateState(S, m, inst, x.*, st, sim);
}
