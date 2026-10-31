//! The prover's falsification oracle: random MIR programs in (parameters with
//! §3.4.2 ranges, §4.4 probes, nested `if` diamonds over the math functions),
//! concrete evaluations at sampled points out, with the device's own math
//! (`contract.gm`). It shares none of the prover's reasoning: no interval, no
//! guard fact, no congruence class. A verdict it falsifies is a prover bug:
//!   - a unit rated `.optimized` must compute only finite doubles on every
//!     executed row of its slice, operands included (`@setFloatMode
//!     (.optimized)` makes any inf or NaN there undefined behaviour);
//!   - a refused model (E06xx) must hold a domain row that is outside its
//!     Table 4-14/4-15 domain at every sample that runs it.
//! A sample is drawn inside every range the prover was told (the host
//! contract): a parameter within its range, a probe within the bound. Rule 3
//! on `proof.FloatMode` is an axiom, not a proof: `+ - * /` (and `hypot`) on
//! finite operands are taken not to overflow, so a sample where one does is
//! outside the contract and is dropped whole (`overflows`).
//!
//! LRM clauses this file's code cites: §3.4.2, §4.3.1, §4.3.2, §4.4.
//!
//! Contents: none public; test support and tests only.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const diag = @import("diag");
const gm = @import("contract").gm;
const proof = @import("proof.zig");

/// The rows a program may hold; every one has a device spelling below.
const unary_ops = [_]Mir.Opcode{ .exp, .ln, .sqrt, .sin, .cos, .tanh, .atan, .asin, .acos, .atanh, .acosh, .fneg, .fabs, .ln1p, .floor, .log10, .sinh };
const binary_ops = [_]Mir.Opcode{ .fadd, .fsub, .fmul, .fdiv, .pow, .fmin, .fmax, .hypot, .atan2 };
/// The §3.4.2 range shapes a parameter may carry.
const Shape = enum { none, positive_open, one_to_ten, unit_closed, negative, nonzero, unit_open };
/// Most values one program defines; the evaluator's table is sized from it.
const values_max = 128;
/// Rows a program's straight-line runs and arms hold.
const rows_max = 24;
const samples_per_program = 48;
const programs = 400;

/// One random program: its MIR, its `Lowered` and the shapes the sampler
/// honours. Lives in the test's arena.
const Program = struct {
    mir: Mir = .{},
    lowered: Lowered = .{},
    shapes: [3]Shape = undefined,
    bound: ?f64 = null,
    /// Values a later row may read, in definition order. An arm's values
    /// leave it when the arm ends, so every read is dominated by its row.
    pool: std.ArrayList(Mir.Value) = .empty,
    /// Per phi, the condition of the branch whose arms it joins (§5.8).
    phi_cond: [values_max]Mir.Value = @splat(.undef),
    out: Mir.Value = .undef,
};

/// What one evaluation saw: the value of every row it executed.
const Run = struct {
    vals: [values_max]f64 = @splat(math.nan(f64)),
    ran: [values_max]bool = @splat(false),
};

// ---- private ----

fn build(a: Allocator, r: std.Random, prog: *Program) !void {
    const m = &prog.mir;
    _ = try m.addBlock(a);
    for (0..2) |_| try prog.lowered.nodes.append(a, .{ .name = "n", .kind = .net, .disc = "", .dir = .unspecified });
    prog.bound = if (r.boolean()) 10.0 else null;
    for (&prog.shapes, 0..) |*sh, i| {
        sh.* = r.enumValue(Shape);
        const ranges: []const Lowered.Range = switch (sh.*) {
            .none => &.{},
            .positive_open => &.{.{ .kind = .from, .lo = 0, .hi = math.inf(f64), .lo_inclusive = false, .hi_inclusive = false }},
            .one_to_ten => &.{.{ .kind = .from, .lo = 1, .hi = 10 }},
            .unit_closed => &.{.{ .kind = .from, .lo = -1, .hi = 1 }},
            .negative => &.{.{ .kind = .from, .lo = -10, .hi = -1 }},
            .nonzero => &.{.{ .kind = .exclude, .lo = 0, .hi = 0 }},
            .unit_open => &.{.{ .kind = .from, .lo = -1, .hi = 1, .lo_inclusive = false, .hi_inclusive = false }},
        };
        try prog.lowered.params.append(a, .{ .name = "p", .ty = .real, .default = .f_one, .ranges = ranges });
        try prog.pool.append(a, try m.addParamRef(a, @intCast(i)));
    }
    for (0..2) |u| try prog.pool.append(a, try m.addBlockParam(a, @intCast(u)));
    for ([_]f64{ 0.0, 1.0, -1.0, 0.5, 2.0 }) |c| try prog.pool.append(a, try m.addFloatConst(a, c));
    var cur: Mir.Block = .entry;
    prog.out = try body(a, r, prog, &cur, 0);
    try prog.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .resist_val = prog.out });
    assert(m.valueCount() <= values_max);
}

/// Emits a run of rows into `cur.*`, maybe a diamond, and returns the last
/// value; `cur.*` is the block the run ends in.
fn body(a: Allocator, r: std.Random, prog: *Program, cur: *Mir.Block, depth: u32) !Mir.Value {
    const m = &prog.mir;
    var last = pick(r, prog);
    for (0..1 + r.uintLessThan(u32, 3)) |_| {
        if (prog.pool.items.len + 8 > rows_max + 10 or m.valueCount() + 16 > values_max) break;
        if (depth < 2 and r.uintLessThan(u32, 3) == 0) {
            // `if (x REL c) v = <arm> else v = <arm>`, joined by a phi.
            const x = pick(r, prog);
            const c = pick(r, prog);
            const cond = try m.emit(a, cur.*, if (r.boolean()) .fgt else .flt, &.{ x, c });
            const t = try m.addBlock(a);
            const e = try m.addBlock(a);
            const j = try m.addBlock(a);
            _ = try m.emitBranch(a, cur.*, cond, t, e);
            const scope = prog.pool.items.len;
            var tb = t;
            const tv = try body(a, r, prog, &tb, depth + 1);
            _ = try m.emitJump(a, tb, j);
            prog.pool.shrinkRetainingCapacity(scope);
            var eb = e;
            const ev = try body(a, r, prog, &eb, depth + 1);
            _ = try m.emitJump(a, eb, j);
            prog.pool.shrinkRetainingCapacity(scope);
            last = try m.emitPhi(a, j, &.{ .{ .block = tb, .value = tv }, .{ .block = eb, .value = ev } });
            prog.phi_cond[@backingInt(last)] = cond;
            cur.* = j;
        } else if (r.boolean()) {
            last = try m.emit(a, cur.*, unary_ops[r.uintLessThan(usize, unary_ops.len)], &.{pick(r, prog)});
        } else {
            last = try m.emit(a, cur.*, binary_ops[r.uintLessThan(usize, binary_ops.len)], &.{ pick(r, prog), pick(r, prog) });
        }
        try prog.pool.append(a, last);
    }
    return last;
}

fn pick(r: std.Random, prog: *const Program) Mir.Value {
    assert(prog.pool.items.len > 0);
    return prog.pool.items[r.uintLessThan(usize, prog.pool.items.len)];
}

/// A value inside shape `sh`: its ends, points just inside them, and a draw.
fn sampleParam(r: std.Random, sh: Shape) f64 {
    const pts: []const f64 = switch (sh) {
        .none => &.{ -1e300, -800, -5, -1, -0.5, 0, 0.5, 1, 5, 800, 1e300 },
        .positive_open => &.{ 5e-324, 1e-300, 0.5, 1, 5, 800, 1e300 },
        .one_to_ten => &.{ 1, 1.5, 5, 10 },
        .unit_closed => &.{ -1, -0.5, 0, 0.5, 1 },
        .negative => &.{ -10, -5, -1.5, -1 },
        .nonzero => &.{ -1e300, -1, -5e-324, 5e-324, 1, 1e300 },
        .unit_open => &.{ math.nextAfter(f64, -1.0, 0.0), -0.5, 0, 0.5, math.nextAfter(f64, 1.0, 0.0) },
    };
    return pts[r.uintLessThan(usize, pts.len)];
}

fn sampleProbe(r: std.Random, bound: ?f64) f64 {
    const pts: []const f64 = if (bound) |b| &.{ -b, -1, -0.5, 0, 0.5, 1, b } else &.{ -1e300, -800, -1, 0, 1, 800, 1e300 };
    return pts[r.uintLessThan(usize, pts.len)];
}

/// The device's value of a row at its operands.
fn device(op: Mir.Opcode, x: f64, y: f64) f64 {
    return switch (op) {
        .exp => gm.exp(x),
        .ln => gm.log(x),
        .log10 => gm.log10(x),
        .sqrt => @sqrt(x),
        .sin => @sin(x),
        .cos => @cos(x),
        .sinh => math.sinh(x),
        .tanh => math.tanh(x),
        .atan => math.atan(x),
        .asin => math.asin(x),
        .acos => math.acos(x),
        .atanh => gm.atanh(x),
        .acosh => gm.acosh(x),
        .ln1p => math.log1p(x),
        .floor => @floor(x),
        .fneg => -x,
        .fabs => @abs(x),
        .fadd => x + y,
        .fsub => x - y,
        .fmul => x * y,
        .fdiv => x / y,
        .pow => gm.pow(x, y),
        .fmin => if (x < y) x else y,
        .fmax => if (x > y) x else y,
        .hypot => math.hypot(x, y),
        .atan2 => gm.atan2(x, y),
        .flt => if (x < y) 1 else 0,
        .fgt => if (x > y) 1 else 0,
        else => unreachable, // else: the generator emits only the rows above
    };
}

/// Tables 4-14/4-15 written out per row, independent of `Mir.opcode`'s
/// column: whether `(x, y)` is inside the row's domain. Rows without one
/// answer true.
fn inDomain(op: Mir.Opcode, x: f64, y: f64) bool {
    return switch (op) {
        .ln, .log10 => x > 0,
        .sqrt => x >= 0,
        .asin, .acos => -1 <= x and x <= 1,
        .atanh => -1 < x and x < 1,
        .acosh => x >= 1,
        .ln1p => x > -1,
        .pow => x > 0 or (x == 0 and y > 0) or (x < 0 and y == @trunc(y)),
        else => true, // else: every other generated row is total
    };
}

/// Runs the program at one point and records every executed row.
fn evaluate(prog: *const Program, params: [3]f64, probes: [2]f64, run: *Run) void {
    const m = &prog.mir;
    var prev: Mir.Block = .entry;
    var cur: Mir.Block = .entry;
    // Bound: the programs are acyclic, so a walk visits each block once.
    for (0..m.blockCount() + 1) |_| {
        var next: ?Mir.Block = null;
        var it = m.blockInsts(cur);
        while (it.next()) |inst| {
            const res = @backingInt(m.instResult(inst));
            switch (m.instData(inst)) {
                .phi => |d| for (0..d.count) |k| {
                    const pp = m.phiPair(inst, @intCast(k));
                    if (pp.block != prev) continue;
                    run.vals[res] = value(m, params, probes, run, pp.value);
                    run.ran[res] = true;
                },
                .unary => |u| {
                    run.vals[res] = device(u.op, value(m, params, probes, run, u.operand), 0);
                    run.ran[res] = true;
                },
                .binary => |b| {
                    run.vals[res] = device(b.op, value(m, params, probes, run, b.lhs), value(m, params, probes, run, b.rhs));
                    run.ran[res] = true;
                },
                .branch => |br| next = if (value(m, params, probes, run, br.cond) != 0) br.then_block else br.else_block,
                .jump => |j| next = j.target,
                .ternary, .call, .anew, .load, .store => unreachable, // not generated
            }
        }
        prev = cur;
        cur = next orelse return;
    }
    unreachable; // an acyclic program ends within its block count
}

fn value(m: *const Mir, params: [3]f64, probes: [2]f64, run: *const Run, v: Mir.Value) f64 {
    return switch (m.valueDef(v)) {
        .float_const => |c| c,
        .int_const => |c| @floatFromInt(c),
        .param_ref => |p| params[p],
        .block_param => |u| probes[u],
        .inst_result => blk: {
            assert(run.ran[@backingInt(v)]); // SSA: defined before its use
            break :blk run.vals[@backingInt(v)];
        },
        .undef, .str_const => unreachable, // not generated
    };
}

/// The static backward slice of `root`: operands, phi incomings, and the
/// condition of the branch each phi joins (it picks the incoming value).
fn slice(prog: *const Program, root: Mir.Value, in: *[values_max]bool) void {
    const m = &prog.mir;
    @memset(in, false);
    var stack: [values_max * 4]Mir.Value = undefined;
    var n: usize = 1;
    stack[0] = root;
    while (n > 0) {
        n -= 1;
        const v = stack[n];
        const i = @backingInt(v);
        if (in[i]) continue;
        in[i] = true;
        const def = m.valueDef(v);
        if (def != .inst_result) continue;
        switch (m.instData(def.inst_result)) {
            .unary => |u| {
                stack[n] = u.operand;
                n += 1;
            },
            .binary => |b| {
                stack[n..][0..2].* = .{ b.lhs, b.rhs };
                n += 2;
            },
            .phi => |d| {
                for (0..d.count) |k| {
                    stack[n] = m.phiPair(def.inst_result, @intCast(k)).value;
                    n += 1;
                }
                stack[n] = prog.phi_cond[i];
                n += 1;
            },
            else => unreachable, // else: the generator emits no other value row
        }
    }
}

fn checkProgram(gpa: Allocator, r: std.Random, round: usize) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prog: Program = .{};
    try build(a, r, &prog);
    var bag = diag.Bag.init(a);
    const v = try proof.prove(gpa, &prog.mir, &prog.lowered, .{ .unknown_bound = prog.bound }, &bag);
    defer v.deinit(gpa);

    var in_slice: [values_max]bool = undefined;
    slice(&prog, prog.out, &in_slice);
    // Per domain row: executions, and executions inside the domain.
    var runs: [values_max]u32 = @splat(0);
    var inside: [values_max]u32 = @splat(0);
    var domain_row: [values_max]bool = @splat(false);
    for (0..prog.mir.instCount()) |k| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(k));
        domain_row[@backingInt(prog.mir.instResult(inst))] = Mir.opcode.get(prog.mir.instOp(inst)).domain != .all;
    }
    domain_row[0] = false; // terminators define no Value
    for (0..samples_per_program) |_| {
        var params: [3]f64 = undefined;
        for (&params, prog.shapes) |*p, sh| p.* = sampleParam(r, sh);
        const probes: [2]f64 = .{ sampleProbe(r, prog.bound), sampleProbe(r, prog.bound) };
        var run: Run = .{};
        evaluate(&prog, params, probes, &run);
        if (overflows(&prog, params, probes, &run)) continue;
        for (0..prog.mir.instCount()) |k| {
            const inst: Mir.Inst = @fromBackingInt(@intCast(k));
            const res = @backingInt(prog.mir.instResult(inst));
            if (res == 0 or !run.ran[res]) continue;
            const d = prog.mir.instData(inst);
            const x, const y = switch (d) {
                .unary => |u| .{ value(&prog.mir, params, probes, &run, u.operand), 0.0 },
                .binary => |b| .{ value(&prog.mir, params, probes, &run, b.lhs), value(&prog.mir, params, probes, &run, b.rhs) },
                else => continue, // else: a phi computes nothing of its own
            };
            const op = prog.mir.instOp(inst);
            runs[res] += 1;
            inside[res] += @intFromBool(inDomain(op, x, y));
            if (v.unit_modes[0] != .optimized or !in_slice[res]) continue;
            const finite = math.isFinite(run.vals[res]) and math.isFinite(x) and math.isFinite(y);
            if (!finite) {
                std.debug.print("falsify round {d}: `{s}` at ({d}, {d}) = {d} in an .optimized unit; params {any} probes {any} bound {?d}\n", .{ round, @tagName(op), x, y, run.vals[res], params, probes, prog.bound });
                return error.TestOptimizedUnitNotFinite;
            }
        }
    }
    if (v.ok()) return;
    // A refusal needs one domain row outside its domain at every sample
    // that ran it; one never run proves nothing either way.
    for (runs, inside, domain_row) |n, k, d| {
        if (d and (n == 0 or k == 0)) return;
    }
    std.debug.print("falsify round {d}: refused (E06xx), but every domain row ran inside its domain at some sample\n", .{round});
    dump(&prog, &runs, &inside, &bag);
    return error.TestRefusalFalsified;
}

/// Prints a falsified program: its shapes, rows, per-row counts, diagnostics.
fn dump(prog: *const Program, runs: []const u32, inside: []const u32, bag: *const diag.Bag) void {
    const m = &prog.mir;
    std.debug.print("  shapes {any} bound {?d}\n", .{ prog.shapes, prog.bound });
    for (0..m.blockCount()) |bi| {
        std.debug.print("  b{d}:\n", .{bi});
        var it = m.blockInsts(@fromBackingInt(@intCast(bi)));
        while (it.next()) |inst| {
            const res = @backingInt(m.instResult(inst));
            std.debug.print("    %{d} = {s}", .{ res, @tagName(m.instOp(inst)) });
            switch (m.instData(inst)) {
                .unary => |u| std.debug.print(" %{d}", .{@backingInt(u.operand)}),
                .binary => |b| std.debug.print(" %{d} %{d}", .{ @backingInt(b.lhs), @backingInt(b.rhs) }),
                .branch => |b| std.debug.print(" %{d} b{d} b{d}", .{ @backingInt(b.cond), @backingInt(b.then_block), @backingInt(b.else_block) }),
                .jump => |j| std.debug.print(" b{d}", .{@backingInt(j.target)}),
                .phi => |d| for (0..d.count) |k| {
                    const pp = m.phiPair(inst, @intCast(k));
                    std.debug.print(" [b{d}: %{d}]", .{ @backingInt(pp.block), @backingInt(pp.value) });
                },
                else => {}, // else: not generated
            }
            if (res != 0) std.debug.print("   runs {d} inside {d}", .{ runs[res], inside[res] });
            std.debug.print("\n", .{});
        }
    }
    for (0..m.defs.len) |i| {
        const v: Mir.Value = @fromBackingInt(@intCast(i + Mir.Value.first_dynamic));
        switch (m.valueDef(v)) {
            .param_ref => |p| std.debug.print("  %{d} = param {d}\n", .{ @backingInt(v), p }),
            .block_param => |u| std.debug.print("  %{d} = probe {d}\n", .{ @backingInt(v), u }),
            .float_const => |c| std.debug.print("  %{d} = {d}\n", .{ @backingInt(v), c }),
            else => {}, // else: rows are printed above
        }
    }
    for (0..bag.count()) |i| std.debug.print("  diag {s}: {s}\n", .{ @tagName(bag.at(i).code), bag.at(i).message });
}

/// Whether a rule-3 row overflowed at this sample: finite operands (a
/// nonzero divisor), an infinite result. A zero divisor is not an overflow:
/// the prover must see it coming (`Interval.excludesZero`).
fn overflows(prog: *const Program, params: [3]f64, probes: [2]f64, run: *const Run) bool {
    const m = &prog.mir;
    for (0..m.instCount()) |k| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(k));
        const res = @backingInt(m.instResult(inst));
        if (res == 0 or !run.ran[res]) continue;
        const b = switch (m.instData(inst)) {
            .binary => |b| b,
            else => continue, // else: only a binary row is a rule-3 row
        };
        switch (b.op) {
            .fadd, .fsub, .fmul, .fdiv, .hypot => {},
            else => continue, // else: every other row is the prover's to bound
        }
        const x = value(m, params, probes, run, b.lhs);
        const y = value(m, params, probes, run, b.rhs);
        if (!math.isFinite(x) or !math.isFinite(y)) continue;
        if (b.op == .fdiv and y == 0) continue;
        if (math.isInf(run.vals[res])) return true;
    }
    return false;
}

test "falsify: no sampled point breaks an .optimized verdict or a domain refusal" {
    var prng = std.Random.DefaultPrng.init(0xfa15_1f1e);
    for (0..programs) |round| try checkProgram(std.testing.allocator, prng.random(), round);
}
