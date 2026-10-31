//! A delay expression or a driver's `delay3` in its scope in, the delay in ticks of the module's precision out (§9.7.1, A.2.2.3).
//! Cites: IEEE 1364-2005 §6.1.3, §7.14, §9.7.1, §19.8; A.2.2.3.
//!
//! Contents:
//! - `pub fn variableDelay(self: *Run, scratch: std.mem.Allocator, d: Ast.Delay3, tok: u32) Error!Delay`
//! - `pub fn delayOf(self: *Run, scratch: std.mem.Allocator, e: Ast.ExprId, tok: u32) Error!u64`

const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const compile = @import("compile.zig");
const deep = @import("base").deep_stack;
const display = @import("display.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const Handle = @import("../scheduler.zig").Handle;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const wordMask = @import("net.zig").wordMask;
const Show = display.Show;
const Overrides = @import("root.zig").Overrides;
const Frame = @import("root.zig").Frame;
const PcRange = @import("root.zig").PcRange;
const Delay = @import("net.zig").Delay;
const Tran = @import("net.zig").Tran;
const system = @import("system.zig");
const vcd = @import("vcd.zig");
const evcd = @import("evcd.zig");
const driver = @import("driver.zig");
const evaluate = @import("evaluate.zig");
const resolution = @import("resolution.zig");
const waiters = @import("waiters.zig");
const activations = @import("activations.zig");
const instructions = @import("instructions.zig");
const callSync = activations.callSync;
const callTimed = activations.callTimed;
const returnTimed = activations.returnTimed;
/// `evaluate.address`: the element an lvalue names right now.
const address = evaluate.address;
/// `waiters.store`: the one write path, which wakes what watches the slot.
const store = waiters.store;
/// `waiters.trigger`: §5.10.4 `-> e`.
const trigger = waiters.trigger;
/// `waiters.release`: §9.3 `deassign` or `release`.
const release = waiters.release;
/// `waiters.forceValue`: a VPI force of a constant.
const forceValue = waiters.forceValue;

/// A driver's `delay3` that reads a variable (`Run.driver_delays`), its
/// values now, defaulted as `Run.declaredDelay3` defaults a constant one.
pub fn variableDelay(self: *Run, scratch: std.mem.Allocator, d: Ast.Delay3, tok: u32) Error!Delay {
    assert(tok < self.starts.len);
    var out: Delay = .{ .present = true };
    out.rise = try delayOf(self, scratch, d.rise, tok);
    out.fall = if (d.fall != .none) try delayOf(self, scratch, d.fall, tok) else out.rise;
    out.off = if (d.off != .none) try delayOf(self, scratch, d.off, tok) else @min(out.rise, out.fall);
    return out;
}

/// The run-time counterpart of `checkDelay`, in the module's precision.
pub fn delayOf(self: *Run, scratch: std.mem.Allocator, e: Ast.ExprId, tok: u32) Error!u64 {
    assert(e != .none);
    assert(tok < self.starts.len);
    if (compile.typeOf(self, e).real) {
        return self.timeOf(self.scope).scale.realDelay(try evaluate.evalReal(self, scratch, e)) catch |err|
            return self.fail(tok, "digital delay cannot be represented: {t}", .{err});
    }
    const value = try evaluate.eval(self, scratch, e, 0);
    // §9.7.1 leaves an x/z delay undefined; zero is the reading that keeps
    // the process running rather than losing it.
    if (value.hasUnknown()) return 0;
    if (value.width > 64) return self.exprFail(e, "delay values wider than 64 bits are not implemented");
    const scale = self.timeOf(self.scope).scale;
    return (if (value.signed) scale.signedDelay(value.asInt().?) else scale.unsignedDelay(value.values()[0])) catch |err|
        return self.fail(tok, "digital delay cannot be represented: {t}", .{err});
}
