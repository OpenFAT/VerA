//! One run of the analog block: MIR plus one potential per `nodes` row in,
//! one `Val` per MIR value out. The arithmetic is `Mir.opcode.fold`, the
//! compiler's own constant kernel, so a value here is the value the device
//! computes at that operating point. Cites Verilog-AMS §4.5.7 (`absdelay`),
//! §4.5.8 (`transition`), §4.5.9 (`slew`), §4.5.13 (`limexp`), §5.6.1.2
//! (`ddt` charge), §9.10 (`$temperature`, `$vt`), §3.2.2 (arrays, refused).
//!
//! Contents:
//! - `pub const Val = struct`
//! - `pub const steps_max: u32`
//! - `pub const Error = error{ OutOfMemory, Refused }`
//! - `pub fn init(scratch: Allocator, mir: *const Mir, lw: *const Lowered, volts: []const f64, refusal: *Refusal) Error!Interp`
//! - `pub fn run(in: *Interp) Error!void`
//! - `pub fn get(in: *const Interp, value: Mir.Value) Error!Val`
//! - `pub fn later(a: f64, b: f64) f64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Const = Lowered.Const;
const Refusal = @import("refusal.zig").Refusal;

mir: *const Mir,
lw: *const Lowered,
/// One potential (V) per `nodes` row, read by every probe; NaN is a row with
/// no value, which a probe refuses. The caller rewrites it between runs.
volts: []const f64,
/// One `Val` per MIR value index, meaningful where `written` is set.
vals: []Val,
/// One bit per MIR value index: the current run defined it.
written: std.DynamicBitSetUnmanaged,
/// One block's phi results, read before any is written; reused by every
/// block, so it grows to the largest block's phi count.
phis: std.ArrayList(Phi) = .empty,
scratch: Allocator,
refusal: *Refusal,

/// A MIR value under one assignment: the number, and the longest
/// `transition`/`absdelay` delay (s) on any path into it.
pub const Val = struct { c: Const, d: f64 = 0 };

/// Most blocks one run may enter before it is refused as not finishing.
pub const steps_max: u32 = 1 << 20;

/// Every way `init`, `run` and `get` fail; `refusal` holds the reason of
/// `Refused`.
pub const Error = error{ OutOfMemory, Refused };

const Interp = @This();

const Phi = struct { res: Mir.Value, v: Val };

comptime {
    // `vals` holds one per MIR value: a 24-byte `Const` (16-byte slice
    // payload plus tag) and the delay.
    if (@sizeOf(usize) == 8) assert(@sizeOf(Val) == 32);
}

/// Returns an interpreter over `mir` whose tables live in `scratch`. `volts`
/// has one entry per `lw.nodes` row and must outlive the interpreter.
pub fn init(scratch: Allocator, mir: *const Mir, lw: *const Lowered, volts: []const f64, refusal: *Refusal) Error!Interp {
    assert(volts.len == lw.nodes.len);
    const n_values = mir.valueCount();
    const in: Interp = .{
        .mir = mir,
        .lw = lw,
        .volts = volts,
        .vals = try scratch.alloc(Val, n_values),
        .written = try .initEmpty(scratch, n_values),
        .scratch = scratch,
        .refusal = refusal,
    };
    assert(in.vals.len == in.written.bit_length);
    return in;
}

/// Runs the analog block once from the entry, over the current `volts`.
/// Refuses a phi with no operand for the edge taken, an array access, a
/// read of a value with no static value here, and a run past `steps_max`
/// blocks.
pub fn run(in: *Interp) Error!void {
    const mir = in.mir;
    assert(in.vals.len == mir.valueCount());
    assert(in.volts.len == in.lw.nodes.len);
    in.written.unsetAll();
    var block: Mir.Block = .entry;
    var prev: ?Mir.Block = null;
    var steps: u32 = 0;
    while (true) : (steps += 1) {
        if (steps >= steps_max) return in.refusal.raise(.no_finish);
        // Phis read the edge just taken, all at once (they are parallel),
        // wherever each sits in the chain (`ssa.zig` mints them anywhere):
        // every operand is read before any result is written.
        in.phis.clearRetainingCapacity();
        var it = mir.blockInsts(block);
        while (it.next()) |inst| {
            if (mir.instOp(inst) != .phi) continue;
            const from = prev orelse return in.refusal.raise(.phi_no_edge);
            const operand = mir.phiIn(inst, from) orelse return in.refusal.raise(.phi_no_edge);
            try in.phis.append(in.scratch, .{ .res = mir.instResult(inst), .v = try in.get(operand) });
        }
        for (in.phis.items) |p| in.put(p.res, p.v);
        // Then every other row in chain order, and the terminator last:
        // `Mir` allows rows after it, which codegen emits before it.
        var term: ?Mir.Inst = null;
        it = mir.blockInsts(block);
        while (it.next()) |inst| {
            const v: Val = switch (mir.instData(inst)) {
                // §5.6.1.2 `A*ddt(B)` is charged as path_acc + A·(B - path_prev(B)):
                // with both latches at 0 the charge is A·B, whose secant is A·ΔB.
                .unary => |u| if (u.op == .path_prev or u.op == .path_acc) .{ .c = .{ .real = 0 } } else try in.op(u.op, &.{u.operand}),
                .binary => |b| try in.op(b.op, &.{ b.lhs, b.rhs }),
                .ternary => |t| try in.get(if ((try in.get(t.cond)).c.isTrue()) t.then_val else t.else_val),
                .phi => continue,
                .branch, .jump => {
                    term = inst;
                    continue;
                },
                .call => |c| try in.call(c.callee, c.name, c.args),
                .anew, .load, .store => return in.refusal.raise(.runtime_array),
            };
            in.put(mir.instResult(inst), v);
        }
        const last = term orelse return;
        prev = block;
        block = switch (mir.instData(last)) {
            .branch => |b| if ((try in.get(b.cond)).c.isTrue()) b.then_block else b.else_block,
            .jump => |j| j.target,
            .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => unreachable,
        };
    }
}

/// Returns `value` in the current run. Refuses a probe of a row with no
/// potential, a value whose block has not run, and `Mir.Value.undef`.
pub fn get(in: *const Interp, value: Mir.Value) Error!Val {
    const mir = in.mir;
    var v = mir.resolveAlias(value);
    // A parameter's default may be another parameter: follow the chain,
    // which lowering leaves acyclic.
    var hops: usize = 0;
    while (true) : (hops += 1) {
        assert(hops <= in.lw.params.items.len);
        switch (mir.valueDef(v)) {
            .float_const => |x| return .{ .c = .{ .real = x } },
            .int_const => |x| return .{ .c = .{ .int = x } },
            .str_const => |s| return .{ .c = .{ .str = s } },
            .param_ref => |p| {
                const info = in.lw.params.items[p];
                if (info.folded) |c| return .{ .c = c };
                v = mir.resolveAlias(info.default);
            },
            .block_param => |u| {
                assert(u < in.volts.len);
                const x = in.volts[u];
                if (std.math.isNan(x)) return in.refusal.raise(.{ .unknown_net = in.lw.nodes.items(.name)[u] });
                return .{ .c = .{ .real = x } };
            },
            .inst_result => {
                const i = @backingInt(v);
                if (!in.written.isSet(i)) return in.refusal.raise(.read_before_run);
                return in.vals[i];
            },
            .undef => return in.refusal.raise(.undefined_value),
        }
    }
}

/// Returns the later of two delays, NaN if either is: `@max` returns the
/// other operand of a NaN, which would drop a NaN `td` to 0 ns and print it
/// (#47).
pub fn later(a: f64, b: f64) f64 {
    return if (std.math.isNan(a) or std.math.isNan(b)) std.math.nan(f64) else @max(a, b);
}

// ---- private ----

fn put(in: *Interp, res: Mir.Value, v: Val) void {
    if (res == .undef) return;
    const i = @backingInt(res);
    assert(i >= Mir.Value.first_dynamic);
    in.vals[i] = v;
    in.written.set(i);
}

fn op(in: *Interp, o: Mir.Opcode, operands: []const Mir.Value) Error!Val {
    var cs: [2]Const = undefined;
    // `run` passes a unary's or a binary's operands.
    assert(operands.len > 0);
    assert(operands.len <= cs.len);
    var d: f64 = 0;
    for (operands, 0..) |x, i| {
        const v = try in.get(x);
        cs[i] = v.c;
        d = later(d, v.d);
    }
    const c = Mir.opcode.fold(o, cs[0..operands.len]) orelse
        return in.refusal.raise(.{ .no_value = Mir.opcode.label(o) });
    return .{ .c = c, .d = d };
}

fn call(in: *Interp, callee: Mir.Callee, name: []const u8, args: []const Mir.Value) Error!Val {
    return switch (callee) {
        // §4.5.8/§4.5.7: the settled value, `td` later.
        .transition, .absdelay, .@"absdelay$quad" => blk: {
            assert(args.len > 0);
            const x = try in.get(args[0]);
            const td = if (args.len > 1) (try in.get(args[1])).c.asReal() else 0;
            // A NaN td stays NaN (`@max` would drop it to 0) so `settle`
            // refuses it; `later` carries it through every operator.
            break :blk .{ .c = x.c, .d = x.d + if (std.math.isNan(td)) td else @max(td, 0) };
        },
        // §4.5.9: the settled value; a slew's time depends on the swing.
        .slew => blk: {
            assert(args.len > 0);
            break :blk in.get(args[0]);
        },
        .limexp => blk: {
            assert(args.len > 0);
            const x = try in.get(args[0]);
            break :blk .{ .c = .{ .real = @exp(x.c.asReal()) }, .d = x.d };
        },
        // A transient's point, not its DC solve.
        .@"op$static" => .{ .c = .{ .int = 0 } },
        .@"$mfactor" => .{ .c = .{ .real = 1 } },
        .@"$temperature" => .{ .c = .{ .real = 300.15 } },
        .@"$vt" => blk: {
            const t = if (args.len > 0) (try in.get(args[0])).c.asReal() else 300.15;
            break :blk .{ .c = .{ .real = 1.380649e-23 * t / 1.602176634e-19 } };
        },
        // Every other callee is time-dependent, an event, a noise or host
        // query, or a task: none has one static value per assignment.
        else => in.refusal.raise(.{ .not_static = name }), // else: a new callee is refused until it is given a static value here
    };
}

test later {
    // #47: a NaN on either side survives; otherwise the larger delay.
    try std.testing.expect(std.math.isNan(later(std.math.nan(f64), 1)));
    try std.testing.expect(std.math.isNan(later(1, std.math.nan(f64))));
    try std.testing.expectEqual(@as(f64, 2e-9), later(2e-9, 1e-9));
    try std.testing.expectEqual(std.math.inf(f64), later(0, std.math.inf(f64)));
}
