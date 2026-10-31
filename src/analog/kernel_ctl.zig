//! §9.17 analog kernel control: `$bound_step`, `$discontinuity` and VerA's
//! `$vera_reject_step` in, running minimums over SSA places out, each turned
//! into one synthetic `call` (or a `Lowered` value) the host reads after an
//! accepted step; and §9.7.3's halt after an `$error` in `analog initial`.
//!
//! Cites: §2.7, §3.3, §4.2.1.1, §9.7.3, §9.17, §9.17.1, §9.17.2.
//!
//! Contents:
//! - `pub fn lowerKernelCtl(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!bool`
//! - `pub fn finishKernelCtl(self: *Lower) Oom!void`
//! - `pub fn haltAfterInitError(self: *Lower) Oom!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const Ssa = @import("ssa.zig");
const lower_display = @import("display.zig");
const lower_format = @import("format.zig");
const Oom = Lower.Oom;
const Const = Lower.Const;

/// §9.17 analog kernel control. Handled here rather than as an ordinary void
/// call because both tasks write to the host, and an unread call would be
/// dropped. Returns true when `name` was one of them.
pub fn lowerKernelCtl(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!bool {
    assert(self.blockValid(self.cur));
    assert(name.len != 0);
    // §9.17.2 `$bound_step ( expression ) ;` — "the simulator shall ensure that
    // the next time step taken is no larger than the smallest $bound_step()
    // argument currently active", so the accumulation is a running minimum.
    if (std.mem.eql(u8, name, "$bound_step")) {
        if (args.len != 1 or args[0] == .none) {
            try self.err(tok, .E0802, "got {d}", .{args.len});
            return true;
        }
        // "The expression argument shall be non-negative" (§9.17.2); `abs`
        // would silently repair a model that violates it, so a provably
        // negative constant is a diagnostic and anything else is taken as
        // written.
        if (lower_constfold.constEval(self, args[0])) |c| {
            if (c.asReal() < 0.0) {
                try self.err(self.file.exprs.mainTok(args[0]), .E0803, "got {d}", .{c.asReal()});
                return true;
            }
        }
        const p = try kernelCtlPlace(self, &self.systask_state.bound_step_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.toReal(try lower_expr.lowerExpr(self, args[0]));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }

    // VerA's `$vera_reject_step(t_retry)`: ask the host to reject the step
    // it is accepting and retry it ending at `t_retry`. The request is read
    // off the accepted solution by `updateState`, so the accumulation is a
    // running minimum, as `$bound_step`'s is: the earliest retry wins.
    if (std.mem.eql(u8, name, "$vera_reject_step")) {
        // An `analog initial` block runs once per analysis and an analog
        // function per call: neither is a step the host accepts.
        if (self.restrict) |ctx| {
            try self.err(tok, .E0533, "in {s}", .{ctx});
            return true;
        }
        const p = try kernelCtlPlace(self, &self.systask_state.reject_step_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.toReal(try lower_expr.lowerExpr(self, args[0]));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }

    // §9.17.1 `$discontinuity [ ( constant_expression ) ] ;` — the argument is
    // the DEGREE, "a discontinuity in the i'th derivative", so a smaller degree
    // is the more severe announcement and the running minimum is what the host
    // needs. `$discontinuity` with no argument is degree 0.
    if (std.mem.eql(u8, name, "$discontinuity")) {
        const real_args = for (args) |a| {
            if (a != .none) break args;
        } else args[0..0];
        if (real_args.len > 1) {
            try self.err(tok, .E0804, "got {d}", .{real_args.len});
            return true;
        }
        var degree: i64 = 0;
        if (real_args.len == 1) {
            const c = lower_constfold.constEval(self, real_args[0]) orelse {
                try self.err(self.file.exprs.mainTok(real_args[0]), .E0805, "", .{});
                return true;
            };
            // §9.17.1 "i must be a non-negative integer", and §3.3 "A string
            // cannot be assigned to an integral type": a `string` PARAMETER has
            // no integer to be. A string LITERAL does: §3.3 lets it be
            // assigned to an integral type, as its packed bytes (§2.7), which
            // `Const.asIntExact`'s `.str => 0` is not.
            if (c == .str) {
                if (self.file.exprs.tag(real_args[0]) != .str_literal) {
                    try self.err(self.file.exprs.mainTok(real_args[0]), .E0820, "got a `string` value, \"{s}\", which is not an integer", .{c.str});
                    return true;
                }
                degree = Lower.strToInt(c.str, 32);
            } else
            // Same hole as the subscript path: §4.2.1.1 gives an infinity no
            // nearest lower_format.integer, so there is no degree here to compare against
            // -1. E0820 is the clause's own verdict for a degree it cannot
            // accept, and reporting it keeps the rest of the file compiling.
            degree = c.asIntExact() orelse {
                try self.err(tok, .E0820, "got {e}", .{c.asReal()});
                return true;
            };
        }
        if (degree == -1) {
            if (self.systask_state.reject_iteration_place == null) {
                const p = self.builder.newPlace();
                try self.builder.writeVariable(p, .entry, .zero);
                self.systask_state.reject_iteration_place = p;
                self.out.uses.insert(.reject_iteration);
            }
            try self.builder.writeVariable(self.systask_state.reject_iteration_place.?, self.cur, .one);
            return true;
        }
        if (degree < -1) {
            try self.err(tok, .E0820, "got {d}", .{degree});
            return true;
        }
        const p = try kernelCtlPlace(self, &self.systask_state.disc_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.mir.addFloatConst(self.arena, @floatFromInt(degree));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }
    return false;
}

/// §9.17.1/§9.17.2. Turns each accumulated kernel-control place into exactly one
/// synthetic `call`, whose single argument is the value the host must read.
/// `names.enumerateUnits` gives that call a unit; `codegen` (`state.zig` `emitStateMachine`)
/// evaluates the unit once per accepted step and stores it into `Instance`.
pub fn finishKernelCtl(self: *Lower) Oom!void {
    assert(self.blockValid(self.cur));
    assert(self.module != null); // once, after the analog blocks
    if (self.systask_state.reject_iteration_place) |p| self.out.reject_iteration = try self.builder.readVariable(p, self.cur);
    if (self.systask_state.reject_step_place) |p| self.out.reject_step = try self.builder.readVariable(p, self.cur);
    if (self.systask_state.status_places) |ps| {
        self.out.status = try self.builder.readVariable(ps[0], self.cur);
        for (&self.out.status_args, ps[1..]) |*a, p| a.* = try self.builder.readVariable(p, self.cur);
    }
    if (self.systask_state.bound_step_place) |p| {
        const v = try self.builder.readVariable(p, self.cur);
        _ = try self.call("$bound_step", &.{v});
    }
    if (self.systask_state.disc_place) |p| {
        const v = try self.builder.readVariable(p, self.cur);
        _ = try self.call("$discontinuity", &.{v});
    }
}

/// §9.7.3: "If $error is executed within an analog initial block, then the
/// message is issued and the initialization continues. However, the
/// simulation shall not proceed past initialization." Called after an
/// `analog initial` block: when one of its `$error` calls ran, a synthetic
/// `$fatal(1, …)` ends the run there, after the block's own prints and before
/// any of the analog block's. Status 1: a run an error ended (`$fatal`'s floor).
pub fn haltAfterInitError(self: *Lower) Oom!void {
    assert(self.blockValid(self.cur));
    assert(self.in_analog_initial == false); // after the block, not in it
    const ie = self.systask_state.init_error orelse return;
    const hit = try self.builder.readVariable(ie.place, self.cur);
    const then_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    try self.branchTo(hit, then_b, join, false);
    self.cur = then_b;
    self.cond_depth += 1;
    defer self.cond_depth -= 1;
    const v = try self.call("$fatal", &.{
        try self.mir.addIntConst(self.arena, 1),
        try self.mir.addStrConst(self.arena, "an $error in analog initial: the simulation does not proceed past initialization"),
    });
    try lower_display.chainCondDisplay(self, v);
    try self.out.displays.append(self.arena, .{ .val = v, .name = "$fatal", .tok = ie.tok, .conditional = true });
    try self.gotoBlock(join);
    try self.builder.sealBlock(join);
    self.cur = join;
}

// ---- private ----

/// Returns the kernel-control place in `slot`, creating it on first use seeded
/// to +inf in the entry block. +inf is both `fmin`'s identity and "the model
/// asked for nothing", so no "was it called" flag has to survive the CFG.
fn kernelCtlPlace(self: *Lower, slot: *?Ssa.Place) Oom!Ssa.Place {
    assert(self.blockValid(self.cur));
    assert(self.mir.blockCount() != 0); // the entry block the seed goes in
    if (slot.*) |p| return p;
    const p = self.builder.newPlace();
    try self.builder.writeVariable(p, .entry, .f_inf);
    slot.* = p;
    return p;
}

test "lower: §9.17.2 $bound_step accumulates through the CFG, not unconditionally" {
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module bs(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $bound_step(1n);
        \\    if (V(p,n) > 0.0) $bound_step(1p);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());

    // Exactly ONE synthetic call, and its argument is a phi: the guarded
    // `$bound_step(1p)` must NOT bound the step on the arm that never ran.
    var found: ?Mir.Value = null;
    for (0..h.mir.blockCount()) |bi| {
        const b: Mir.Block = @fromBackingInt(@intCast(bi));
        var it = h.mir.blockInsts(b);
        while (it.next()) |inst| {
            if (h.mir.instOp(inst) != .call) continue;
            if (!std.mem.eql(u8, h.mir.instData(inst).call.name, "$bound_step")) continue;
            try std.testing.expect(found == null);
            found = h.mir.instData(inst).call.args[0];
        }
    }
    const arg = h.mir.resolveAlias(found orelse return error.NoBoundStepCall);
    try std.testing.expectEqual(Mir.Opcode.phi, h.mir.instOp(h.mir.valueDef(arg).inst_result));
    // …and nothing was emitted for §9.17.1, which this module never calls.
    try std.testing.expect(h.low.systask_state.disc_place == null);
}

test "lower: §9.17.1 $discontinuity separates iteration rejection from degree" {
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module d(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $discontinuity(-1);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());
    try std.testing.expectEqual(Mir.Value.one, h.low.out.reject_iteration);
    // Iteration rejection must not become a timestep discontinuity.
    try std.testing.expect(h.low.systask_state.disc_place == null);
    try std.testing.expect(h.low.systask_state.bound_step_place == null);

    var h2: Lower.Harness = undefined;
    try h2.init(std.testing.allocator,
        \\module d2(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $discontinuity(2);
        \\    $discontinuity;
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    );
    defer h2.deinit();
    _ = try h2.low.lowerFile();
    try std.testing.expect(h2.bag.isEmpty());
    try std.testing.expect(h2.low.systask_state.disc_place != null);
}
