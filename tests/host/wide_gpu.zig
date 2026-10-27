//! IEEE 1364-2005 §5.4 wide `reg`s on a GPU target: tests/conformance/tests/verilog-ams/ch07_mixed_signal/wide_reg_held_across_evaluations.va's
//! `eval` and `updateState` as one function, so the native (`u72`) and the
//! limb (300-bit) kernels of `wide_kernels.zig` compile for NVPTX and AMDGCN
//! (`zig build test` builds this for both; no GPU runs it). NVPTX is taken to
//! PTX assembly, not only LLVM IR, so a library call LLVM's NVPTX backend
//! cannot lower (a wider-than-64-bit integer to float) fails the build.
//! `wide_host.zig` checks the behaviour on the host.

const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &.{0}, .{});

/// A plain export, not `callconv(.kernel)`: the NVPTX backend refuses the
/// LLVM alias a kernel export makes, and the assembly is what is checked.
export fn wide_ops_kernel(x: *const [n_u]f64, m: *const D.Model, inst: *D.Instance, st: *D.State, out: *[n_u]f64) void {
    const sim: contract.SimState = .{ .t = 1e-9, .dt = 1e-9, .kind = .tran };
    const r = D.eval(S, x, m, inst, sim);
    inline for (r, 0..) |e, u| out[u] = e.v + e.ddxAt(0);
    _ = D.updateState(S, m, inst, x.*, st, sim);
}
