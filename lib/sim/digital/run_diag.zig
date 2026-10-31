//! A refusal during elaboration or the run in, an E-coded diagnostic in the run's bag out, and the error that ends the run.
//! Cites: none (the house diagnostic format, lib/diag).
//!
//! Contents:
//! - `pub fn fail(self: *Run, tok: u32, comptime fmt: []const u8, args: anytype) Error`
//! - `pub fn stage(self: *const Run) diag.Stage`
//! - `pub fn failWith(self: *Run, code: diag.Code, tok: u32, comptime fmt: []const u8, args: anytype) Error`
//! - `pub fn deepFail(self: *Run, tok: u32) Error`
//! - `pub fn exprFail(self: *Run, e: Ast.ExprId, comptime msg: []const u8) Error`

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const Scheduler = @import("../scheduler.zig").Scheduler;
/// Scheduler ticks. `Time` below is the timescale module, not this.
const Tick = @import("../scheduler.zig").Time;
const Time = @import("../time.zig");
const deep = @import("base").deep_stack;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const display = @import("display.zig");
/// Public for the VPI (src/vpi/value.zig), which writes a value the way a
/// process does (`waiters.store` now, `exec.enqueue` of a `.write` later), so a
/// §12.30 put wakes waiters and value-change watchers like any other write.
const exec = @import("exec.zig");
/// §17 system tasks.
const system = @import("system.zig");
const driver = @import("driver.zig");
const binding = @import("bind.zig");
const elab = @import("elab.zig");
const waiters = @import("waiters.zig");
const resolution = @import("resolution.zig");
const tchk = @import("tchk.zig");
const vpi = @import("vpi.zig");
const Type = compile.Type;
const Instruction = compile.Instruction;
const Row = exec.Row;
const Delay = @import("net.zig").Delay;
const Net = @import("net.zig").Net;
const NetCold = @import("net.zig").NetCold;
const no_cold = @import("net.zig").no_cold;
const Tran = @import("net.zig").Tran;
const Signal = @import("net.zig").Signal;
const Inertial = @import("net.zig").Inertial;
const no_transition = @import("net.zig").no_transition;
const Driver = @import("net.zig").Driver;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const Show = display.Show;
const TimeFormat = display.TimeFormat;

// ---- the public surface -----------------------------------------------------
const root = @import("root.zig");
const Run = root.Run;
const Error = root.Error;

/// The descriptor table a `Run` with no `file_io` opens files through.
const own_files = system.own;

/// Adds an E1100 diagnostic at token `tok` (clamped to the last token)
/// and returns `error.DigitalFailed` for the caller to propagate.
pub fn fail(self: *Run, tok: u32, comptime fmt: []const u8, args: anytype) Error {
    return self.failWith(.E1100, tok, fmt, args);
}

/// The stage a diagnostic raised now belongs to (`diag_stage`, #72).
pub fn stage(self: *const Run) diag.Stage {
    return self.diag_stage;
}

/// `fail` under a rule's own code, for a refusal the analog side reports.
pub fn failWith(self: *Run, code: diag.Code, tok: u32, comptime fmt: []const u8, args: anytype) Error {
    const start = self.starts[@min(tok, self.starts.len - 1)];
    self.bag.add(self.stage(), code, .{ .start = start, .end = start }, fmt, args) catch return error.OutOfMemory;
    return error.DigitalFailed;
}

/// A walk ran out of the stack `deep.runGuarded` reserved, at token `tok`.
pub fn deepFail(self: *Run, tok: u32) Error {
    return self.fail(tok, deep.message, .{deep.mib()});
}

/// `fail` at expression `e`'s main token, with a fixed message.
pub fn exprFail(self: *Run, e: Ast.ExprId, comptime msg: []const u8) Error {
    return self.fail(self.file.exprs.mainTok(e), "{s}", .{msg});
}
