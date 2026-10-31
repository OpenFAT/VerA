//! A change of a value the standing monitor or an `$fmonitor` watches in, its line at the end of the time step out (§17.1.3, §17.2.2): installation, the per-step check, and `$monitoron`.
//! Cites: IEEE 1364-2005 §17.1.3, §17.2.2.
//!
//! Contents:
//! - `pub const Monitoring = struct`
//! - `pub fn monitorPrint(self: *Run, a: std.mem.Allocator) Error!void`
//! - `pub fn monitorDue(self: *Run, a: std.mem.Allocator) Error!bool`
//! - `pub fn install(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: Show, pc: u32) Error!void`
//! - `pub fn cancelFile(self: *Run, d: i64) void`
//! - `pub fn comparedOperand(self: *Run, e: Ast.ExprId) bool`
//! - `pub fn monitorChanged(self: *Run, slot: u32) Error!void`
//! - `pub fn fmonitorPrint(self: *Run, a: std.mem.Allocator) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const compile = @import("compile.zig");
const waiters = @import("waiters.zig");
const evaluate = @import("evaluate.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const Standing = @import("root.zig").Standing;
const run = @import("root.zig").run;
const expectRun = @import("root.zig").expectRun;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const Signal = @import("net.zig").Signal;
const netPull = @import("net.zig").netPull;
/// §9.4.3 Table 9-23's C conversion, the one the analog devices run.
const str_k = @import("kernels").str_kernels;
const zCReal = str_k.zCReal;
const system = @import("system.zig");
const fmt = @import("kernels").fmt;
const Radix = fmt.Radix;
/// §17.3.2 `$timeformat`'s state; the type is `fmt`'s so `rt` shares it.
const TimeFormat = fmt.TimeFormat;
const display = @import("display.zig");
const Show = display.Show;

/// §17.1.3 the one standing monitor and §17.2.2 the `$fmonitor` tasks of a
/// run, with what each report compares against.
pub const Monitoring = struct {
    /// The standing monitor. A second `$monitor` replaces it; there is no stack.
    standing: ?Standing = null,
    /// "any number of $fmonitor tasks can be set up to be simultaneously
    /// active", each until an `$fclose` of its descriptor.
    files: std.ArrayList(Standing) = .empty,
    /// `monitorChanged` is evaluating a monitor's arguments, so a store that
    /// evaluation makes asks nothing again.
    evaluating: bool = false,
    on: bool = true,
    /// One `.monitor` event per timestep however many values moved.
    pending: bool = false,
    /// VAMS §7.3.6.3: the analog probes in the standing monitor's arguments,
    /// operands no slot holds. With any, the monitor is checked at every time
    /// step (`runUntil`), after the step's region-3b solve (§8.5.1 row 4), and
    /// at every analog solution at a tick no digital event reached
    /// (`analogPoint`), and reports when a probe's value moved (`monitorDue`).
    probes: []const Ast.ExprId = &.{},
    /// A watched slot changed since the monitor last reported, so the report
    /// is due without a comparison. The first report is due too.
    slot_hit: bool = false,
    /// Per `probes` entry, the value it read at the last report.
    last: []f64 = &.{},
    /// The slots the standing monitor's arguments read: §17.1.3's "variable
    /// or an expression in the argument list". Clock queries read no slot,
    /// which is the clause's `$time`/`$stime`/`$realtime` exception.
    slots: std.ArrayList(u32) = .empty,
};

/// Prints the standing monitor's argument list, if there is one and it is
/// on. The caller decides whether to print (`monitorDue` at the time step's
/// `.monitor` event, or `$monitoron` ran), never by comparing text.
pub fn monitorPrint(self: *Run, a: std.mem.Allocator) Error!void {
    const m = self.monitoring.standing orelse return;
    // A change seen while monitoring was on still reports at the end of its
    // step, after a `$monitoroff` there, as iverilog's does (monitor4):
    // §17.1.3 says only that $monitoroff "disables monitoring".
    if (!self.monitoring.on and !self.monitoring.slot_hit) return;
    // §17.1.3 the monitor renders in the instance that installed it; the
    // `.monitor` region runs outside any process's dispatch.
    self.scope = m.scope;
    self.pc = m.pc;
    try display.display(self, m.args, a, m.show);
    // What each probe read at this report, the base the next time step
    // compares against (`monitorDue`).
    for (self.monitoring.probes, self.monitoring.last) |e, *last| last.* = try evaluate.evalReal(self, a, e);
    self.monitoring.slot_hit = false;
}

/// Whether the `.monitor` event of this time step reports (§17.1.3: "each
/// time a variable or an expression in the argument list changes value"). A
/// watched slot's change says so already (`monitor_slot_hit`); a VAMS
/// §7.3.6.3 probe is an operand no slot holds, so each one is compared with
/// its value at the last report, a change being VD-032's `!=`. An argument
/// is not compared whole: `$time`, `$stime` and `$realtime` are the clause's
/// exceptions inside an expression too, so time passing alone reports
/// nothing (docs/specification/Vague_Decisions.md VD-111).
pub fn monitorDue(self: *Run, a: std.mem.Allocator) Error!bool {
    const m = self.monitoring.standing orelse return false;
    if (self.monitoring.slot_hit) return true;
    if (self.monitoring.probes.len == 0 or !self.monitoring.on) return false;
    self.scope = m.scope;
    self.pc = m.pc;
    for (self.monitoring.probes, self.monitoring.last) |e, last| {
        if ((try evaluate.evalReal(self, a, e)) != last) return true;
    }
    return false;
}

/// §17.1.3 `$monitor` (`show.file` false) or §17.2.2 `$fmonitor` at `pc`,
/// in the current scope: a `$monitor` replaces the standing one, an
/// `$fmonitor` joins the others. Its first line is at the end of this time
/// step like every other, so it shows settled values.
pub fn install(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: Show, pc: u32) Error!void {
    watchAll(self, false);
    defer watchAll(self, true);
    var m: Standing = .{ .args = args, .show = show, .scope = self.scope, .pc = pc, .hit = true };
    m.values = try self.arena.alloc(?[]u64, args.len);
    var loose: std.ArrayList(u32) = .empty;
    var probes_ignored: std.ArrayList(Ast.ExprId) = .empty;
    for (args, m.values, 0..) |e, *v, k| {
        v.* = null;
        if (k < @intFromBool(show.file) or e == .none or self.file.exprs.tag(e) == .str_literal) continue;
        // A clock query or a call can move with no slot changing (VD-111):
        // such an argument is not compared, and any change of a slot it
        // reads reports.
        if (!comparable(self, e)) {
            try compile.sensitivityProbes(self, e, &loose, &probes_ignored);
            continue;
        }
        v.* = try self.arena.dupe(u64, try current(self, a, e));
    }
    m.loose = loose.items;
    if (show.file) {
        m.fd = ((try evaluate.eval(self, a, args[0], 0)).asInt() orelse return) & 0xffff_ffff;
        var slots: std.ArrayList(u32) = .empty;
        for (args[1..]) |e| if (e != .none and self.file.exprs.tag(e) != .str_literal)
            try compile.sensitivity(self, e, &slots);
        m.slots = slots.items;
        try self.monitoring.files.append(self.arena, m);
        return requestTick(self);
    }
    self.monitoring.slots.clearRetainingCapacity();
    var probes: std.ArrayList(Ast.ExprId) = .empty;
    for (args) |e| if (e != .none and self.file.exprs.tag(e) != .str_literal)
        try compile.sensitivityProbes(self, e, &self.monitoring.slots, &probes);
    self.monitoring.standing = m;
    // VAMS §8.5.1 row 4 after 3b: a probe of the analog solution is an
    // operand no slot holds, so it is compared at every time step and
    // analog solution (`monitorDue`). The first report is due.
    self.monitoring.probes = probes.items;
    self.monitoring.last = try self.arena.alloc(f64, probes.items.len);
    @memset(self.monitoring.last, 0);
    self.monitoring.slot_hit = true;
    try waiters.requestMonitor(self);
}

/// §17.2.7: "Active $fmonitor and/or $fstrobe operations on a file
/// descriptor or multichannel descriptor are implicitly cancelled by an
/// $fclose operation". The `$fmonitor`s writing to `d` stop: one on a
/// multichannel descriptor any of whose channels `d` closes stops whole, as
/// iverilog's does (fmonitor2), since the clause does not split it.
pub fn cancelFile(self: *Run, d: i64) void {
    watchAll(self, false);
    defer watchAll(self, true);
    const mcd = d & (1 << 31) == 0;
    var k: usize = 0;
    while (k < self.monitoring.files.items.len) {
        const fd = self.monitoring.files.items[k].fd;
        const hit = if (mcd and fd & (1 << 31) == 0) fd & d != 0 else fd == d;
        if (hit) _ = self.monitoring.files.orderedRemove(k) else k += 1;
    }
}

/// Whether `$monitor` argument `e` reports on a change of its own value
/// that a change of a slot it reads need not be (`bs[1]` under `bs`): an
/// expression `install` compares. A whole variable, a constant and an
/// argument that is not compared report on any change of their slots.
pub fn comparedOperand(self: *Run, e: Ast.ExprId) bool {
    if (e == .none) return false;
    return switch (self.file.exprs.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .real_literal, .ident, .hier_ident => false,
        else => comparable(self, e), // else: an expression of operands
    };
}

/// `waiters.store`: a slot some standing monitor reads changed. §17.1.3 "each
/// time a variable or an expression in the argument list changes value": a
/// monitor whose arguments' values moved reports at the end of the time
/// step; one whose slot changed under an unchanged argument (`bs` under
/// `bs[1]`) does not. A transient change still reports.
pub fn monitorChanged(self: *Run, slot: u32) Error!void {
    assert(slot < self.values.len);
    if (self.monitoring.evaluating) return;
    self.monitoring.evaluating = true;
    defer self.monitoring.evaluating = false;
    const a = self.scratch.allocator();
    if (self.monitoring.standing) |*m| if (std.mem.findScalar(u32, self.monitoring.slots.items, slot) != null and try moved(self, m, a, slot) and self.monitoring.on) {
        self.monitoring.slot_hit = true;
        try waiters.requestMonitor(self);
    };
    for (self.monitoring.files.items) |*m| if (std.mem.findScalar(u32, m.slots, slot) != null and try moved(self, m, a, slot)) {
        m.hit = true;
        try requestTick(self);
    };
}

/// The `.monitor_tick`'s `$fmonitor` lines: each one whose arguments moved.
pub fn fmonitorPrint(self: *Run, a: std.mem.Allocator) Error!void {
    for (self.monitoring.files.items) |*m| if (m.hit) {
        m.hit = false;
        self.scope = m.scope;
        self.pc = m.pc;
        try system.fdisplayTo(self, a, m.fd, m.args, m.show);
    };
}

// ---- private ----

/// Marks (`on`) or unmarks every slot a standing monitor reads as a
/// `.monitor` watch (`waiters.store` -> `monitorChanged`).
fn watchAll(self: *Run, on: bool) void {
    for (self.monitoring.slots.items) |at| self.waits.watch[at].setPresent(.monitor, on);
    for (self.monitoring.files.items) |m| for (m.slots) |at| self.waits.watch[at].setPresent(.monitor, on);
}

/// Whether argument `e`'s value can move only when a slot it reads does:
/// no clock query, call or analog probe anywhere in it.
fn comparable(self: *Run, e: Ast.ExprId) bool {
    assert(e != .none);
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .real_literal, .ident, .hier_ident => true,
        .index => comparable(self, ex.lhs(e)) and comparable(self, ex.rhs(e)),
        .unary, .binary, .multi_concat, .ternary, .concat, .range, .indexed_range => {
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (c != .none and !comparable(self, c)) return false;
            return true;
        },
        else => false, // else: a system or user call, an analog probe
    };
}

/// Argument `e`'s value now, as the planes compared between evaluations; a
/// real as its bits (VD-032's change is `!=`, which -0.0 over +0.0 is not,
/// so a real compares by value).
fn current(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error![]u64 {
    assert(e != .none);
    if (compile.typeOf(self, e).real) {
        const r = try evaluate.evalReal(self, a, e);
        const out = try a.alloc(u64, 1);
        out[0] = @bitCast(if (r == 0) 0 else r);
        return out;
    }
    return (try evaluate.eval(self, a, e, 0)).planes;
}

/// Re-evaluates `m`'s compared arguments after `slot` changed: true when any
/// of them moved since its last evaluation (each then keeps its new value),
/// or when an argument that is not compared reads `slot` (`install`).
fn moved(self: *Run, m: *Standing, a: std.mem.Allocator, slot: u32) Error!bool {
    assert(slot < self.values.len);
    if (std.mem.findScalar(u32, m.loose, slot) != null) return true;
    const saved_scope = self.scope;
    const saved_pc = self.pc;
    defer {
        self.scope = saved_scope;
        self.pc = saved_pc;
    }
    self.scope = m.scope;
    self.pc = m.pc;
    var any = false;
    for (m.args, m.values) |e, last| {
        const old = last orelse continue;
        const now = try current(self, a, e);
        if (std.mem.eql(u64, old, now)) continue;
        any = true;
        @memcpy(old, now);
    }
    return any;
}

/// The time step's one `.monitor_tick`, which `$fmonitor` needs whether or
/// not a `$monitor` stands.
fn requestTick(self: *Run) Error!void {
    if (self.monitoring.pending) return;
    self.monitoring.pending = true;
    try @import("exec.zig").enqueueMonitor(self, .monitor_tick);
}

test "§17.1.3 monitor: clock queries do not trigger, a change and change back does" {
    // t1: only `u` (unwatched) changes and $time advances: no line. t2: a
    // goes 1 then back to 0 via #0: it "changes value", so one line with
    // the settled 0. t3: a = 1 prints with the current time. $monitoron at
    // t4 prints although nothing changed and monitoring was already on.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg a, u;
        \\initial begin
        \\  a = 0; u = 0;
        \\  $monitor("a=%b t=%0d", a, $time);
        \\  a <= 0;
        \\  #1 u = 1;
        \\  #1 a = 1;
        \\  #0 a = 0;
        \\  #1 a = 1;
        \\  #1 $monitoron;
        \\  #1 $finish(0);
        \\end
        \\endmodule
    , "a=0 t=0\na=0 t=2\na=1 t=3\na=1 t=4\n");
}

test "§17.1.3 monitor: a bit-select argument reports only when that bit changes" {
    // bs changes at t1..t4; bs[1] only at t2, so two lines in all.
    try expectRun(
        \\module m;
        \\reg [3:0] bs;
        \\integer i;
        \\initial begin
        \\  bs = 0;
        \\  $monitor("%0d %b", $time, bs[1]);
        \\  for (i = 0; i < 4; i = i + 1) #1 bs[i] = 1;
        \\  #1 $finish(0);
        \\end
        \\endmodule
    , "0 0\n2 1\n");
}

test "§17.1.3 a change before $monitoroff in its step still reports; a $finish step drains first" {
    // Oracle: iverilog -g2005 (ivtest monitor4) for b's change at 1, which
    // precedes the $monitoroff, its change at 2, which does not report, and
    // the change in the $finish step at 3, reported at the step's end. The
    // `b=2 t=3` line is §17.1.3's own: "$monitoron shall produce a display
    // immediately" (iverilog defers it to the end of the step).
    try expectRun(
        \\module m;
        \\  integer b;
        \\  initial begin
        \\    b = 0; $monitor("b=%0d t=%0d", b, $time);
        \\    #1 b = 1; $monitoroff;
        \\    #1 b = 2;
        \\    #1 $monitoron; b = 3; $finish(0);
        \\  end
        \\endmodule
    , "b=0 t=0\nb=1 t=1\nb=2 t=3\nb=3 t=3\n");
}
