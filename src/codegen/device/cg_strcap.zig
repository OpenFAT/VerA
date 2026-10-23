//! String capacities -> the size of each emitted string row. A device has no
//! allocator, so every run-time string lives in a static row: a §9.5.3
//! formatter's or a §3.3 concatenation's call-site row (`str_kernels.zSRow`)
//! and a §5.10 held string's `Instance` field (`ZStrHeldN`). This sizes each
//! from what the model can put there, so no legal model overruns one.
//! LRM §3.3 (strings, Table 3-3), §5.10 (held values), §9.5.3/§9.5.4.
//!
//! `cap(v)` is the most bytes string Value `v` can hold. A piece whose length
//! is run-time data no fold bounds (a file line, a string parameter a card
//! may set, a `$plusargs` value, an array element) counts `row` bytes, the
//! row every site had before rows were sized; text longer than its row ends
//! the run with E1011 (`zSOver`), §9.5.3 giving no truncation rule. A row is
//! never below `row`, so a model that ran before still runs.

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const cg_display = @import("cg_display.zig");
const gen_call = @import("codegen/call.zig");
const none_u32 = cg.none_u32;

/// The row every string site had before rows were sized, and what a piece of
/// run-time length counts.
pub const row: u64 = 4096;

/// The largest row a device can address: 2^47 bytes, a 64-bit host's user
/// address space. A larger one is E1011 when the model compiles.
pub const max_row: u64 = 1 << 47;

/// The longest `$ferror` description (`file_kernels.zFErrorStr`).
const ferror_max: u64 = 32;

comptime {
    assert(row <= max_row);
    assert(ferror_max <= row);
    assert(std.math.isPowerOfTwo(max_row));
}

/// The most bytes string Value `v` can hold. Memoized per Value; a Value met
/// again while its own capacity is computed (a loop's phi) counts `row`.
pub fn cap(g: *Gen, v0: Mir.Value) Error!u64 {
    if (g.held_caps == null) try planHeld(g);
    const v = g.an.rv(v0);
    if (g.str_caps.get(v)) |c| return c;
    try g.str_caps.put(g.arena, v, row);
    const c = try compute(g, v);
    try g.str_caps.put(g.arena, v, c);
    return c;
}

// ponytail: recursive over the string's defining Values; a string built by
// thousands of chained concatenations recurses that deep. An explicit stack
// is the upgrade if one measures it.
fn compute(g: *Gen, v: Mir.Value) Error!u64 {
    const inst = switch (g.mir.valueDef(v)) {
        .str_const => |s| return s.len,
        // A number where a string is read prints its digits (§2.7): a
        // folded-away held string is the literal zero.
        .undef, .float_const, .int_const => return 0,
        .param_ref, .block_param => return row,
        .inst_result => |i| i,
    };
    switch (g.mir.instData(inst)) {
        .phi => |d| {
            var m: u64 = 0;
            for (0..d.count) |i| m = @max(m, try cap(g, g.mir.phiPair(inst, @intCast(i)).value));
            return m;
        },
        .ternary => |t| return @max(try cap(g, t.then_val), try cap(g, t.else_val)),
        .call => |c| return callCap(g, c.callee, c.args),
        // else: a load is an array element, and no other class yields a string
        .unary, .binary, .branch, .jump, .anew, .load, .store => return row,
    }
}

fn callCap(g: *Gen, c: Mir.Callee, args: []const Mir.Value) Error!u64 {
    switch (c) {
        .@"$sformat" => {
            var fmt: std.ArrayList(u8) = .empty;
            var ops: cg_display.Ops = .empty;
            try cg_display.buildArgs(g, args, &fmt, &ops);
            return cg_display.siteCap(g, fmt.items, ops.items);
        },
        .@"$sformat$rt" => return rtFormatCap(g, args),
        .@"$str$cat" => {
            var n: u64 = 0;
            for (args) |a| n +|= try cap(g, a);
            return @max(n, row);
        },
        .@"$str$repeat" => {
            assert(args.len == 2); // analog/expr.zig mints (copies, string)
            const k = g.an.foldConst(args[0], false) orelse return row;
            const copies = std.math.lossyCast(u64, @max(k.f, 0));
            return @max(copies *| try cap(g, args[1]), row);
        },
        .@"$held_str" => return heldCap(g, gen_call.heldIdx(g, args)),
        // §9.5.4.2 an item is a slice of the input string.
        .@"$sscanf$str" => return if (args.len > 0) cap(g, args[0]) else 0,
        .@"$ferror$str" => return ferror_max,
        else => return row, // else: a file line or item, a `$plusargs` or `$simparam` string, an array element: run-time lengths
    }
}

/// The row of a `$sformat` whose format is a string variable
/// (`str_kernels.zSFormatRt`): the format's own text plus each operand's
/// widest rendering. A width written in the run-time format can still ask
/// for more (E1011).
pub fn rtFormatCap(g: *Gen, args: []const Mir.Value) Error!u64 {
    var n: u64 = if (args.len > 0) try cap(g, args[0]) else 0;
    for (args[@min(1, args.len)..]) |a| n +|= switch (g.an.tyOf(g.an.rv(a))) {
        .str => try cap(g, a),
        // %e/%f/%g/%r of f64 (`zCReal`'s body), or 64 binary digits.
        .real, .int => 512,
        .wide => unreachable, // lowering hands a task no wide value: a whole wide `reg` read is E0222
    };
    return @max(n, row);
}

/// The capacity of §5.10 held string `i` (`Lowered.held_vars` row): what its
/// end-of-block value can hold, never below `row`. Asserts that the planned
/// capacities have one row per `held_vars` row. A held string's value may
/// read held strings (itself, through `$held_str`), so the capacities are
/// solved together, each round reading the last round's; a model whose string
/// grows by itself every step does not settle, and keeps the capacity the
/// last round gave (E1011 when it outgrows it).
fn heldCap(g: *Gen, i: usize) Error!u64 {
    if (g.held_caps == null) try planHeld(g);
    const caps = g.held_caps.?;
    assert(caps.len == g.lowered.held_vars.items.len);
    const c = if (i < caps.len) caps[i] else row;
    assert(c >= row);
    return c;
}

fn planHeld(g: *Gen) Error!void {
    const held = g.lowered.held_vars.items;
    const caps = try g.arena.alloc(u64, held.len);
    for (held, caps) |h, *c| c.* = @max(row, initLen(g, h.init));
    g.held_caps = caps;
    var round: usize = 0;
    while (round <= held.len) : (round += 1) {
        g.str_caps.clearRetainingCapacity();
        var changed = false;
        for (held, caps) |h, *c| {
            if (h.ty != .string or h.array != none_u32) continue;
            const n = try cap(g, h.final);
            if (n > c.*) {
                c.* = n;
                changed = true;
            }
        }
        if (!changed) break;
    }
    for (caps) |c| assert(c >= row);
    g.str_caps.clearRetainingCapacity();
}

fn initLen(g: *Gen, init: Mir.Value) u64 {
    return switch (g.mir.valueDef(g.an.rv(init))) {
        .str_const => |s| s.len,
        .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => 0,
    };
}

/// The `Instance` type of held string `i`: `ZStrHeld` for the `row`, else
/// `ZStrHeldN(cap)`.
pub fn emitHeldType(g: *Gen, i: usize) Error!void {
    const c = try heldCap(g, i);
    if (c == row) return g.w("ZStrHeld", .{});
    return g.w("ZStrHeldN({d})", .{c});
}

/// The call that copies text into held string `i`'s type: `zStrHeld(` or
/// `zStrHeldN(cap, `; the caller writes the text and the `)`.
pub fn emitHeldCopy(g: *Gen, i: usize) Error!void {
    const c = try heldCap(g, i);
    if (c == row) return g.w("zStrHeld(", .{});
    return g.w("zStrHeldN({d}, ", .{c});
}
