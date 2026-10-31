//! A gate's or UDP's input bits in, its output bit out: the §7.8.5 gate tables, the §7.6 switch strength rules and the §8 UDP rows, levels and edges.
//! Cites: IEEE 1364-2005 §7.6, §7.8.5 (A.3.1, A.3.4), §8.1 to §8.6.
//!
//! Contents:
//! - `pub const Gate = struct`
//! - `pub fn gateBit(kind: Ast.GateKind, ins: []const Int.Bit) GateOut`
//! - `pub fn udpRows(a: std.mem.Allocator, decl: *const Ast.UdpDecl) Error!?[]const UdpRow`
//! - `pub fn udpEval(rows: []const UdpRow, sequential: bool, ins: []const Int.Bit, state: Int.Bit, changed: ?u32, from: Int.Bit) Int.Bit`
//! - `pub fn gateWorlds(kind: Ast.GateKind, ins: []const Int.Bit) GateOut`
//! Driver bits, their A.2.2.2 strengths and the net's type -> one resolved
//! four-state bit, a delay in scheduler ticks, or a gate output bit. Data and
//! pure functions only; no engine state. IEEE 1364-2005 §7.9 Tables 7-4/7-6/7-7
//! and §7.10 strength resolution, §7.8.5 gate tables (A.3.1, A.3.4), §7.6/§7.12
//! switches, §8 UDPs, §3.7 undriven values, §3.8 `trireg` charge, A.2.2.3
//! `delay3` chosen per §7.14, §6.1.3 vector and inertial delays.
const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const Error = @import("root.zig").Error;
const expectRun = @import("root.zig").expectRun;
const Handle = @import("../scheduler.zig").Handle;
const net = @import("net.zig");
const GateOut = net.GateOut;
const UdpRow = net.UdpRow;
const UdpSym = net.UdpSym;

/// One A.3.1 gate instance, reduced to what §7.8.5 needs to compute its output:
/// the type and the input terminals in source order.
///
/// One member of a §7.1.5 instance array is lane `lane` of `lanes`: an input
/// as wide as the array gives it its bit `lane` (§7.1.6), a scalar one is
/// broadcast, and it drives bit `out_bit` of a vector output net.
pub const Gate = struct { kind: Ast.GateKind, ins: []const Ast.ExprId, lane: ?u32 = null, lanes: u32 = 1, out_bit: ?u32 = null };

/// §7.8.5's tables for A.3.4's twelve computing gate types, one output bit.
///
/// The n-input arms are controlling-value rules, which is what the tables
/// encode: `and(0, x)` is 0 because the 0 controls, while `xor(0, x)` is x
/// because xor has no controlling value. `ins` holds `(data, enable)` for
/// the four enable gates and at least one input for every other kind.
pub fn gateBit(kind: Ast.GateKind, ins: []const Int.Bit) GateOut {
    assert(ins.len != 0);
    switch (kind) {
        // A.3.1 `( output_terminal , input_terminal , enable_terminal )`. Three
        // regimes: the off enable gives z whatever the data is; the on enable
        // gives the gate function of the data; an x/z enable means the gate may
        // or may not be conducting, which IEEE 1364 writes as L (0-or-z) or H
        // (1-or-z). Neither is a member of {0,1,x,z} (L is not 0, because it
        // might be z), so the value alone projects to x, and the flag is what
        // lets §7.10.3 resolve it against another driver (Figure 7-6).
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => {
            assert(ins.len == 2); // A.3.1 (data, enable).
            const on: Int.Bit = if (kind == .g_bufif1 or kind == .g_notif1) .one else .zero;
            const enable = ins[1];
            const data = if (kind == .g_bufif0 or kind == .g_bufif1) gateIn(ins[0]) else invert(ins[0]);
            if (enable == .x or enable == .z) return .{ .bit = data, .or_z = data != .x };
            if (enable != on) return .{ .bit = .z };
            return .{ .bit = data };
        },
        .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor, .g_buf, .g_not => return .{ .bit = logicBit(kind, ins) },
    }
}

/// Split A.5.3's input characters into one field per input, or null when an
/// entry has the wrong number of them (A.5.3 gives each input exactly one).
pub fn udpRows(a: std.mem.Allocator, decl: *const Ast.UdpDecl) Error!?[]const UdpRow {
    assert(decl.ports.len >= 2); // An output and at least one input (§8.1.2).
    const inputs = decl.ports.len - 1;
    const rows = try a.alloc(UdpRow, decl.rows.len);
    for (decl.rows, rows) |src, *row| {
        // Exactly one symbol per input, else the row is malformed: a symbol
        // past `inputs` already makes it so.
        var syms: std.ArrayList(UdpSym) = try .initCapacity(a, inputs);
        var edge_at: ?u32 = null;
        var i: usize = 0;
        while (i < src.inputs.len) : (i += 1) {
            const c = src.inputs[i];
            const sym: UdpSym = switch (c) {
                '(' => blk: {
                    if (i + 3 >= src.inputs.len or src.inputs[i + 3] != ')') return null;
                    const pair: [2]u8 = .{ std.ascii.toLower(src.inputs[i + 1]), std.ascii.toLower(src.inputs[i + 2]) };
                    i += 3;
                    break :blk .{ .pair = pair };
                },
                'r', 'R', 'f', 'F', 'p', 'P', 'n', 'N', '*' => .{ .letter = std.ascii.toLower(c) },
                else => .{ .level = std.ascii.toLower(c) },
            };
            if (syms.items.len == inputs) return null;
            if (sym != .level) edge_at = @intCast(syms.items.len);
            syms.appendAssumeCapacity(sym);
        }
        if (syms.items.len != inputs) return null;
        row.* = .{ .ins = syms.items, .state = std.ascii.toLower(src.state), .out = std.ascii.toLower(src.output), .edge_at = edge_at };
        if (edge_at) |k| assert(k < inputs);
    }
    assert(rows.len == decl.rows.len);
    return rows;
}

/// §8.6/§8.7 one evaluation. With `changed == null` only level entries can
/// match (a combinational table, or a sequential one re-read without an
/// event); otherwise `changed` went from `from` to `ins[changed]`, and an
/// edge entry on that input matches too, after every level entry, since
/// §8.8 makes level-sensitive entries dominate edge-sensitive ones. Nothing
/// matching is x (§8.1.6: "a combination of input values not specified ...
/// results in x"). `ins` has one value per input field of every row (as
/// `udpRows` made them), and `changed`, when given, indexes it.
pub fn udpEval(rows: []const UdpRow, sequential: bool, ins: []const Int.Bit, state: Int.Bit, changed: ?u32, from: Int.Bit) Int.Bit {
    if (changed) |k| assert(k < ins.len);
    for (rows) |row| assert(row.ins.len == ins.len);
    for (rows) |row| {
        if (row.edge_at != null) continue;
        if (sequential and !udpLevel(row.state, state)) continue;
        for (row.ins, ins) |sym, b| {
            if (!udpLevel(sym.level, b)) break;
        } else return udpOut(row.out, state);
    }
    const k = changed orelse return .x;
    for (rows) |row| {
        if (row.edge_at != k or !udpLevel(row.state, state)) continue;
        for (row.ins, ins, 0..) |sym, b, i| {
            if (i == k) {
                if (!udpEdge(sym, from, b)) break;
            } else if (sym != .level or !udpLevel(sym.level, b)) break;
        } else return udpOut(row.out, state);
    }
    return .x;
}

/// The §7.8.5 truth tables read as "an x input is a 0 or a 1" (and a z
/// input as an x, §7.8.5: "a gate transmits a logic value"): the output
/// every resolution of the unknown inputs agrees on, else x. An enable gate
/// whose resolutions give one value or z is that value's L/H (Figure 7-6).
/// The oracle `gateBit`'s controlling-value rules are checked against: it
/// enumerates worlds instead of reading a controlling value.
pub fn gateWorlds(kind: Ast.GateKind, ins: []const Int.Bit) GateOut {
    std.debug.assert(ins.len <= 3);
    var seen = [3]bool{ false, false, false }; // the output was 0, 1, z
    for (0..@as(usize, 1) << @intCast(ins.len)) |world| {
        var v: [3]bool = undefined;
        const fits = for (ins, 0..) |b, i| {
            v[i] = (world >> @intCast(i)) & 1 != 0;
            if ((b == .zero and v[i]) or (b == .one and !v[i])) break false;
        } else true;
        if (!fits) continue;
        const in = v[0..ins.len];
        var all = true;
        var any = false;
        var odd = false;
        for (in) |p| {
            all = all and p;
            any = any or p;
            odd = odd != p;
        }
        const z: usize = 2;
        const out: usize = switch (kind) {
            .g_and => @intFromBool(all),
            .g_nand => @intFromBool(!all),
            .g_or => @intFromBool(any),
            .g_nor => @intFromBool(!any),
            .g_xor => @intFromBool(odd),
            .g_xnor => @intFromBool(!odd),
            .g_buf => @intFromBool(in[0]),
            .g_not => @intFromBool(!in[0]),
            // A.3.1 `(out, data, enable)`: an off enable gives z.
            .g_bufif0 => if (in[1]) z else @intFromBool(in[0]),
            .g_bufif1 => if (in[1]) @intFromBool(in[0]) else z,
            .g_notif0 => if (in[1]) z else @intFromBool(!in[0]),
            .g_notif1 => if (in[1]) @intFromBool(!in[0]) else z,
        };
        seen[out] = true;
    }
    assert(seen[0] or seen[1] or seen[2]); // Some world fits the inputs.
    if (seen[0] and seen[1]) return .{ .bit = .x };
    if (seen[0]) return .{ .bit = .zero, .or_z = seen[2] };
    if (seen[1]) return .{ .bit = .one, .or_z = seen[2] };
    return .{ .bit = .z };
}

// ---- private ----

/// §7.8.5: "a gate transmits a logic value, not a connection": every primitive
/// but the MOS switches reads a z input as x, unlike the expression operators.
fn gateIn(b: Int.Bit) Int.Bit {
    const in: Int.Bit = if (b == .z) .x else b;
    assert(in != .z); // §7.8.5: a z input reads as x.
    return in;
}

/// ~x is x and ~z is x: the complement of "unknown" is unknown.
fn invert(b: Int.Bit) Int.Bit {
    const out: Int.Bit = switch (b) {
        .zero => .one,
        .one => .zero,
        .x, .z => .x,
    };
    assert(out != .z);
    return out;
}

fn logicBit(kind: Ast.GateKind, ins: []const Int.Bit) Int.Bit {
    assert(ins.len != 0);
    switch (kind) {
        .g_and, .g_nand, .g_or, .g_nor => {
            // The value that decides the output on its own, and the output it
            // decides: `and` is controlled by 0 and produces 0.
            const control: Int.Bit = if (kind == .g_and or kind == .g_nand) .zero else .one;
            var unknown = false;
            for (ins) |raw| {
                const b = gateIn(raw);
                if (b == control) return if (kind == .g_and or kind == .g_or) control else invert(control);
                if (b == .x) unknown = true;
            }
            if (unknown) return .x;
            const quiet = invert(control);
            return if (kind == .g_and or kind == .g_or) quiet else control;
        },
        .g_xor, .g_xnor => {
            var ones: u32 = 0;
            for (ins) |raw| {
                const b = gateIn(raw);
                if (b == .x) return .x;
                if (b == .one) ones += 1;
            }
            const parity: Int.Bit = if (ones % 2 == 1) .one else .zero;
            return if (kind == .g_xor) parity else invert(parity);
        },
        .g_buf, .g_not => {
            assert(ins.len == 1);
            return if (kind == .g_buf) gateIn(ins[0]) else invert(ins[0]);
        },
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => unreachable, // gateBit's own arm
    }
}

/// Table 8-1's level symbols against a value the table reads (§8.1.6: a z
/// input has already been read as x).
fn udpLevel(sym: u8, b: Int.Bit) bool {
    assert(sym == std.ascii.toLower(sym)); // `udpRows` folds the case.
    return switch (sym) {
        '0' => b == .zero,
        '1' => b == .one,
        'x' => b == .x,
        '?' => true,
        'b' => b == .zero or b == .one,
        else => false,
    };
}

/// Table 8-1's edges: `(vw)` is v then w; r is (01), f (10), p any of (01)
/// (0x) (x1), n any of (10) (1x) (x0), and * any change at all.
fn udpEdge(sym: UdpSym, from: Int.Bit, to: Int.Bit) bool {
    if (from == to) return false;
    assert(from != to);
    return switch (sym) {
        .level => false,
        .pair => |p| udpLevel(p[0], from) and udpLevel(p[1], to),
        .letter => |l| switch (l) {
            'r' => from == .zero and to == .one,
            'f' => from == .one and to == .zero,
            'p' => (from == .zero and to != .zero) or (from == .x and to == .one),
            'n' => (from == .one and to != .one) or (from == .x and to == .zero),
            else => true, // `*`
        },
    };
}

fn udpOut(sym: u8, state: Int.Bit) Int.Bit {
    assert(sym == std.ascii.toLower(sym));
    return switch (sym) {
        '0' => .zero,
        '1' => .one,
        '-' => state,
        else => .x,
    };
}

// §7.1.6: a vector terminal as wide as the array is split one bit per gate,
// a scalar one is shared, and each gate drives only its own output bit.
test "§7.1.5 a gate instance array splits vector terminals and shares scalars" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [2:0] a, b; reg e; wire [2:0] y; wire [2:0] z;
        \\and g[2:0](y, a, b);
        \\bufif0 f[0:2](z, a, e);
        \\initial begin a = 3'b110; b = 3'b011; e = 1; #1 $write("%b %b ", y, z); e = 0; #1 $display("%b", z); end
        \\endmodule
    , "010 zzz 110\n");
}

// §8: a rising-edge toggle built from Table 8-1's letters, behind an
// instance delay: the initial state is out at time 0, a falling edge holds,
// each rising edge flips the state and lands 2 units later.
test "§8 a sequential UDP with edge letters, an initial state and an instance delay" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\primitive tog(q, c);
        \\  output q; reg q; input c;
        \\  initial q = 1;
        \\  table r : 0 : 1; r : 1 : 0; f : ? : -; (?x) : ? : -; (x?) : ? : -; endtable
        \\endprimitive
        \\module m;
        \\reg c; wire q;
        \\tog #2 t(q, c);
        \\initial begin
        \\  #1 $write("%b", q); c = 0; #1 c = 1; #1 $write("%b", q); #1 $write("%b", q);
        \\  c = 0; #3 c = 1; #3 $display("%b", q);
        \\end
        \\endmodule
    , "1101\n");
}

test "§7.8.5 every gate table agrees with every resolution of its unknown inputs" {
    const bits = [_]Int.Bit{ .zero, .one, .x, .z };
    const Case = struct { Ast.GateKind, usize };
    const cases = [_]Case{
        .{ .g_and, 2 },
        .{ .g_and, 3 },
        .{ .g_nand, 2 },
        .{ .g_nand, 3 },
        .{ .g_or, 2 },
        .{ .g_or, 3 },
        .{ .g_nor, 2 },
        .{ .g_nor, 3 },
        .{ .g_xor, 2 },
        .{ .g_xor, 3 },
        .{ .g_xnor, 2 },
        .{ .g_xnor, 3 },
        .{ .g_buf, 1 },
        .{ .g_not, 1 },
        .{ .g_bufif0, 2 },
        .{ .g_bufif1, 2 },
        .{ .g_notif0, 2 },
        .{ .g_notif1, 2 },
    };
    for (cases) |c| {
        const kind, const n = c;
        var ins: [3]Int.Bit = undefined;
        // Every combination of 0, 1, x and z on `n` inputs: 4^n of them.
        for (0..std.math.pow(usize, 4, n)) |code| {
            var rest = code;
            for (ins[0..n]) |*b| {
                b.* = bits[rest % 4];
                rest /= 4;
            }
            try std.testing.expectEqual(gateWorlds(kind, ins[0..n]), gateBit(kind, ins[0..n]));
        }
    }
}

test udpRows {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decl: Ast.UdpDecl = .{
        .name = .none,
        .ports = &.{ .none, .none, .none },
        .is_sequential = true,
        .rows = &.{
            .{ .inputs = "(01)0", .state = '?', .output = '1' },
            .{ .inputs = "R?", .state = 'X', .output = '-' },
            .{ .inputs = "1b", .state = 'b', .output = 'x' },
        },
    };
    const rows = (try udpRows(a, &decl)).?;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(?u32, 0), rows[0].edge_at);
    try std.testing.expectEqualSlices(u8, "01", &rows[0].ins[0].pair);
    try std.testing.expectEqual(@as(u8, '0'), rows[0].ins[1].level);
    // Table 8-1's letters and the state column are read case-blind.
    try std.testing.expectEqual(@as(u8, 'r'), rows[1].ins[0].letter);
    try std.testing.expectEqual(@as(?u32, 0), rows[1].edge_at);
    try std.testing.expectEqual(@as(u8, 'x'), rows[1].state);
    try std.testing.expectEqual(@as(?u32, null), rows[2].edge_at);
    try std.testing.expectEqual(@as(u8, 'x'), rows[2].out);
    // A.5.3 gives each input exactly one field: one too few, one too many,
    // and an edge whose parenthesis does not close are malformed.
    for ([_][]const u8{ "0", "000", "(01", "(0)1" }) |bad| {
        const one: Ast.UdpDecl = .{ .name = .none, .ports = &.{ .none, .none, .none }, .rows = &.{.{ .inputs = bad, .output = '0' }} };
        try std.testing.expect((try udpRows(a, &one)) == null);
    }
}

test udpEval {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A combinational AND table.
    const comb: Ast.UdpDecl = .{
        .name = .none,
        .ports = &.{ .none, .none, .none },
        .rows = &.{
            .{ .inputs = "11", .output = '1' },
            .{ .inputs = "0?", .output = '0' },
            .{ .inputs = "?0", .output = '0' },
        },
    };
    const and_rows = (try udpRows(a, &comb)).?;
    try std.testing.expectEqual(Int.Bit.one, udpEval(and_rows, false, &.{ .one, .one }, .x, null, .x));
    try std.testing.expectEqual(Int.Bit.zero, udpEval(and_rows, false, &.{ .zero, .x }, .x, null, .x));
    try std.testing.expectEqual(Int.Bit.zero, udpEval(and_rows, false, &.{ .x, .zero }, .x, null, .x));
    // §8.1.6: a combination no entry names is x.
    try std.testing.expectEqual(Int.Bit.x, udpEval(and_rows, false, &.{ .one, .x }, .x, null, .x));
    // A sequential table over (clk, d): d = 1 sets, a rising clk clears, a
    // falling clk with d = 0 holds, and clk at x with d = 0 sets only from
    // state 1.
    const seq: Ast.UdpDecl = .{
        .name = .none,
        .ports = &.{ .none, .none, .none },
        .is_sequential = true,
        .rows = &.{
            .{ .inputs = "?1", .state = '?', .output = '1' },
            .{ .inputs = "r?", .state = '?', .output = '0' },
            .{ .inputs = "f0", .state = '?', .output = '-' },
            .{ .inputs = "x0", .state = '1', .output = '1' },
        },
    };
    const ff = (try udpRows(a, &seq)).?;
    // clk 0 -> 1 with d = 0: the edge entry.
    try std.testing.expectEqual(Int.Bit.zero, udpEval(ff, true, &.{ .one, .zero }, .x, 0, .zero));
    // clk 0 -> 1 with d = 1: the edge entry says 0, but §8.8 makes the
    // level entry dominate.
    try std.testing.expectEqual(Int.Bit.one, udpEval(ff, true, &.{ .one, .one }, .zero, 0, .zero));
    // clk 1 -> 0 with d = 0: `-` keeps the state.
    try std.testing.expectEqual(Int.Bit.one, udpEval(ff, true, &.{ .zero, .zero }, .one, 0, .one));
    // clk 0 -> x: no entry names that edge, so x.
    try std.testing.expectEqual(Int.Bit.x, udpEval(ff, true, &.{ .x, .zero }, .zero, 0, .zero));
    // With no event only level entries match, and the state column counts.
    try std.testing.expectEqual(Int.Bit.one, udpEval(ff, true, &.{ .x, .zero }, .one, null, .x));
    try std.testing.expectEqual(Int.Bit.x, udpEval(ff, true, &.{ .x, .zero }, .zero, null, .x));
}

// §7.6/§7.12: a MOS switch passes its data at the data's strength (reduced by
// an `r` switch), a tran joins two nets into one resolution, and a tranif
// whose control is x lets the far side's value arrive only as "or z".
test "§7.6 MOS strength pass-through and reduction, tran and tranif joins" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg d, g, c; wire n, rn, p, q, s, t;
        \\pullup (n); pullup (rn);
        \\nmos (n, d, g); rnmos (rn, d, g);
        \\assign p = d; tran (p, q);
        \\buf (s, 1'b1); tranif1 (s, t, c);
        \\initial begin
        \\  d = 0; g = 1; c = 1'bx; #1 $write("%b%b %b%b %b%b ", n, rn, p, q, s, t);
        \\  c = 1; #1 $write("%b ", t); c = 0; #1 $display("%b", t);
        \\end
        \\endmodule
    , "0x 00 1x 1 z\n");
}
