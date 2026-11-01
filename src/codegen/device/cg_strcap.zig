//! String capacities -> the size of each emitted string row. A device has no
//! allocator, so every run-time string lives in a static row: a §9.5.3
//! formatter's or a §3.3 concatenation's call-site row (`str_store.zSRow`)
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
//!
//! Contents:
//! - `pub const row: u64 = 4096`
//! - `pub const max_row: u64 = 1 << 47`
//! - `pub fn cap(g: *Gen, v0: Mir.Value) Error!u64`
//! - `pub fn rtFormatCap(g: *Gen, args: []const Mir.Value) Error!u64`
//! - `pub fn emitHeldType(g: *Gen, i: usize) Error!void`
//! - `pub fn emitHeldCopy(g: *Gen, i: usize) Error!void`

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
/// Walks the Values `v` is built from depth first on a heap stack, in the
/// order `compute` reads them, so a string built by a chain of concatenations
/// as long as the source costs no stack.
pub fn cap(g: *Gen, v0: Mir.Value) Error!u64 {
    assert(g.an.vty.len == g.an.nv);
    if (g.held_caps == null) try planHeld(g);
    assert(g.held_caps != null);
    const v = g.an.rv(v0);
    if (g.str_caps.get(v)) |c| return c;
    const Frame = struct { v: Mir.Value, open: bool };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(g.gpa);
    var reads: std.ArrayList(Mir.Value) = .empty;
    defer reads.deinit(g.gpa);
    try stack.append(g.gpa, .{ .v = v, .open = false });
    // Bounded: a Value opens once (it is memoized as it opens), and only an
    // opening pushes, so the pops are at most one per open plus its reads.
    var opened: usize = 0;
    while (stack.pop()) |f| {
        if (f.open) {
            // Every Value `compute` reads below is memoized now.
            try g.str_caps.put(g.arena, f.v, try compute(g, f.v));
            continue;
        }
        // Done, or open further down: a cycle reads `row`, as it did.
        if (g.str_caps.contains(f.v)) continue;
        try g.str_caps.put(g.arena, f.v, row);
        opened += 1;
        assert(opened <= g.an.nv);
        try stack.append(g.gpa, .{ .v = f.v, .open = true });
        reads.clearRetainingCapacity();
        try readsOf(g, f.v, &reads);
        // Last first, so the first read is the next visited.
        var k = reads.items.len;
        while (k > 0) {
            k -= 1;
            try stack.append(g.gpa, .{ .v = g.an.rv(reads.items[k]), .open = false });
        }
    }
    // `v` was not memoized, so the first pop opened it.
    assert(opened >= 1);
    return g.str_caps.get(v).?;
}

/// The row of a `$sformat` whose format is a string variable
/// (`str_format.zSFormatRt`): the format's own text plus each operand's
/// widest rendering. A width written in the run-time format can still ask
/// for more (E1011).
pub fn rtFormatCap(g: *Gen, args: []const Mir.Value) Error!u64 {
    assert(args.len != 0);
    var n: u64 = if (args.len > 0) try cap(g, args[0]) else 0;
    for (args[@min(1, args.len)..]) |a| n +|= switch (g.an.tyOf(g.an.rv(a))) {
        .str => try cap(g, a),
        // %e/%f/%g/%r of f64 (`zCReal`'s body), or 64 binary digits.
        .real, .int => 512,
        .wide => unreachable, // lowering hands a task no wide value: a whole wide `reg` read is E0222
    };
    const c = @max(n, row);
    assert(c >= row);
    return c;
}

/// The `Instance` type of held string `i`: `ZStrHeld` for the `row`, else
/// `ZStrHeldN(cap)`.
pub fn emitHeldType(g: *Gen, i: usize) Error!void {
    assert(i < g.lowered.held_vars.items.len);
    assert(g.lowered.held_vars.items[i].ty == .string);
    const c = try heldCap(g, i);
    const len_before = g.out.items.len;
    if (c == row) try g.w("ZStrHeld", .{}) else try g.w("ZStrHeldN({d})", .{c});
    assert(g.out.items.len >= len_before + "ZStrHeld".len);
}

/// The call that copies text into held string `i`'s type: `zStrHeld(` or
/// `zStrHeldN(cap, `; the caller writes the text and the `)`.
pub fn emitHeldCopy(g: *Gen, i: usize) Error!void {
    assert(i < g.lowered.held_vars.items.len);
    assert(g.lowered.held_vars.items[i].ty == .string);
    const c = try heldCap(g, i);
    const len_before = g.out.items.len;
    if (c == row) try g.w("zStrHeld(", .{}) else try g.w("zStrHeldN({d}, ", .{c});
    assert(g.out.items.len >= len_before + "zStrHeld(".len);
}

// ---- private ----

/// The Values `compute(v)` asks `cap` about, in its order, so `cap` can size
/// them first. A `$sformat` operand is left to `compute` itself, which finds
/// it through the format (`cg_display.siteCap`): that call recurses once per
/// nested `$sformat`.
fn readsOf(g: *Gen, v: Mir.Value, out: *std.ArrayList(Mir.Value)) Error!void {
    assert(out.items.len == 0);
    const inst = switch (g.mir.valueDef(v)) {
        .inst_result => |i| i,
        .str_const, .undef, .float_const, .int_const, .param_ref, .block_param => return,
    };
    switch (g.mir.instData(inst)) {
        .phi => |d| for (0..d.count) |i| try out.append(g.gpa, g.mir.phiPair(inst, @intCast(i)).value),
        .ternary => |t| try out.appendSlice(g.gpa, &.{ t.then_val, t.else_val }),
        .call => |c| switch (c.callee) {
            .@"$sformat$rt" => for (c.args, 0..) |a, i| {
                if (i == 0 or g.an.tyOf(g.an.rv(a)) == .str) try out.append(g.gpa, a);
            },
            .@"$str$cat" => try out.appendSlice(g.gpa, c.args),
            .@"$str$repeat" => {
                assert(c.args.len == 2); // `callCap`'s (copies, string)
                if (g.an.foldConst(c.args[0], false) != null) try out.append(g.gpa, c.args[1]);
            },
            .@"$sscanf$str" => if (c.args.len > 0) try out.append(g.gpa, c.args[0]),
            else => {}, // else: `callCap` reads no other capacity through `cap`
        },
        .unary, .binary, .branch, .jump, .anew, .load, .store => {},
    }
}

fn compute(g: *Gen, v: Mir.Value) Error!u64 {
    // `cap` memoizes `row` for `v` before it opens it here.
    assert(g.str_caps.contains(v));
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
    assert(args.len <= std.math.maxInt(u32));
    switch (c) {
        .@"$sformat" => {
            var fmt: std.ArrayList(u8) = .empty;
            var ops: cg_display.Ops = .empty;
            try cg_display.buildArgs(g, args, &fmt, &ops);
            const n = try cg_display.siteCap(g, fmt.items, ops.items);
            assert(n >= row);
            return n;
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
            const copies = std.math.lossyCast(u64, @max(k, 0));
            return @max(copies *| try cap(g, args[1]), row);
        },
        .@"$held_str" => return heldCap(g, gen_call.heldIdx(g, args)),
        // §9.5.4.2 an item is a slice of the input string.
        .@"$sscanf$str" => return if (args.len > 0) cap(g, args[0]) else 0,
        .@"$ferror$str" => return ferror_max,
        else => return row, // else: a file line or item, a `$plusargs` or `$simparam` string, an array element: run-time lengths
    }
}

/// The capacity of §5.10 held string `i` (`Lowered.held_vars` row): what its
/// end-of-block value can hold, never below `row`. Asserts that the planned
/// capacities have one row per `held_vars` row. A held string's value may
/// read held strings (itself, through `$held_str`), so the capacities are
/// solved together, each round reading the last round's; a model whose string
/// grows by itself every step does not settle, and keeps the capacity the
/// last round gave (E1011 when it outgrows it).
fn heldCap(g: *Gen, i: usize) Error!u64 {
    assert(i < g.lowered.held_vars.items.len);
    if (g.held_caps == null) try planHeld(g);
    const caps = g.held_caps.?;
    assert(caps.len == g.lowered.held_vars.items.len);
    const c = if (i < caps.len) caps[i] else row;
    assert(c >= row);
    return c;
}

fn planHeld(g: *Gen) Error!void {
    assert(g.held_caps == null);
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
    assert(round <= held.len + 1);
    for (caps) |c| assert(c >= row);
    g.str_caps.clearRetainingCapacity();
}

fn initLen(g: *Gen, init: Mir.Value) u64 {
    return switch (g.mir.valueDef(g.an.rv(init))) {
        .str_const => |s| s.len,
        .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => 0,
    };
}
