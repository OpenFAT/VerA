//! §9.4 a device's `say` on a GPU target: tests/conformance/tests/verilog-a/ch09_system_tasks/say_ops.va's
//! `say` as one kernel recording into a host-lent buffer, so the output
//! channel compiles for NVPTX and AMDGCN (`zig build test` builds this for
//! both; no GPU runs it). tests/host/say_host.zig checks the behaviour.

const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &.{ 0, 1 }, .{});

export fn say_ops_kernel(x: *const [n_u]f64, m: *const D.Model, inst: contract.InstancePtr(D), buf: *[64]f64, len: *usize) callconv(.kernel) void {
    var out: contract.Say = .{ .buf = buf };
    D.say(S, x, m, inst, .{ .t = 1e-9, .dt = 1e-9, .kind = .tran }, &out);
    len.* = out.len;
}
