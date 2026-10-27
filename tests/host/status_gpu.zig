//! §9.7.3 the status channel on a GPU target: tests/conformance/tests/verilog-a/ch09_system_tasks/status_ops.va's `eval`,
//! `evalQ` and `updateState` as one kernel, so the latch and the zero plane
//! compile for NVPTX and AMDGCN (`zig build test` builds this for both; no
//! GPU runs it). The host code above `status_host.zig` checks the behaviour.

const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &.{ 0, 1 }, .{});

fn run(x: *const [n_u]f64, m: *const D.Model, inst: *D.Instance, st: *D.State, out: *[n_u]f64) void {
    const sim: contract.SimState = .{ .t = 1e-9, .dt = 1e-9, .kind = .tran };
    const r = D.evalQ(S, x, m, inst, sim);
    inline for (r.res, 0..) |e, u| out[u] = e.v + e.ddxAt(0);
    _ = D.updateState(S, m, inst, x.*, st, sim);
    out[0] += @floatFromInt(inst.vera_status__);
    // `contract.gm`'s Table 4-15 functions reach log1p, whose std body
    // AMDGCN cannot lower (`gm.log1p`); compiling them here keeps it so.
    out[0] += contract.gm.asinh(x[0]) + contract.gm.acosh(x[0]) + contract.gm.atanh(x[0]) + contract.gm.log1p(x[0]);
}

export fn status_ops_kernel(x: *const [n_u]f64, m: *const D.Model, inst: *D.Instance, st: *D.State, out: *[n_u]f64) callconv(.kernel) void {
    run(x, m, inst, st, out);
}
