const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_table_model = @import("table_model.zig");
const lower_analog_op = @import("analog_op.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;

/// Lowers a §4.6.4 noise source call. It contributes only in a small-signal noise
/// analysis; codegen decides that from the call name (the value is 0 in DC).
pub fn lowerNoise(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    // VerA's `vera_timepoint` (§2.9): a source is a stamp, not a value.
    if (self.tp_cur != null) {
        try self.err(ex.mainTok(e), .E0530, "the noise function `{s}` (§4.6.4)", .{name});
        return poison;
    }
    // A.8.2 analog_small_signal_function_call brackets only trailing optional
    // arguments; no form has an `_or_null` slot, so an empty one has no meaning.
    for (ex.args(e)) |a| if (a == .none) {
        try self.err(ex.mainTok(e), .E0505, "`{s}()` (A.8.2 gives the small-signal functions no empty slot)", .{name});
        return poison;
    };
    // A.8.2 `ac_stim ( [ " analysis_identifier " [ , analog_expression ...`:
    // the quotation marks are in the production, so the analysis name is a
    // string literal.
    if (std.mem.eql(u8, name, "ac_stim")) if (ex.args(e).len != 0) {
        const a0 = ex.args(e)[0];
        if (a0 != .none and ex.tag(a0) != .str_literal) {
            try self.err(ex.mainTok(a0), .E0521, "", .{});
            return poison;
        }
        // A name that is not a Table 4-21 small-signal kind matches the
        // analysis the host labels with it (`contract.acStimActive`, VD-109),
        // so the device reads the host's Table 9-28 `analysis_name`.
        if (a0 != .none) {
            const s = self.file.str(ex.strOf(a0));
            if (!std.mem.eql(u8, s, "ac") and !std.mem.eql(u8, s, "noise")) self.out.uses.insert(.host_strings);
        }
    };
    // Syntax 4-4 `flicker_noise ( analog_expression , analog_expression
    // [ , string ] )`: only the name is bracketed. §4.6.4.2's "1/f^exp" has no
    // default exponent, so a one-argument call has no spectrum to invent.
    if (std.mem.eql(u8, name, "flicker_noise")) {
        var n: usize = 0;
        for (ex.args(e)) |a| n += @intFromBool(a != .none);
        if (n < 2) {
            try self.err(ex.mainTok(e), .E0522, "got {d} argument(s)", .{n});
            return poison;
        }
    }
    // Syntax 4-4: each noise function's optional last argument is `string`,
    // §4.6.4.1's "name argument [that] acts as a label for the noise source".
    const label_at: ?usize = if (std.mem.eql(u8, name, "white_noise") or
        std.mem.eql(u8, name, "noise_table") or std.mem.eql(u8, name, "noise_table_log"))
        1
    else if (std.mem.eql(u8, name, "flicker_noise"))
        2
    else
        null;
    if (label_at) |li| if (ex.args(e).len > li and ex.args(e)[li] != .none) {
        const a = ex.args(e)[li];
        const c = lower_constfold.constEval(self, a);
        if (c == null or c.? != .str) {
            try self.err(ex.mainTok(a), .E0573, "`{s}()` argument {d} is its label", .{ name, li + 1 });
            return poison;
        }
    };
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    // §4.6.4 the PSD arguments, positionally: arg 0 is the power, arg 1 of
    // `flicker_noise` is the exponent. Recorded here, the only place the call's
    // arguments are lowered. The seeds are §4.6.3's `ac_stim` defaults: "The
    // default magnitude is one (1) and the default phase is zero (0)".
    var psd: [2]Mir.Value = if (std.mem.eql(u8, name, "ac_stim"))
        .{ .f_one, .f_zero }
    else
        .{ .f_zero, .f_one };
    var reals: usize = 0;
    // §4.6.4.3/.4 the table itself: `appendVectorArg` writes the count, then the
    // elements, so the pairs are the slice after the count.
    var tab: ?struct { usize, usize } = null;
    // A.8.2's `noise_table_input_arg` is argument 0 of `noise_table`/
    // `noise_table_log` only; every other form's trailing `string` is a label.
    const table_input = std.mem.eql(u8, name, "noise_table") or
        std.mem.eql(u8, name, "noise_table_log");
    for (ex.args(e), 0..) |a, ai| {
        if (a == .none) continue;
        const at = vals.items.len;
        // §4.6.4.3's FILE form of the input: "When the input is a file name,
        // the indicated file will contain the frequency / power pairs. The
        // file name argument shall be constant". So the pairs are compile-time
        // data and land in the same slot the vector form fills.
        if (table_input and ai == 0) if (lower_constfold.constEval(self, a)) |c| if (c == .str) {
            if (try lower_table_model.readNoiseTableFile(self, e, c.str)) |pairs| {
                try vals.append(self.arena, try self.mir.addIntConst(self.arena, @intCast(pairs.len)));
                for (pairs) |x| try vals.append(self.arena, try self.mir.addFloatConst(self.arena, x));
                if (tab == null) tab = .{ at + 1, vals.items.len };
            }
            continue;
        };
        // The same slot is the only one a vector belongs in: anywhere else a
        // pattern or an array is an ordinary operand, which `lowerExpr` judges.
        if (table_input and ai == 0 and try lower_analog_op.appendVectorArg(self, &vals, a)) {
            // Indices, not a slice: `vals` keeps growing and may reallocate.
            if (tab == null) tab = .{ at + 1, vals.items.len };
            continue;
        }
        const tv = try lower_expr.lowerExpr(self, a);
        if (tv.ty == .string) {
            try vals.append(self.arena, tv.v);
            continue;
        }
        const rv = try self.toReal(tv);
        if (reals < 2) psd[reals] = rv;
        reals += 1;
        try vals.append(self.arena, rv);
    }
    // §4.6.4.1 `white_noise(pwr[, name])` has one real argument, so its `.f_one`
    // exponent seed is never read as a spectrum; `flicker_noise` always
    // overwrites it (E0522 above refuses the call that would not).
    try self.noise_psd.put(self.arena, @backingInt(e), psd);
    if (tab) |r| try self.noise_tab.put(
        self.arena,
        @backingInt(e),
        try self.arena.dupe(Mir.Value, vals.items[r[0]..r[1]]),
    );
    const result = try self.call(name, vals.items);
    try self.noise_val.put(self.arena, @backingInt(e), result);
    return .{ .v = result, .ty = .real };
}

/// A §4.6.4.6 noise coefficient, `∂contribution/∂generator`. A noise function is an
/// amplitude combined linearly, so for correlated noise ("the output of one noise
/// function for more than one noise source") the derivative is the constant factor
/// the branch applies to it:
///   absent     the generator does not occur here, so its coefficient is 0 and
///              this statement adds nothing to the branch's total;
///   nonlinear  it occurs in a shape no single factor describes (squared, in a
///              denominator, inside a call), so there is no coefficient;
///   value      the factor.
const Coeff = union(enum) { absent, nonlinear, value: Mir.Value };

/// Returns `-v`, folded when `v` is a literal so the coefficient renders inline in
/// `noisePsd` instead of taking a core live-out slot.
pub fn coeffNeg(self: *Lower, v: Mir.Value) Oom!Mir.Value {
    assert(self.valueValid(v));
    assert(self.blockValid(self.cur));
    if (self.mir.valueDef(self.mir.resolveAlias(v)) == .float_const)
        return self.mir.addFloatConst(self.arena, -self.mir.valueDef(self.mir.resolveAlias(v)).float_const);
    return self.emit(.fneg, &.{v});
}

/// `a · b`, with the identity folded away. The derivative of `c * n` is
/// `c * 1`, and emitting that multiply would hide the constant from
/// `psdConst`.
fn coeffMul(self: *Lower, a: Mir.Value, b: Mir.Value) Oom!Mir.Value {
    assert(self.valueValid(a));
    assert(self.valueValid(b));
    assert(self.blockValid(self.cur));
    if (a == .f_one) return b;
    if (b == .f_one) return a;
    return self.emit(.fmul, &.{ a, b });
}

/// Returns the coefficient of generator `n` in contribution value `v`, emitting the
/// few arithmetic nodes it needs over values the MIR already holds (no re-lowering,
/// so no side effect repeats).
pub fn noiseCoeff(self: *Lower, v: Mir.Value, n: Mir.Value) Oom!Coeff {
    assert(self.valueValid(v));
    assert(self.valueValid(n));
    const gen = self.mir.resolveAlias(n);
    var reach = try reachOf(self, gen, v);
    defer reach.deinit(self.arena);
    return coeffAt(self, v, gen, &reach, 0, null);
}

/// The Values of `v`'s cone whose operands, along the edges `coeffAt` follows,
/// lead to `gen`: off this set the walk answers `.absent` without descending, so
/// its cost is the generator-bearing paths and not every path of the DAG. An
/// unsealed phi (no operands yet) is kept in, since what it will carry is
/// unknown. Indexed by `@backingInt(value)`. O(cone) per fixpoint pass, not
/// O(values): a module of n noisy `<+` would otherwise lower in O(n²).
fn reachOf(self: *Lower, gen: Mir.Value, v: Mir.Value) Oom!std.bit_set.Dynamic {
    assert(self.valueValid(gen));
    assert(self.valueValid(v));
    const mir = self.mir;
    const n = Mir.Value.first_dynamic + mir.defs.len;
    var reach = try std.bit_set.Dynamic.initEmpty(self.arena, n);
    errdefer reach.deinit(self.arena);
    reach.set(@backingInt(gen));
    // The cone: every instruction result `v`'s operand edges lead to, phis'
    // back edges included, which is all `coeffAt` can visit.
    var seen = try std.bit_set.Dynamic.initEmpty(self.arena, n);
    defer seen.deinit(self.arena);
    var cone: std.ArrayList(Mir.Value) = .empty;
    defer cone.deinit(self.arena);
    var stack: std.ArrayList(Mir.Value) = .empty;
    defer stack.deinit(self.arena);
    try stack.append(self.arena, mir.resolveAlias(v));
    while (stack.pop()) |x| {
        if (seen.isSet(@backingInt(x))) continue;
        seen.set(@backingInt(x));
        const inst = switch (mir.valueDef(x)) {
            .inst_result => |i| i,
            .undef, .float_const, .int_const, .str_const, .param_ref, .block_param => continue,
        };
        try cone.append(self.arena, x);
        switch (mir.instData(inst)) {
            .unary => |u| try stack.append(self.arena, mir.resolveAlias(u.operand)),
            .binary => |bn| try stack.appendSlice(self.arena, &.{ mir.resolveAlias(bn.lhs), mir.resolveAlias(bn.rhs) }),
            .ternary => |t| try stack.appendSlice(self.arena, &.{ mir.resolveAlias(t.then_val), mir.resolveAlias(t.else_val) }),
            .phi => |p| for (0..p.count) |k| try stack.append(self.arena, mir.resolveAlias(mir.phiPair(inst, @intCast(k)).value)),
            .call => |c| for (c.args) |arg| try stack.append(self.arena, mir.resolveAlias(arg)),
            .anew, .branch, .jump => {},
            .load => |l| try stack.appendSlice(self.arena, &.{ mir.resolveAlias(l.arr), mir.resolveAlias(l.index) }),
            .store => |st| try stack.appendSlice(self.arena, &.{ mir.resolveAlias(st.arr), mir.resolveAlias(st.index), mir.resolveAlias(st.value) }),
        }
    }
    // Operands precede their users except along a phi's back edge or an
    // alias onto a later value; those need another pass.
    std.mem.sortUnstable(Mir.Value, cone.items, {}, struct {
        fn lt(_: void, l: Mir.Value, r: Mir.Value) bool {
            return @backingInt(l) < @backingInt(r);
        }
    }.lt);
    var changed = true;
    var passes: usize = 0;
    while (changed) : (passes += 1) {
        // Each pass that continues sets a bit, and the cone has that many.
        std.debug.assert(passes <= cone.items.len);
        changed = false;
        for (cone.items) |x| {
            if (reach.isSet(@backingInt(x))) continue;
            if (operandReaches(mir, mir.valueDef(x).inst_result, &reach)) {
                reach.set(@backingInt(x));
                changed = true;
            }
        }
    }
    return reach;
}

fn reached(mir: *const Mir, reach: *const std.bit_set.Dynamic, v: Mir.Value) bool {
    return reach.isSet(@backingInt(mir.resolveAlias(v)));
}

fn operandReaches(mir: *const Mir, inst: Mir.Inst, reach: *const std.bit_set.Dynamic) bool {
    return switch (mir.instData(inst)) {
        .unary => |u| reached(mir, reach, u.operand),
        .binary => |b| reached(mir, reach, b.lhs) or reached(mir, reach, b.rhs),
        // `coeffAt` differentiates the arms; the condition selects, it is not scaled.
        .ternary => |t| reached(mir, reach, t.then_val) or reached(mir, reach, t.else_val),
        .phi => |p| {
            if (p.count == 0) return true;
            for (0..p.count) |k| if (reached(mir, reach, mir.phiPair(inst, @intCast(k)).value)) return true;
            return false;
        },
        .call => |c| {
            for (c.args) |arg| if (reached(mir, reach, arg)) return true;
            return false;
        },
        .anew, .branch, .jump => false,
        .load => |l| reached(mir, reach, l.arr) or reached(mir, reach, l.index),
        .store => |st| reached(mir, reach, st.arr) or reached(mir, reach, st.index) or reached(mir, reach, st.value),
    };
}

/// The phis the walk is inside, innermost first. A loop-header phi reaches
/// itself again through its back edge; meeting one already on the path is a
/// generator fed back into itself, which no single factor describes.
const PhiPath = struct { inst: Mir.Inst, up: ?*const PhiPath };

fn coeffAt(self: *Lower, v: Mir.Value, gen: Mir.Value, reach: *const std.bit_set.Dynamic, depth: u16, path: ?*const PhiPath) Oom!Coeff {
    assert(self.valueValid(v));
    assert(self.valueValid(gen));
    assert(self.blockValid(self.cur));
    if (depth == 64) return .nonlinear;
    const value = self.mir.resolveAlias(v);
    if (value == gen) return .{ .value = .f_one };
    if (!reach.isSet(@backingInt(value))) return .absent;
    const inst = switch (self.mir.valueDef(value)) {
        .inst_result => |i| i,
        // A constant, a parameter or a probe cannot contain the generator.
        .undef, .float_const, .int_const, .str_const, .param_ref, .block_param => return .absent,
    };
    switch (self.mir.instData(inst)) {
        .unary => |u| {
            const d = try coeffAt(self, u.operand, gen, reach, depth + 1, path);
            if (d == .absent) return .absent;
            if (u.op != .fneg or d == .nonlinear) return .nonlinear;
            return .{ .value = try coeffNeg(self, d.value) };
        },
        .binary => |b| {
            const da = try coeffAt(self, b.lhs, gen, reach, depth + 1, path);
            const db = try coeffAt(self, b.rhs, gen, reach, depth + 1, path);
            if (da == .absent and db == .absent) return .absent;
            if (da == .nonlinear or db == .nonlinear) return .nonlinear;
            switch (b.op) {
                .fadd, .fsub => {
                    // A side that does not mention the generator contributes
                    // the zero this skips rather than emits.
                    if (da == .absent) return .{
                        .value = if (b.op == .fadd) db.value else try coeffNeg(self, db.value),
                    };
                    if (db == .absent) return .{ .value = da.value };
                    return .{ .value = try self.emit(if (b.op == .fadd) .fadd else .fsub, &.{ da.value, db.value }) };
                },
                // The generator on both sides of a multiply is the generator
                // squared, which has no coefficient.
                .fmul => {
                    if (da != .absent and db != .absent) return .nonlinear;
                    if (da == .absent) return .{ .value = try coeffMul(self, b.lhs, db.value) };
                    return .{ .value = try coeffMul(self, da.value, b.rhs) };
                },
                // Dividing BY the generator is nonlinear for the same reason.
                .fdiv => {
                    if (db != .absent) return .nonlinear;
                    return .{ .value = try self.emit(.fdiv, &.{ da.value, b.rhs }) };
                },
                // The rest of the two-operand ops: a generator under any of them
                // is no longer an amplitude scaled by a factor (an integer op
                // would have to round it, a comparison or a min/max selects on
                // it, pow/hypot/atan2/fmod are not linear in it).
                .fmod,
                .iadd,
                .isub,
                .imul,
                .idiv,
                .imod,
                .flt,
                .fgt,
                .fle,
                .fge,
                .feq,
                .fne,
                .ilt,
                .igt,
                .ile,
                .ige,
                .ieq,
                .ine,
                .logand,
                .logor,
                .bitand,
                .bitor,
                .bitxor,
                .bitxnor,
                .shl,
                .shr,
                .pow,
                .hypot,
                .fmin,
                .fmax,
                .imin,
                .imax,
                .ipow,
                .atan2,
                => return .nonlinear,
                // `instData` decodes `.binary` only for `opClass(op) == .binary`.
                .fneg,
                .ineg,
                .lognot,
                .bitnot,
                .sqrt,
                .exp,
                .expm1,
                .ln,
                .ln1p,
                .log10,
                .floor,
                .ceil,
                .fabs,
                .iabs,
                .sin,
                .cos,
                .tan,
                .asin,
                .acos,
                .atan,
                .sinh,
                .cosh,
                .tanh,
                .asinh,
                .acosh,
                .atanh,
                .fi_cast,
                .if_cast,
                .opt_barrier,
                .dstop,
                .path_prev,
                .path_acc,
                .select,
                .phi,
                .branch,
                .jump,
                .call,
                .anew,
                .fload,
                .iload,
                .store,
                => unreachable,
            }
        },
        // §4.2.12 `?:`: either arm may carry the generator, and which arm runs
        // is a solve-time question, so the coefficient is the same conditional.
        .ternary => |t| {
            const dy = try coeffAt(self, t.then_val, gen, reach, depth + 1, path);
            const dn = try coeffAt(self, t.else_val, gen, reach, depth + 1, path);
            if (dy == .absent and dn == .absent) return .absent;
            if (dy == .nonlinear or dn == .nonlinear) return .nonlinear;
            return .{ .value = try self.emit(.select, &.{
                t.cond,
                if (dy == .absent) .f_zero else dy.value,
                if (dn == .absent) .f_zero else dn.value,
            }) };
        },
        // §5.8 `if` and §4.2.12 `?:` both arrive here as a CFG diamond (ifconv
        // makes the `.select` later): the coefficient of a phi is the phi of the
        // incoming coefficients.
        .phi => |p| {
            // An unsealed loop header's phi has no operands yet, so nothing is
            // known about what it carries.
            if (p.count == 0) return .nonlinear;
            var up = path;
            while (up) |f| : (up = f.up) if (f.inst == inst) return .nonlinear;
            const here: PhiPath = .{ .inst = inst, .up = path };
            const coeffs = try self.arena.alloc(Mir.PhiPair, p.count);
            var any = false;
            var same = true;
            for (coeffs, 0..) |*c, k| {
                const pair = self.mir.phiPair(inst, @intCast(k));
                const before = self.mir.blockLast(self.cur);
                const d = try coeffAt(self, pair.value, gen, reach, depth + 1, &here);
                // What that walk emitted (`x/r` has coefficient `1/r`) landed in
                // `self.cur`, after the join, where the edge from `pair.block`
                // cannot carry it. Its operands are sub-terms of `pair.value`,
                // so they exist at the end of that block: compute it there.
                if (!self.mir.moveTailBefore(self.cur, before, pair.block)) return .nonlinear;
                const cv: Mir.Value = switch (d) {
                    .absent => .f_zero,
                    .nonlinear => return .nonlinear,
                    .value => |x| blk: {
                        any = true;
                        break :blk x;
                    },
                };
                c.* = .{ .block = pair.block, .value = cv };
                if (cv != coeffs[0].value) same = false;
            }
            if (!any) return .absent;
            // One value on every edge is available at the join already.
            if (same) return .{ .value = coeffs[0].value };
            return .{ .value = try self.mir.emitPhi(self.arena, self.mir.instBlock(inst), coeffs) };
        },
        // A call's arguments are reachable, so whether the generator occurs is
        // answerable even though the derivative is not.
        .call => |c| {
            for (c.args) |arg| if (try coeffAt(self, arg, gen, reach, depth + 1, path) != .absent) return .nonlinear;
            return .absent;
        },
        // Terminators define no value, so no Value resolves to one.
        .branch, .jump => unreachable,
        // §3.2.2 a generator stored into an array is no longer an amplitude
        // scaled by a factor of this expression: like a call's argument, it
        // can only be detected, not differentiated through the storage.
        .anew => return .absent,
        .load => |l| return if (try coeffAt(self, l.arr, gen, reach, depth + 1, path) == .absent and
            try coeffAt(self, l.index, gen, reach, depth + 1, path) == .absent) .absent else .nonlinear,
        .store => |st| return if (try coeffAt(self, st.arr, gen, reach, depth + 1, path) == .absent and
            try coeffAt(self, st.index, gen, reach, depth + 1, path) == .absent and
            try coeffAt(self, st.value, gen, reach, depth + 1, path) == .absent) .absent else .nonlinear,
    }
}

test "§4.6 small-signal sources: arguments and labels" {
    try Lower.expectBodies(&.{
        // §4.6.4.1 `white_noise(pwr[, name])`: the power is a scalar. Only
        // `noise_table`'s input (§4.6.4.3) is a vector.
        .{ .src = "analog I(p) <+ white_noise('{1.0, 2.0});", .code = .E0509 },
        .{ .src = "analog I(p) <+ white_noise(1e-20);", .code = null },
        // Syntax 4-4: the optional last argument is a string label.
        .{ .src = "analog I(p) <+ white_noise(1e-20, 3);", .code = .E0573 },
        // §4.6.4.2: 1/f^exp has no default exponent.
        .{ .src = "analog I(p) <+ flicker_noise(1e-20);", .code = .E0522 },
        // A.8.2 puts the quotation marks inside `ac_stim`'s production.
        .{ .src = "analog I(p) <+ ac_stim(1);", .code = .E0521 },
    });
}
