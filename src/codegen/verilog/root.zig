//! Proven MIR in, a behavioural IEEE 1364-2005 module out (`vera
//! --emit-verilog`): the digital stand-in a gate-level or RTL simulation
//! uses for an analog macro, derived from the same `.va` the analog side is
//! verified against. Same module name, same port order.
//!
//! The abstraction. Every net the model drives (one with a contribution) is
//! one bit: high when its potential is above VDD/2. For every assignment of
//! the input pins and node bits, each pin or node at 0 or VDD, the analog
//! block is run once (`Interp.zig`, an interpreter over the MIR whose
//! arithmetic is `opcode.fold`, the compiler's own constant kernel). A node's
//! §5.6 KCL residual and §5.6.1.2 charge, read with its own potential at 0
//! and at VDD, give the potential it settles to and its time constant
//! (`settle.zig`); a §5.6 `V(n) <+ F` contribution sets the potential
//! directly. Each node becomes a truth table over the bits it depends on and
//! an inertial `assign #(rise, fall)` (`write.zig`).
//!
//! Pins (§2.9 attributes on a port declaration, `--digital-pins` wins):
//!   `(* vera_pin = "digital" *)`  logic: `input` if the model never drives it,
//!                                 else `output`
//!   `(* vera_pin = "analog" *)`   undriven `inout wire`; read as its logic level
//!   `(* vera_pin = "power" *)`    supply, VDD;  `(* vera_pin = "ground" *)`, 0 V
//! Undecorated: `vdd*`/`vcc*`/`vpwr`/`vpb`/`avdd`/`dvdd` are power,
//! `vss*`/`gnd*`/`vgnd`/`vnb`/`vee*`/`avss`/`dvss` ground, the rest analog.
//! `(* vera_delay = <seconds> *)` on a net's declaration replaces its derived
//! delay (both edges). On a port, both go on the direction declaration
//! (`inout`): a port's discipline declaration carries no attribute to it.
//! `--power-pins` moves the supply pins under `` `ifdef USE_POWER_PINS ``.
//!
//! Refused with a `Refusal`, never emitted half-right: §5.10 events and held
//! variables, `I()` probes and `ddt`/`idt` outside a contribution (their
//! unknowns are not nets), arrays, vector ports, `$abstime` and any call with
//! no static value, more than `vars_max` pins plus nodes, and a node whose
//! derived delay is not finite (a NaN or infinite charge or `td`) and has no
//! `vera_delay`.
//!
//! The spine, one stage per file: `ports.readAttrs` and `ports.classify`
//! (pin kinds), `drive.scan` (the variables), `sample.sample` (2^n runs),
//! `settle.settle` and `settle.liveStates` (the logic functions), then
//! `write.write` (the text).
//!
//! Contents:
//! - `pub const Refusal = union(enum)` (`refusal.zig`)
//! - `pub const vars_max: u8` (`drive.zig`)
//! - `pub const Options = struct`
//! - `pub const Error = error{ OutOfMemory, Refused, WriteFailed }`
//! - `pub fn emit(gpa: Allocator, mir: *const Mir, lw: *const Lowered, options: Options, out: *std.Io.Writer, refusal: ?*Refusal) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const ports = @import("ports.zig");
const drive = @import("drive.zig");
const sample = @import("sample.zig");
const settle = @import("settle.zig");
const write = @import("write.zig");
const Fixture = @import("prove").Fixture;
const Const = Lowered.Const;

/// Why `emit` refused; rendered by `{f}`.
pub const Refusal = @import("refusal.zig").Refusal;

/// The largest pins-plus-driven-nodes count the truth tables enumerate.
pub const vars_max = drive.vars_max;

/// What `emit` reads besides the model.
pub const Options = struct {
    /// `--digital-pins`: port names that are logic, whatever their attributes say.
    digital: []const []const u8 = &.{},
    /// `--power-pins`: declare the supply pins only under `ifdef USE_POWER_PINS`.
    power_pins: bool = false,
    /// The logic-high potential (V) a pin or node is evaluated at; > 0, finite.
    vdd: f64 = 1.8,
    /// The `.va` path, for the header comment.
    source: []const u8 = "",
};

/// Every way `emit` fails.
pub const Error = error{
    /// The scratch allocator failed; nothing was written to `out`.
    OutOfMemory,
    /// The model is outside the abstraction (the header lists what is);
    /// `refusal`, when given, holds why. Nothing was written to `out`.
    Refused,
    /// `out` failed; it holds a prefix of the module.
    WriteFailed,
};

// Test models: every one is a hand-built MIR (`Fixture`).

/// Pins `a`, `y`, `vdd`, `vss`, in that order, all ports.
const four = [_][]const u8{ "a", "y", "vdd", "vss" };
const logic: Options = .{ .digital = &.{ "a", "y" }, .source = "buf.va" };

/// Writes the behavioural module of `mir` and `lw` to `out`, or refuses it.
/// Every table lives in an arena over `gpa`, freed before return, so the
/// peak is about 24 bytes per (driven node, assignment): 2^vars_max · 20
/// rows at most. Runs the analog block 2^vars times. A `Refusal` borrows
/// from `mir`, `lw` and `options`. Asserts that `options.vdd` is positive
/// and finite.
pub fn emit(gpa: Allocator, mir: *const Mir, lw: *const Lowered, options: Options, out: *std.Io.Writer, refusal: ?*Refusal) Error!void {
    assert(options.vdd > 0);
    assert(std.math.isFinite(options.vdd));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var slot: Refusal = undefined;
    const p = plan(arena.allocator(), mir, lw, options, &slot) catch |e| switch (e) {
        error.Refused => {
            if (refusal) |r| r.* = slot;
            return error.Refused;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    assert(p.pins.len == lw.num_ports);
    try write.write(out, &p);
}

// ---- private ----

/// Every stage but the text, in order: everything that can refuse runs
/// before a byte is written.
fn plan(scratch: Allocator, mir: *const Mir, lw: *const Lowered, options: Options, slot: *Refusal) (Allocator.Error || error{Refused})!write.Plan {
    if (lw.held_vars.items.len != 0) return slot.raise(.{ .held_state = lw.held_vars.items[0].name });
    if (lw.vectors.count() != 0) return slot.raise(.vector_net);
    if (lw.num_ports == 0) return slot.raise(.{ .no_ports = mir.name });
    assert(lw.num_ports <= lw.nodes.len);
    const names = lw.nodes.items(.name);

    const attrs = try ports.readAttrs(scratch, lw, slot);
    const pins = try ports.classify(scratch, names[0..lw.num_ports], &attrs, options.digital, mir.name, slot);
    const d = try drive.scan(scratch, mir, lw, pins, slot);
    const samples = try sample.sample(scratch, mir, lw, pins, &d, options.vdd, slot);
    const settled = try settle.settle(scratch, &samples, &d, names, &attrs.delay, options.vdd, slot);
    const live = settle.liveStates(&settled, &d, pins);
    assert(settled.support.len == d.states().len);
    assert(live >> @intCast(d.states().len) == 0);
    if (write.firstSignal(pins, options.power_pins) == null) return slot.raise(.only_supplies);
    return .{
        .module = mir.name,
        .source = options.source,
        .vdd = options.vdd,
        .power_pins = options.power_pins,
        .names = names,
        .pins = pins,
        .drive = d,
        .settled = settled,
        .live = live,
    };
}

// Test support. // Each model is a hand-built MIR (`Fixture`), so the test states the residual
// it hands `emit`. The expected values follow from `settle.zig`'s formulas:
// F = -S(0)·VDD/(S(VDD)-S(0)), tau = ΔQ/ΔS, delay = tau·ln2 + td.

/// Appends the unconditional direct contribution `I(hi, lo) <+ resist +
/// ddt(react)`.
fn addFlow(f: *Fixture, hi: u32, lo: u32, resist: Mir.Value, react: Mir.Value) !void {
    try f.lowered.contributions.append(f.alloc(), .{ .access = .flow, .hi = hi, .lo = lo, .resist_val = resist, .react_val = react, .wrote_val = .f_one });
}

/// Builds `four` with `I(y, vss) <+ V(y) - V(a)`: y settles at V(a).
fn buffer(f: *Fixture) !void {
    try f.init(&four);
    f.lowered.num_ports = 4;
    const r = try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(1), try f.probe(0) });
    try addFlow(f, 1, 3, r, .f_zero);
}

/// Runs `emit`, printing the refusal if there is one.
fn emitOk(f: *Fixture, o: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(f.alloc());
    var why: Refusal = undefined;
    emit(std.testing.allocator, &f.mir, &f.lowered, o, &out.writer, &why) catch |e| {
        if (e == error.Refused) std.debug.print("refused: {f}\n", .{why});
        return e;
    };
    return out.written();
}

/// Fails unless `emit` refuses with a reason holding `part`, having written
/// nothing.
fn expectRefused(f: *Fixture, o: Options, part: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(f.alloc());
    var why: Refusal = undefined;
    try std.testing.expectError(error.Refused, emit(std.testing.allocator, &f.mir, &f.lowered, o, &out.writer, &why));
    try std.testing.expectEqual(0, out.written().len);
    const text = try f.alloc().print("{f}", .{why});
    if (std.mem.find(u8, text, part) == null) {
        std.debug.print("refused: {s}\nexpected: {s}\n", .{ text, part });
        return error.TestUnexpectedResult;
    }
}

fn emitUnderFailure(gpa: Allocator, rc: bool) !void {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&.{ "a", "y", "vdd", "vss", "n" });
    f.lowered.num_ports = 4;
    const m = f.alloc();
    // y follows n, n follows a; with `rc`, n is an RC so its delay is non-zero.
    try addFlow(&f, 1, 3, try f.mir.emit(m, .entry, .fsub, &.{ try f.probe(1), try f.probe(4) }), .f_zero);
    const q = if (rc) try f.mir.emit(m, .entry, .fmul, &.{ try f.mir.addFloatConst(m, 1e-12), try f.probe(4) }) else .f_zero;
    try addFlow(&f, 4, 3, try f.mir.emit(m, .entry, .fsub, &.{ try f.probe(4), try f.probe(0) }), q);
    // The text goes to an allocator that never fails: only the scratch
    // tables are under test, and a failing `out` is `WriteFailed`.
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emit(gpa, &f.mir, &f.lowered, logic, &out.writer, null);
}

test {
    _ = @import("refusal.zig");
    _ = ports;
    _ = drive;
    _ = @import("Interp.zig");
    _ = sample;
    _ = settle;
    _ = write;
}

test "emit: a buffer is a one-input truth table with no delay" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try buffer(&f);
    // S(V(y)) = V(y) - V(a), so F = V(a): y copies a. No charge and no
    // transition, so both delays are 0.
    try std.testing.expectEqualStrings(
        \\// GENERATED BY VerA --emit-verilog from buf.va - DO NOT EDIT.
        \\// Behavioural model of `mymod` for digital simulation: a driven net is high
        \\// above VDD/2 = 0.9 V; its switching delay is the model's own RC (tau*ln2) plus
        \\// any transition()/absdelay() td, or its (* vera_delay *). Analog pins are
        \\// undriven and read as their logic level.
        \\`timescale 1ns/1ps
        \\module mymod (
        \\      a
        \\    , y
        \\    , vdd
        \\    , vss
        \\);
        \\    input  wire a; // digital
        \\    output wire y; // digital
        \\    inout  wire vdd; // power
        \\    inout  wire vss; // ground
        \\
        \\    // y
        \\    parameter real vera_rise_y = 0.000000; // ns
        \\    parameter real vera_fall_y = 0.000000; // ns
        \\    reg vera_t_y;
        \\    always @* begin
        \\        case ({a})
        \\            1'b0: vera_t_y = 1'b0;
        \\            1'b1: vera_t_y = 1'b1;
        \\            default: vera_t_y = 1'bx;
        \\        endcase
        \\    end
        \\    assign #(vera_rise_y, vera_fall_y) y = vera_t_y;
        \\endmodule
        \\
    , try emitOk(&f, logic));
}

test "emit: an RC's delay is tau·ln2, a transition's is its td" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    const a = f.alloc();
    // I(y) <+ (V(y) - V(a))/1k + ddt(1p·V(y)): tau = R·C = 1 ns, so the 50 %
    // crossing is ln2 ns = 0.693147 ns on both edges.
    const vy = try f.probe(1);
    const diff = try f.mir.emit(a, .entry, .fsub, &.{ vy, try f.probe(0) });
    const i_r = try f.mir.emit(a, .entry, .fdiv, &.{ diff, try f.mir.addFloatConst(a, 1000) });
    const q = try f.mir.emit(a, .entry, .fmul, &.{ try f.mir.addFloatConst(a, 1e-12), vy });
    try addFlow(&f, 1, 3, i_r, q);
    const rc = try emitOk(&f, logic);
    try std.testing.expect(std.mem.find(u8, rc, "parameter real vera_rise_y = 0.693147; // ns\n") != null);
    try std.testing.expect(std.mem.find(u8, rc, "parameter real vera_fall_y = 0.693147; // ns\n") != null);

    // I(y) <+ V(y) - transition(V(a), 2n): no charge, td = 2 ns.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try g.init(&four);
    g.lowered.num_ports = 4;
    const b = g.alloc();
    const tr = try g.call("transition", &.{ try g.probe(0), try g.mir.addFloatConst(b, 2e-9) });
    try addFlow(&g, 1, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(1), tr }), .f_zero);
    const td = try emitOk(&g, logic);
    try std.testing.expect(std.mem.find(u8, td, "parameter real vera_rise_y = 2.000000; // ns\n") != null);
    try std.testing.expect(std.mem.find(u8, td, "parameter real vera_fall_y = 2.000000; // ns\n") != null);
}

test "emit: a non-finite charge or td is refused by node, not printed (#47)" {
    // The RC above with C = inf: Q(V(y) = 0) = inf·0 = NaN, so tau is NaN.
    // Before #47 `@max` dropped the NaN delay and printed 0 ns.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    const a = f.alloc();
    const vy = try f.probe(1);
    const diff = try f.mir.emit(a, .entry, .fsub, &.{ vy, try f.probe(0) });
    const i_r = try f.mir.emit(a, .entry, .fdiv, &.{ diff, try f.mir.addFloatConst(a, 1000) });
    const q = try f.mir.emit(a, .entry, .fmul, &.{ try f.mir.addFloatConst(a, std.math.inf(f64)), vy });
    try addFlow(&f, 1, 3, i_r, q);
    try expectRefused(&f, logic, "node `y`: its delay is not finite");

    // `transition(V(a), td)` with td = inf (printed `inf` before #47) and
    // td = NaN (dropped to 0 before #47).
    for ([_]f64{ std.math.inf(f64), std.math.nan(f64) }) |td| {
        var g: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer g.deinit();
        try g.init(&four);
        g.lowered.num_ports = 4;
        const b = g.alloc();
        const tr = try g.call("transition", &.{ try g.probe(0), try g.mir.addFloatConst(b, td) });
        try addFlow(&g, 1, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(1), tr }), .f_zero);
        try expectRefused(&g, logic, "node `y`: its delay is not finite");
    }
    // The legal neighbours are the finite RC and td of the test above.
}

test "emit: a node settling at exactly VDD/2 is x, and a constant needs no table" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    // I(y) <+ V(y) - 0.9: F = 0.9 = VDD/2 whatever a is.
    const r = try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(1), try f.mir.addFloatConst(f.alloc(), 0.9) });
    try addFlow(&f, 1, 3, r, .f_zero);
    const text = try emitOk(&f, logic);
    try std.testing.expect(std.mem.find(u8, text, "    wire vera_t_y = 1'bx;\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "case") == null);
}

test "emit: --power-pins puts every supply under USE_POWER_PINS, before and after the signals" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&.{ "vdd", "a", "y", "vss" });
    f.lowered.num_ports = 4;
    const r = try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(2), try f.probe(1) });
    try addFlow(&f, 2, 3, r, .f_zero);
    var o = logic;
    o.power_pins = true;
    const text = try emitOk(&f, o);
    // A leading supply carries its own comma inside the `ifdef`; a trailing
    // one, its leading comma.
    const port_text =
        \\module mymod (
        \\`ifdef USE_POWER_PINS
        \\    vdd,
        \\`endif
        \\      a
        \\    , y
        \\`ifdef USE_POWER_PINS
        \\    , vss
        \\`endif
        \\);
        \\`ifdef USE_POWER_PINS
        \\    inout  wire vdd; // power
        \\`endif
        \\    input  wire a; // digital
        \\    output wire y; // digital
        \\`ifdef USE_POWER_PINS
        \\    inout  wire vss; // ground
        \\`endif
        \\
    ;
    try std.testing.expect(std.mem.find(u8, text, port_text) != null);
}

test "emit: an internal net is declared only when a digital output reads it" {
    const five = [_][]const u8{ "a", "y", "vdd", "vss", "n" };
    // Live: y follows n, n follows a.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&five);
    f.lowered.num_ports = 4;
    const a = f.alloc();
    try addFlow(&f, 1, 3, try f.mir.emit(a, .entry, .fsub, &.{ try f.probe(1), try f.probe(4) }), .f_zero);
    try addFlow(&f, 4, 3, try f.mir.emit(a, .entry, .fsub, &.{ try f.probe(4), try f.probe(0) }), .f_zero);
    const live = try emitOk(&f, logic);
    try std.testing.expect(std.mem.find(u8, live, "    wire vera_n_n; // n\n") != null);
    try std.testing.expect(std.mem.find(u8, live, "        case ({vera_n_n})\n") != null);
    try std.testing.expect(std.mem.find(u8, live, "    assign #(vera_rise_n, vera_fall_n) vera_n_n = vera_t_n;\n") != null);

    // Dead: y follows a, and nothing reads n.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try g.init(&five);
    g.lowered.num_ports = 4;
    const b = g.alloc();
    try addFlow(&g, 1, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(1), try g.probe(0) }), .f_zero);
    try addFlow(&g, 4, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(4), try g.probe(0) }), .f_zero);
    const dead = try emitOk(&g, logic);
    try std.testing.expect(std.mem.find(u8, dead, "vera_n_n") == null);
    try std.testing.expect(std.mem.find(u8, dead, "// n\n") == null);
}

test "emit refuses what it cannot abstract, naming it" {
    const gpa = std.testing.allocator;
    {
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&.{"y"});
        try expectRefused(&f, .{}, "has no ports");
    }
    {
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try buffer(&f);
        try f.lowered.held_vars.append(f.alloc(), .{ .name = "q", .ty = .real, .init = .f_zero, .seed = .f_zero });
        try expectRefused(&f, logic, "`q` holds state");
    }
    {
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try buffer(&f);
        try f.lowered.vectors.put(f.alloc(), "bus", .{ .msb = 1, .lsb = 0 });
        try expectRefused(&f, logic, "vector nets");
    }
    {
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try buffer(&f);
        try expectRefused(&f, .{ .digital = &.{"nope"} }, "`nope` is not a port");
    }
    {
        // §5.6.7 indirect assignment.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try buffer(&f);
        f.lowered.contributions.items[0].kind = .indirect;
        try expectRefused(&f, logic, "indirect");
    }
    {
        // V(y, a) <+ 0: referred to a signal, not a rail.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        try f.lowered.contributions.append(f.alloc(), .{ .access = .potential, .hi = 1, .lo = 0, .wrote_val = .f_one });
        try expectRefused(&f, logic, "must be referred to a supply or ground");
    }
    {
        // V(vdd, y) <+ 0.2 drives y (V(y) = VDD - 0.2), but from its second
        // node: refused rather than silently left undriven.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        try f.lowered.contributions.append(f.alloc(), .{ .access = .potential, .hi = 2, .lo = 1, .resist_val = try f.mir.addFloatConst(f.alloc(), 0.2), .wrote_val = .f_one });
        try expectRefused(&f, logic, "drives its first node");
    }
    {
        // Every assignment enumerated: 21 undriven ports are 2^21 runs.
        const many = comptime blk: {
            var n: [vars_max + 1][]const u8 = undefined;
            for (&n, 0..) |*s, i| s.* = std.fmt.comptimePrint("p{d}", .{i});
            break :blk n;
        };
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&many);
        f.lowered.num_ports = many.len;
        try expectRefused(&f, .{}, "21 pins and driven nodes; the truth tables stop at 20");
    }
    {
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&.{ "vdd", "vss" });
        f.lowered.num_ports = 2;
        try expectRefused(&f, .{ .power_pins = true }, "every port is a supply");
    }
    {
        // I(y) <+ V(a): y's current does not move with V(y).
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        try addFlow(&f, 1, 3, try f.probe(0), .f_zero);
        try expectRefused(&f, logic, "settles nowhere");
    }
    {
        // `$abstime` moves with time: no one value per assignment.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        const t = try f.call("$abstime", &.{});
        try addFlow(&f, 1, 3, try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(1), t }), .f_zero);
        try expectRefused(&f, logic, "`$abstime` has no static value");
    }
    {
        // An internal net nothing drives has no potential to read.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&.{ "a", "y", "vdd", "vss", "n" });
        f.lowered.num_ports = 4;
        try addFlow(&f, 1, 3, try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(1), try f.probe(4) }), .f_zero);
        try expectRefused(&f, logic, "`n` is read but is neither a pin nor a driven net");
    }
}

test "emit: a potential row §5.6.1.3 discards on every path leaves the flow in charge" {
    // Metamorphic: the buffer plus a `V(y, vss)` row whose retention folded
    // to 0 (its accumulators to 0 with it) is the buffer.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try buffer(&f);
    const want = try emitOk(&f, logic);

    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try g.init(&four);
    g.lowered.num_ports = 4;
    try g.lowered.contributions.append(g.alloc(), .{ .access = .potential, .hi = 1, .lo = 3, .wrote_val = .f_zero });
    try addFlow(&g, 1, 3, try g.mir.emit(g.alloc(), .entry, .fsub, &.{ try g.probe(1), try g.probe(0) }), .f_zero);
    try std.testing.expectEqualStrings(want, try emitOk(&g, logic));
}

test "emit: a §5.6.5 switch branch follows whichever quantity this assignment retains" {
    // if (V(a) > 0.9) V(y) <+ 1.8; else I(y) <+ V(y);
    // a = 1: the potential holds y at 1.8; a = 0: the flow I = V(y) settles
    // it at 0. Either way y copies a with no delay: the buffer's text.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try buffer(&f);
    const want = try emitOk(&f, logic);

    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try g.init(&four);
    g.lowered.num_ports = 4;
    const b = g.alloc();
    const on = try g.mir.emit(b, .entry, .fgt, &.{ try g.probe(0), try g.mir.addFloatConst(b, 0.9) });
    try g.lowered.contributions.append(b, .{ .access = .potential, .hi = 1, .lo = 3, .resist_val = try g.mir.addFloatConst(b, 1.8), .wrote_val = on });
    try addFlow(&g, 1, 3, try g.probe(1), .f_zero);
    try std.testing.expectEqualStrings(want, try emitOk(&g, logic));
}

test "emit: phis read the edge taken all at once" {
    // p, q = 0, 1; for (i = 0; i < 1; i++) p, q = q, p;  then I(y) <+ V(y) - 1.8·q.
    // One swap leaves q = 0, so y settles at 0. Reading q's operand after p
    // was overwritten would give q = 1 and y = 1.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    const a = f.alloc();
    const m = &f.mir;
    const header = try m.addBlock(a);
    const body = try m.addBlock(a);
    const exit = try m.addBlock(a);
    _ = try m.emitJump(a, .entry, header);
    const p = try m.emitPhi(a, header, &.{});
    const p_inst = m.blockLast(header);
    const q = try m.emitPhi(a, header, &.{});
    const q_inst = m.blockLast(header);
    const i = try m.emitPhi(a, header, &.{});
    const i_inst = m.blockLast(header);
    const go = try m.emit(a, header, .flt, &.{ i, .f_one });
    _ = try m.emitBranch(a, header, go, body, exit);
    const i_next = try m.emit(a, body, .fadd, &.{ i, .f_one });
    _ = try m.emitJump(a, body, header);
    try m.setPhiPairs(a, p_inst, &.{ .{ .block = .entry, .value = .f_zero }, .{ .block = body, .value = q } });
    try m.setPhiPairs(a, q_inst, &.{ .{ .block = .entry, .value = .f_one }, .{ .block = body, .value = p } });
    try m.setPhiPairs(a, i_inst, &.{ .{ .block = .entry, .value = .f_zero }, .{ .block = body, .value = i_next } });
    const scaled = try m.emit(a, exit, .fmul, &.{ try m.addFloatConst(a, 1.8), q });
    try addFlow(&f, 1, 3, try m.emit(a, exit, .fsub, &.{ try f.probe(1), scaled }), .f_zero);

    try std.testing.expect(std.mem.find(u8, try emitOk(&f, logic), "    wire vera_t_y = 1'b0;\n") != null);
}

test "emit: a row placed after its block's terminator still runs, before it" {
    // `Mir` allows rows after a branch (`lower_var.hiddenHeldInt`); codegen
    // runs them before the terminator, and so must the interpreter.
    // x = 1 + 1 sits after entry's jump; I(y) <+ V(y) - 0.9·x settles at 1.8.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    const a = f.alloc();
    const m = &f.mir;
    const next = try m.addBlock(a);
    _ = try m.emitJump(a, .entry, next);
    const x = try m.emit(a, .entry, .fadd, &.{ .f_one, .f_one });
    const scaled = try m.emit(a, next, .fmul, &.{ try m.addFloatConst(a, 0.9), x });
    try addFlow(&f, 1, 3, try m.emit(a, next, .fsub, &.{ try f.probe(1), scaled }), .f_zero);

    try std.testing.expect(std.mem.find(u8, try emitOk(&f, logic), "    wire vera_t_y = 1'b1;\n") != null);
}

test "emit refuses a vera_pin or vera_delay whose value is not one" {
    // Only the attribute's value is judged here; `attrs.va` in
    // test-external runs the accepted ones by name.
    const bad = [_]struct { name: []const u8, value: ?Const, says: []const u8 }{
        .{ .name = "vera_pin", .value = null, .says = "vera_pin takes" },
        .{ .name = "vera_pin", .value = .{ .real = 1 }, .says = "vera_pin takes" },
        .{ .name = "vera_delay", .value = null, .says = "vera_delay takes" },
        .{ .name = "vera_delay", .value = .{ .str = "1n" }, .says = "vera_delay takes" },
        .{ .name = "vera_delay", .value = .{ .real = -1e-9 }, .says = "vera_delay takes" },
        .{ .name = "vera_delay", .value = .{ .real = std.math.nan(f64) }, .says = "vera_delay takes" },
        // Finite in seconds, infinite in the ns `node` prints.
        .{ .name = "vera_delay", .value = .{ .real = 1e300 }, .says = "vera_delay takes" },
    };
    for (bad) |b| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try buffer(&f);
        const attrs = [_]Lowered.DeclAttr{.{ .tok = 0, .name = b.name, .value = b.value }};
        f.lowered.decl_attrs = &attrs;
        try expectRefused(&f, logic, b.says);
    }
    // The neighbours that pass: a zero delay, and an attribute VerA ignores.
    for ([_]Lowered.DeclAttr{ .{ .tok = 0, .name = "vera_delay", .value = .{ .int = 0 } }, .{ .tok = 0, .name = "other", .value = null } }) |ok| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try buffer(&f);
        f.lowered.decl_attrs = &.{ok};
        _ = try emitOk(&f, logic);
    }
}

test "emit: a driven analog port stays an undriven inout, its bit an internal net" {
    // `a` analog; y digital follows it, and I(a) <+ V(a) - V(vdd) drives a high.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try f.init(&four);
    f.lowered.num_ports = 4;
    const m = f.alloc();
    try addFlow(&f, 0, 3, try f.mir.emit(m, .entry, .fsub, &.{ try f.probe(0), try f.probe(2) }), .f_zero);
    try addFlow(&f, 1, 3, try f.mir.emit(m, .entry, .fsub, &.{ try f.probe(1), try f.probe(0) }), .f_zero);
    const text = try emitOk(&f, .{ .digital = &.{"y"} });
    for ([_][]const u8{
        "    inout  wire a; // analog, undriven\n",
        "    wire vera_n_a; // a\n",
        "    wire vera_t_a = 1'b1;\n",
        "        case ({vera_n_a})\n",
        "    assign #(vera_rise_a, vera_fall_a) vera_n_a = vera_t_a;\n",
    }) |want| try std.testing.expect(std.mem.find(u8, text, want) != null);
}

test "emit: a supply contribution against a supply is the supply itself" {
    // Metamorphic: the buffer plus V(vdd, vss) <+ 1.8 is the buffer.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try buffer(&f);
    const want = try emitOk(&f, logic);
    try f.lowered.contributions.append(f.alloc(), .{ .access = .potential, .hi = 2, .lo = 3, .resist_val = try f.mir.addFloatConst(f.alloc(), 1.8), .wrote_val = .f_one });
    try std.testing.expectEqualStrings(want, try emitOk(&f, logic));
}

test "emit: the static callees fold to the values the header gives them" {
    // I(y) <+ V(y) - k·V(a) with k a callee that is 1 here: the buffer's text.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try buffer(&f);
    const want = try emitOk(&f, logic);
    for ([_][]const u8{ "$mfactor", "limexp", "slew" }) |name| {
        var g: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer g.deinit();
        try g.init(&four);
        g.lowered.num_ports = 4;
        const b = g.alloc();
        // limexp(0) = 1, slew(1) = 1.
        const arg: []const Mir.Value = if (std.mem.eql(u8, name, "limexp")) &.{.f_zero} else if (std.mem.eql(u8, name, "slew")) &.{.f_one} else &.{};
        const k = try g.call(name, arg);
        const scaled = try g.mir.emit(b, .entry, .fmul, &.{ k, try g.probe(0) });
        try addFlow(&g, 1, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(1), scaled }), .f_zero);
        try std.testing.expectEqualStrings(want, try emitOk(&g, logic));
    }
    // Over a 2 ns transition: absdelay's td adds like transition's, a
    // negative td adds 0 (not -1 ns), and no td argument adds nothing.
    for ([_]struct { name: []const u8, td: ?f64, ns: []const u8 }{
        .{ .name = "absdelay", .td = 2e-9, .ns = "4.000000" },
        .{ .name = "transition", .td = -1e-9, .ns = "2.000000" },
        .{ .name = "transition", .td = null, .ns = "2.000000" },
    }) |c| {
        var g: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer g.deinit();
        try g.init(&four);
        g.lowered.num_ports = 4;
        const b = g.alloc();
        const x = try g.call("transition", &.{ try g.probe(0), try g.mir.addFloatConst(b, 2e-9) });
        const tr = if (c.td) |td| try g.call(c.name, &.{ x, try g.mir.addFloatConst(b, td) }) else try g.call(c.name, &.{x});
        try addFlow(&g, 1, 3, try g.mir.emit(b, .entry, .fsub, &.{ try g.probe(1), tr }), .f_zero);
        const text = try emitOk(&g, logic);
        const line = try std.fmt.allocPrint(b, "parameter real vera_rise_y = {s}; // ns\n", .{c.ns});
        try std.testing.expect(std.mem.find(u8, text, line) != null);
    }
}

test "emit refuses a node whose law or value it cannot pin down" {
    const gpa = std.testing.allocator;
    {
        // if (V(y) > 0.9) V(y) <+ 1.8; else I(y) <+ V(y): which law holds
        // depends on y itself, so there is no one secant.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        const b = f.alloc();
        const on = try f.mir.emit(b, .entry, .fgt, &.{ try f.probe(1), try f.mir.addFloatConst(b, 0.9) });
        try f.lowered.contributions.append(b, .{ .access = .potential, .hi = 1, .lo = 3, .resist_val = try f.mir.addFloatConst(b, 1.8), .wrote_val = on });
        try addFlow(&f, 1, 3, try f.probe(1), .f_zero);
        try expectRefused(&f, logic, "depends on its own value");
    }
    {
        // V(y, vss) <+ inf.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        try f.lowered.contributions.append(f.alloc(), .{ .access = .potential, .hi = 1, .lo = 3, .resist_val = try f.mir.addFloatConst(f.alloc(), std.math.inf(f64)), .wrote_val = .f_one });
        try expectRefused(&f, logic, "its settled potential is not finite");
    }
    {
        // A phi in the entry block has no edge to read.
        var f: Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try f.init(&four);
        f.lowered.num_ports = 4;
        const p = try f.mir.emitPhi(f.alloc(), .entry, &.{});
        try addFlow(&f, 1, 3, try f.mir.emit(f.alloc(), .entry, .fsub, &.{ try f.probe(1), p }), .f_zero);
        try expectRefused(&f, logic, "a phi with no operand for the edge taken");
    }
    // The 2^20-step bound on a block that never finishes is not run here:
    // reaching it takes 4 s in Debug.
}

test "emit: an allocation failure anywhere is OutOfMemory, never a refusal or a crash" {
    for ([_]bool{ false, true }) |rc| try std.testing.checkAllAllocationFailures(std.testing.allocator, emitUnderFailure, .{rc});
}
