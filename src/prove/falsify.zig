//! The prover's falsification oracle: random MIR programs in (parameters with
//! §3.4.2 ranges, §4.4 probes, nested `if` diamonds over the math functions,
//! §4.2.12 selects, §9.10/§4.5.13 calls, §3.2.2 arrays and §5.8.3 counted
//! loops), concrete evaluations at sampled points out, with the device's own
//! math (`contract.gm`). It shares none of the prover's reasoning: no interval, no
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
//! outside the contract and is dropped whole (`overflows`). A select's arm
//! that the generator made for it alone runs only when the select takes it,
//! as the device renders it (§4.2.12, lazy); every other row runs where it
//! stands. A host's `$temperature` is positive and `$abstime` non-negative.
//!
//! LRM clauses this file's code cites: §3.2.2, §3.4.2, §4.2.12, §4.3.1,
//! §4.3.2, §4.4, §4.5.13, §5.8.3, §9.10.
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
/// The domain-restricted rows a guarded arm applies to its guard's operand
/// (`if (x > c) ln(x)`), the shape a guard fact exists to prove.
const guarded_ops = [_]Mir.Opcode{ .ln, .log10, .sqrt, .acosh, .ln1p, .asin, .atanh };
const unary_ops = [_]Mir.Opcode{ .exp, .ln, .sqrt, .sin, .cos, .tanh, .atan, .asin, .acos, .atanh, .acosh, .fneg, .fabs, .ln1p, .floor, .log10, .sinh };
const binary_ops = [_]Mir.Opcode{ .fadd, .fsub, .fmul, .fdiv, .pow, .fmin, .fmax, .hypot, .atan2 };
/// The §3.4.2 range shapes a parameter may carry.
const Shape = enum { none, positive_open, one_to_ten, unit_closed, negative, nonzero, unit_open, non_negative };
/// Most values one program defines; the evaluator's table is sized from it.
const values_max = 160;
/// Elements of each generated §3.2.2 array, and most arrays per program.
const array_len = 4;
const arrays_max = 4;
/// Most iterations of a generated loop.
const trips_max = 3;
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
    /// Per phi, the condition of the branch whose arms it joins (§5.8), or
    /// of the loop whose header it is.
    phi_cond: [values_max]Mir.Value = @splat(.undef),
    /// Per row, whether it is a select arm made for that select alone, which
    /// runs only when the select takes it.
    lazy: [values_max]bool = @splat(false),
    out: Mir.Value = .undef,
};

/// What one evaluation saw: the value of every row it executed, every array
/// version's elements, and per row over all its executions (a loop body runs
/// several times): how many, how many inside its domain, whether one saw a
/// non-finite operand or result, and whether a rule-3 row overflowed.
const Run = struct {
    vals: [values_max]f64 = @splat(math.nan(f64)),
    ran: [values_max]bool = @splat(false),
    arrays: [values_max][array_len]f64 = undefined,
    runs: [values_max]u32 = @splat(0),
    inside: [values_max]u32 = @splat(0),
    nonfinite: [values_max]bool = @splat(false),
    overflow: bool = false,
};

/// One sample: the parameters, probes and host state a run reads.
const Point = struct { params: [3]f64, probes: [2]f64, temperature: f64, abstime: f64 };

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
            .non_negative => &.{.{ .kind = .from, .lo = 0, .hi = 10 }},
        };
        try prog.lowered.params.append(a, .{ .name = "p", .ty = .real, .default = .f_one, .ranges = ranges });
        try prog.pool.append(a, try m.addParamRef(a, @intCast(i)));
    }
    for (0..2) |u| try prog.pool.append(a, try m.addBlockParam(a, @intCast(u)));
    for ([_]f64{ 0.0, 1.0, -1.0, 0.5, 2.0 }) |c| try prog.pool.append(a, try m.addFloatConst(a, c));
    var cur: Mir.Block = .entry;
    prog.out = try body(a, r, prog, &cur, 0, null);
    try prog.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .resist_val = prog.out });
    assert(m.valueCount() <= values_max);
}

/// Emits a run of rows into `cur.*`, maybe a diamond, and returns the last
/// value; `cur.*` is the block the run ends in.
/// `guard`, when set, is the operand the enclosing branch compared, on the
/// arm where it is at or above what it was compared to: half the time the
/// run opens with a guarded row on it.
fn body(a: Allocator, r: std.Random, prog: *Program, cur: *Mir.Block, depth: u32, guard: ?Mir.Value) !Mir.Value {
    const m = &prog.mir;
    var last = pick(r, prog);
    if (guard) |x| if (r.boolean()) {
        last = try m.emit(a, cur.*, guarded_ops[r.uintLessThan(usize, guarded_ops.len)], &.{x});
        try prog.pool.append(a, last);
    };
    for (0..1 + r.uintLessThan(u32, 3)) |_| {
        if (prog.pool.items.len + 8 > rows_max + 10 or m.valueCount() + 16 > values_max) break;
        if (depth < 2 and r.uintLessThan(u32, 3) == 0) {
            // `if (x REL c) v = <arm> else v = <arm>`, joined by a phi.
            const x = pick(r, prog);
            // Half the time against zero: the `if (x > 0)` guard idiom.
            const c: Mir.Value = if (r.boolean()) .f_zero else pick(r, prog);
            const gt = r.boolean();
            const cond = try m.emit(a, cur.*, if (gt) .fgt else .flt, &.{ x, c });
            const t = try m.addBlock(a);
            const e = try m.addBlock(a);
            const j = try m.addBlock(a);
            _ = try m.emitBranch(a, cur.*, cond, t, e);
            const scope = prog.pool.items.len;
            var tb = t;
            // The guarded row goes where `x` is at or above `c`.
            const tv = try body(a, r, prog, &tb, depth + 1, if (gt) x else null);
            _ = try m.emitJump(a, tb, j);
            prog.pool.shrinkRetainingCapacity(scope);
            var eb = e;
            const ev = try body(a, r, prog, &eb, depth + 1, if (gt) null else x);
            _ = try m.emitJump(a, eb, j);
            prog.pool.shrinkRetainingCapacity(scope);
            last = try m.emitPhi(a, j, &.{ .{ .block = tb, .value = tv }, .{ .block = eb, .value = ev } });
            prog.phi_cond[@backingInt(last)] = cond;
            cur.* = j;
        } else if (depth < 2 and r.uintLessThan(u32, 8) == 0) {
            last = try loop(a, r, prog, cur);
        } else switch (r.uintLessThan(u32, 8)) {
            0 => last = try select(a, r, prog, cur.*),
            1 => last = try call(a, r, prog, cur.*),
            2 => last = try array(a, r, prog, cur.*),
            3, 4 => last = try m.emit(a, cur.*, unary_ops[r.uintLessThan(usize, unary_ops.len)], &.{pick(r, prog)}),
            else => last = try m.emit(a, cur.*, binary_ops[r.uintLessThan(usize, binary_ops.len)], &.{ pick(r, prog), pick(r, prog) }),
        }
        try prog.pool.append(a, last);
    }
    assert(m.valueCount() <= values_max); // the cap the loop checks
    return last;
}

/// `x REL c ? <arm> : <arm>`. An arm is a pool value or a row made for this
/// select alone (`Program.lazy`), often a guarded row on `x`.
fn select(a: Allocator, r: std.Random, prog: *Program, b: Mir.Block) !Mir.Value {
    const m = &prog.mir;
    const x = pick(r, prog);
    const c: Mir.Value = if (r.boolean()) .f_zero else pick(r, prog);
    const gt = r.boolean();
    const cond = try m.emit(a, b, if (gt) .fgt else .flt, &.{ x, c });
    var arms: [2]Mir.Value = undefined;
    for (&arms, [_]bool{ gt, !gt }) |*arm, at_or_above| arm.* = if (r.uintLessThan(u32, 3) == 0) pick(r, prog) else blk: {
        // A guarded row only where `x` is at or above `c`.
        const v = if (at_or_above and r.boolean())
            try m.emit(a, b, guarded_ops[r.uintLessThan(usize, guarded_ops.len)], &.{x})
        else if (r.boolean())
            try m.emit(a, b, unary_ops[r.uintLessThan(usize, unary_ops.len)], &.{pick(r, prog)})
        else
            try m.emit(a, b, binary_ops[r.uintLessThan(usize, binary_ops.len)], &.{ pick(r, prog), pick(r, prog) });
        prog.lazy[@backingInt(v)] = true;
        break :blk v;
    };
    return m.emit(a, b, .select, &.{ cond, arms[0], arms[1] });
}

/// A call whose range the LRM fixes: §9.10 `$temperature`, `$abstime`,
/// `$vt` with and without its argument, §4.5.13 `limexp`.
fn call(a: Allocator, r: std.Random, prog: *Program, b: Mir.Block) !Mir.Value {
    const m = &prog.mir;
    const names = [_][]const u8{ "$temperature", "$abstime", "$vt", "$vt", "limexp" };
    const k = r.uintLessThan(usize, names.len);
    const args: []const Mir.Value = if (k >= 3) &.{pick(r, prog)} else &.{};
    assert(args.len <= 1);
    return m.emitCall(a, b, try m.internString(a, names[k]), args);
}

/// A fresh §3.2.2 array, one or two stores at literal indices (one may fall
/// outside it), and a load of the last version.
fn array(a: Allocator, r: std.Random, prog: *Program, b: Mir.Block) !Mir.Value {
    const m = &prog.mir;
    if (prog.lowered.mem_arrays.items.len == arrays_max) return pick(r, prog);
    try prog.lowered.mem_arrays.append(a, .{ .name = "arr", .len = array_len, .ty = .real });
    assert(prog.lowered.mem_arrays.items.len <= arrays_max);
    var ver = try m.emitAnew(a, b, @intCast(prog.lowered.mem_arrays.items.len - 1));
    for (0..1 + r.uintLessThan(u32, 2)) |_| {
        const at = try m.addIntConst(a, r.uintLessThan(u32, array_len + 1));
        ver = try m.emit(a, b, .store, &.{ ver, at, pick(r, prog) });
    }
    return m.emit(a, b, .fload, &.{ ver, try m.addIntConst(a, r.uintLessThan(u32, array_len + 1)) });
}

/// `for (i = 0; i < n; i = i + 1) acc = acc OP x;` with `n` a literal up to
/// `trips_max`: a header of two phis, a body, the back edge. `cur.*` ends at
/// the exit block, where `acc` is the result.
fn loop(a: Allocator, r: std.Random, prog: *Program, cur: *Mir.Block) !Mir.Value {
    const m = &prog.mir;
    const h = try m.addBlock(a);
    const body_b = try m.addBlock(a);
    const exit = try m.addBlock(a);
    const init = pick(r, prog);
    const x = pick(r, prog);
    _ = try m.emitJump(a, cur.*, h);
    // The latch values are made in the body; the phis name them once they exist.
    const i = try m.emitPhi(a, h, &.{.{ .block = cur.*, .value = .zero }});
    const acc = try m.emitPhi(a, h, &.{.{ .block = cur.*, .value = init }});
    const trips = try m.addIntConst(a, r.uintLessThan(u32, trips_max + 1));
    const cond = try m.emit(a, h, .ilt, &.{ i, trips });
    _ = try m.emitBranch(a, h, cond, body_b, exit);
    const next = try m.emit(a, body_b, binary_ops[r.uintLessThan(usize, binary_ops.len)], &.{ acc, x });
    const i_next = try m.emit(a, body_b, .iadd, &.{ i, .one });
    _ = try m.emitJump(a, body_b, h);
    try m.setPhiPairs(a, m.valueDef(i).inst_result, &.{ .{ .block = cur.*, .value = .zero }, .{ .block = body_b, .value = i_next } });
    try m.setPhiPairs(a, m.valueDef(acc).inst_result, &.{ .{ .block = cur.*, .value = init }, .{ .block = body_b, .value = next } });
    prog.phi_cond[@backingInt(i)] = cond;
    prog.phi_cond[@backingInt(acc)] = cond;
    cur.* = exit;
    return acc;
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
        .non_negative => &.{ 0, 5e-324, 0.5, 1, 10 },
    };
    return pts[r.uintLessThan(usize, pts.len)];
}

fn samplePoint(r: std.Random, prog: *const Program) Point {
    var pt: Point = undefined;
    for (&pt.params, prog.shapes) |*p, sh| p.* = sampleParam(r, sh);
    pt.probes = .{ sampleProbe(r, prog.bound), sampleProbe(r, prog.bound) };
    // The host contract: a positive absolute temperature, a non-negative time.
    const temps = [_]f64{ 5e-324, 1e-3, 300.15, 1e6, 1e300 };
    const times = [_]f64{ 0, 5e-324, 1e-9, 1, 1e300 };
    pt.temperature = temps[r.uintLessThan(usize, temps.len)];
    pt.abstime = times[r.uintLessThan(usize, times.len)];
    assert(pt.temperature > 0); // the host contract `$vt` relies on
    return pt;
}

fn sampleProbe(r: std.Random, bound: ?f64) f64 {
    if (bound) |b| assert(b > 0);
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
        // The loop counter: small integers, exact in f64.
        .ilt => if (x < y) 1 else 0,
        .iadd => x + y,
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
fn evaluate(prog: *const Program, pt: Point, run: *Run) void {
    const m = &prog.mir;
    assert(m.blockCount() > 0);
    var prev: Mir.Block = .entry;
    var cur: Mir.Block = .entry;
    // Bound: the programs' only cycles are counted loops, each block of one
    // entered at most `trips_max + 1` times per entry of its own.
    for (0..m.blockCount() * (trips_max + 2) * (trips_max + 2)) |_| {
        var next: ?Mir.Block = null;
        // Phis first, as a parallel copy from the edge taken.
        var it = m.blockInsts(cur);
        var copies: [values_max]struct { u32, f64 } = undefined;
        var n_copies: usize = 0;
        while (it.next()) |inst| if (m.instOp(inst) == .phi) {
            const d = m.instData(inst).phi;
            for (0..d.count) |k| {
                const pp = m.phiPair(inst, @intCast(k));
                if (pp.block != prev) continue;
                copies[n_copies] = .{ @backingInt(m.instResult(inst)), value(m, pt, run, pp.value) };
                n_copies += 1;
            }
        };
        for (copies[0..n_copies]) |c| {
            run.vals[c[0]] = c[1];
            run.ran[c[0]] = true;
        }
        it = m.blockInsts(cur);
        while (it.next()) |inst| {
            const res = @backingInt(m.instResult(inst));
            if (prog.lazy[res]) continue; // runs if its select takes it
            switch (m.instData(inst)) {
                .phi => {},
                .branch => |br| next = if (value(m, pt, run, br.cond) != 0) br.then_block else br.else_block,
                .jump => |j| next = j.target,
                .ternary => |t| {
                    const arm = if (value(m, pt, run, t.cond) != 0) t.then_val else t.else_val;
                    if (prog.lazy[@backingInt(arm)]) exec(prog, pt, run, m.valueDef(arm).inst_result);
                    run.vals[res] = value(m, pt, run, arm);
                    run.ran[res] = true;
                },
                .unary, .binary, .call, .anew, .load, .store => exec(prog, pt, run, inst),
            }
        }
        prev = cur;
        cur = next orelse return;
    }
    unreachable; // a counted loop ends within its trips
}

/// Runs one value row, recording its result.
fn exec(prog: *const Program, pt: Point, run: *Run, inst: Mir.Inst) void {
    const m = &prog.mir;
    const res = @backingInt(m.instResult(inst));
    assert(res < values_max);
    switch (m.instData(inst)) {
        .unary => |u| {
            const x = value(m, pt, run, u.operand);
            run.vals[res] = device(u.op, x, 0);
            record(run, res, u.op, x, 0);
        },
        .binary => |b| {
            const x = value(m, pt, run, b.lhs);
            const y = value(m, pt, run, b.rhs);
            run.vals[res] = device(b.op, x, y);
            record(run, res, b.op, x, y);
            // Rule 3: `+ - * /` and `hypot` of finite operands (a nonzero
            // divisor) are taken not to overflow; a sample where one does is
            // outside the contract. A zero divisor is the prover's to see.
            const rule3 = switch (b.op) {
                .fadd, .fsub, .fmul, .fdiv, .hypot => true,
                else => false, // else: every other row is the prover's to bound
            };
            if (rule3 and math.isFinite(x) and math.isFinite(y) and !(b.op == .fdiv and y == 0) and math.isInf(run.vals[res]))
                run.overflow = true;
        },
        .call => |c| run.vals[res] = switch (c.callee) {
            .@"$temperature" => pt.temperature,
            .@"$abstime" => pt.abstime,
            // §9.10 kT/q; with an argument, at that temperature.
            .@"$vt" => (if (c.args.len == 0) pt.temperature else value(m, pt, run, c.args[0])) * 8.617333262145179e-5,
            .limexp => gm.exp(value(m, pt, run, c.args[0])), // VD-121: exp's own text
            else => unreachable, // else: the generator calls only these
        },
        // §3.2: a fresh local array is all zero.
        .anew => run.arrays[res] = @splat(0),
        .store => |st| {
            run.arrays[res] = run.arrays[@backingInt(st.arr)];
            const at = value(m, pt, run, st.index);
            if (at >= 0 and at < array_len) run.arrays[res][@intFromFloat(at)] = value(m, pt, run, st.value);
        },
        // §3.2.2 an index outside the array reads zero.
        .load => |l| {
            const at = value(m, pt, run, l.index);
            run.vals[res] = if (at >= 0 and at < array_len) run.arrays[@backingInt(l.arr)][@intFromFloat(at)] else 0;
        },
        .ternary, .phi, .branch, .jump => unreachable, // `evaluate` runs these itself
    }
    if (m.instOp(inst) == .call) {
        const c = m.instData(inst).call;
        record(run, res, .fneg, if (c.args.len != 0) value(m, pt, run, c.args[0]) else 0, 0);
        run.nonfinite[res] = run.nonfinite[res] or !math.isFinite(run.vals[res]);
    }
    run.ran[res] = true;
}

/// Counts one execution of row `res` (`op` at `x`, `y`, its result already
/// in `vals`).
fn record(run: *Run, res: u32, op: Mir.Opcode, x: f64, y: f64) void {
    run.runs[res] += 1;
    run.inside[res] += @intFromBool(inDomain(op, x, y));
    assert(run.inside[res] <= run.runs[res]);
    const finite = math.isFinite(run.vals[res]) and math.isFinite(x) and math.isFinite(y);
    run.nonfinite[res] = run.nonfinite[res] or !finite;
}

fn value(m: *const Mir, pt: Point, run: *const Run, v: Mir.Value) f64 {
    return switch (m.valueDef(v)) {
        .float_const => |c| c,
        .int_const => |c| @floatFromInt(c),
        .param_ref => |p| pt.params[p],
        .block_param => |u| pt.probes[u],
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
    var stack: [values_max * 8]Mir.Value = undefined;
    var n: usize = 1;
    stack[0] = root;
    while (n > 0) {
        assert(n <= stack.len);
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
            .ternary => |t| {
                stack[n..][0..3].* = .{ t.cond, t.then_val, t.else_val };
                n += 3;
            },
            .call => |c| for (c.args) |arg| {
                stack[n] = arg;
                n += 1;
            },
            .load => |l| {
                stack[n..][0..2].* = .{ l.arr, l.index };
                n += 2;
            },
            .store => |st| {
                stack[n..][0..3].* = .{ st.arr, st.index, st.value };
                n += 3;
            },
            .anew => {},
            .phi => |d| {
                for (0..d.count) |k| {
                    stack[n] = m.phiPair(def.inst_result, @intCast(k)).value;
                    n += 1;
                }
                stack[n] = prog.phi_cond[i];
                n += 1;
            },
            .branch, .jump => unreachable, // a terminator defines no Value
        }
    }
    assert(in[@backingInt(root)]);
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
    assert(v.unit_modes.len == 1); // `build` writes one contribution

    var in_slice: [values_max]bool = undefined;
    slice(&prog, prog.out, &in_slice);
    // Per domain row: executions, and executions inside the domain.
    var domain_row: [values_max]bool = @splat(false);
    for (0..prog.mir.instCount()) |k| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(k));
        domain_row[@backingInt(prog.mir.instResult(inst))] = Mir.opcode.get(prog.mir.instOp(inst)).domain != .all;
    }
    domain_row[0] = false; // terminators define no Value
    var runs: [values_max]u32 = @splat(0);
    var inside: [values_max]u32 = @splat(0);
    for (0..samples_per_program) |_| {
        const pt = samplePoint(r, &prog);
        var run: Run = .{};
        evaluate(&prog, pt, &run);
        if (run.overflow) continue;
        for (0..values_max) |res| {
            if (run.runs[res] == 0) continue;
            runs[res] += run.runs[res];
            inside[res] += run.inside[res];
            if (v.unit_modes[0] != .optimized or !in_slice[res] or !run.nonfinite[res]) continue;
            const op = prog.mir.instOp(prog.mir.valueDef(@fromBackingInt(@intCast(res))).inst_result);
            std.debug.print("falsify round {d}: `{s}` (%{d}) saw a non-finite value in an .optimized unit; point {any} bound {?d}\n", .{ round, @tagName(op), res, pt, prog.bound });
            dump(&prog, &runs, &inside, &bag);
            return error.TestOptimizedUnitNotFinite;
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

test "falsify: no sampled point breaks an .optimized verdict or a domain refusal" {
    // Red on each prover bug of the class it guards, injected and reverted:
    // `fdiv` ignoring a zero divisor, `exp` ignoring overflow, `ln` proven on
    // `x >= 0`, and a false-edge `<` guard that keeps its strictness.
    var prng = std.Random.DefaultPrng.init(0xfa15_1f1e);
    for (0..programs) |round| try checkProgram(std.testing.allocator, prng.random(), round);
}
