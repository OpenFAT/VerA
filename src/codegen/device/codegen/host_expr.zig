//! A parameter or control-argument expression -> its plain `f64`/`i64` Zig
//! spelling over `model.<p>` leaves: what the host evaluates outside `S`
//! (`derive`, dependent defaults, §4.5 control arguments, small-signal
//! tables), and the nvptx-safe form a unit body may inline. Never looks
//! through a parameter's default, because the host overrides parameters.
//! Where the LRM requires a constant expression and the value is a solve
//! result, `f64Expr` refuses with E0515.
//! LRM: §3.2, §3.4.6, §4.5, §4.5.14, §6.3.4, §9.14, §9.15, Table 3-3.

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_file = @import("file.zig");
const gen_render = @import("render.zig");
const gen_setup = @import("setup.zig");
const gen_unit = @import("unit.zig");
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;
const opcode_zig = codegen.opcode_zig;

/// Returns `inst` as a ternary: the optimizer's select, or a pure two-way CFG
/// merge rebuilt from its phi. Null for loop-carried or multiway phis and
/// for arms containing a call.
fn hostConditional(self: *const Gen, inst: Mir.Inst) ?Mir.InstData {
    if (self.mir.instOp(inst) == .select) return self.mir.instData(inst);
    if (self.mir.instOp(inst) != .phi or self.mir.instData(inst).phi.count != 2) return null;
    const join = self.an.def_block[@backingInt(self.mir.instResult(inst))];
    if (join == none_u32) return null;
    const header = self.an.idom[join];
    if (header == none_u32 or header == join) return null;
    assert(join < self.an.nb);
    assert(header < self.an.nb);
    // SSA may append a phi after the terminator; Analysis already records
    // the actual branch independently of its position in the chain.
    const last = self.an.term[header];
    if (last == .none or self.mir.instOp(last) != .branch) return null;
    const branch = self.mir.instData(last).branch;
    var arms: [2]Mir.Value = undefined;
    inline for (.{ branch.then_block, branch.else_block }, 0..) |arm, i| {
        var found = false;
        for (0..2) |k| {
            const pair = self.mir.phiPair(inst, @intCast(k));
            const matches = if (@backingInt(arm) == join)
                @backingInt(pair.block) == header
            else
                self.an.dominates(@backingInt(arm), @backingInt(pair.block));
            if (matches) {
                if (found) return null;
                arms[i] = pair.value;
                found = true;
            }
        }
        if (!found) return null;
    }
    // Two pairs, each claimed by exactly one arm.
    assert(self.mir.instData(inst).phi.count == 2);
    // Value-only rendering must not lose calls or effects from an arm.
    for (0..self.an.nb) |bi| {
        const block_index: u32 = @intCast(bi);
        if (block_index == header or !self.an.dominates(header, block_index) or self.an.dominates(join, block_index)) continue;
        for (self.an.blockInstsFlat(block_index)) |op|
            if (self.mir.instOp(op) == .call) return null;
    }
    return .{ .ternary = .{ .cond = branch.cond, .then_val = arms[0], .else_val = arms[1] } };
}

fn hostConditionalExpr(self: *Gen, inst: Mir.Inst, depth: u32, ty: VTy) Error!?[]const u8 {
    const d = (hostConditional(self, inst) orelse return null).ternary;
    const condition = try i64Const(self, d.cond, depth + 1) orelse return null;
    const yes = (if (ty == .int) try i64Const(self, d.then_val, depth + 1) else try f64Const(self, d.then_val, depth + 1, false)) orelse return null;
    const no = (if (ty == .int) try i64Const(self, d.else_val, depth + 1) else try f64Const(self, d.else_val, depth + 1, false)) orelse return null;
    return try self.arena.print("@as({s}, if (({s}) != 0) ({s}) else ({s}))", .{ if (ty == .int) "i64" else "f64", condition, yes, no });
}

/// Returns a host-side `[]const u8` for a string operand: the literal, or the
/// model field of a §3.4.6 string parameter. Null for anything else, which is
/// how `i64Const` tells a string comparison from arithmetic.
fn strConst(self: *Gen, v0: Mir.Value) Error!?[]const u8 {
    switch (self.mir.valueDef(self.an.rv(v0))) {
        .str_const => |s| return try self.arena.print("\"{f}\"", .{std.zig.fmtString(s)}),
        .param_ref => |p| {
            if (Analysis.tyOfParam(self.lowered.params.items[p].ty) != .str) return null;
            self.uses.model = true;
            return try self.arena.print("model.{s}", .{self.names.p_names[p]});
        },
        .undef, .float_const, .int_const, .block_param, .inst_result => return null,
    }
}

/// Returns a plain-i64 host expression for an integer parameter expression,
/// or null when `v` has none. Keeps integral bits beyond f64's exact range
/// and applies the MIR's 32-bit integer arithmetic rules.
pub fn i64Const(self: *Gen, v0: Mir.Value, depth: u32) Error!?[]const u8 {
    if (depth > 32) return null;
    const v = self.an.rv(v0);
    switch (self.mir.valueDef(v)) {
        .int_const => |n| return try self.arena.print("@as(i64, {d})", .{n}),
        .float_const => |n| return try self.arena.print("@as(i64, {d})", .{std.math.lossyCast(i64, @round(n))}),
        .param_ref => |p| {
            if (Analysis.tyOfParam(self.lowered.params.items[p].ty) == .str) return null;
            self.uses.model = true;
            return switch (Analysis.tyOfParam(self.lowered.params.items[p].ty)) {
                .int => try self.arena.print("@as(i64, model.{s})", .{self.names.p_names[p]}),
                .real => try self.arena.print("std.math.lossyCast(i64, @round(model.{s}))", .{self.names.p_names[p]}),
                .str => unreachable,
                .wide => unreachable, // `tyOfParam` types no parameter wide
            };
        },
        .inst_result => |inst| {
            const row = self.mir.instRow(inst);
            const av: Mir.Value = @fromBackingInt(@intCast(row.a));
            const bv: Mir.Value = @fromBackingInt(@intCast(row.b));
            if (self.an.tyOf(v) == .real or row.op == .fi_cast) {
                const f = try f64Const(self, if (row.op == .fi_cast) av else v, depth + 1, false) orelse return null;
                return try self.arena.print("std.math.lossyCast(i64, @round({s}))", .{f});
            }
            if (row.op == .select or row.op == .phi) return hostConditionalExpr(self, inst, depth, .int);
            // §9.14 `$clog2` is a constant system function, so a §6.3.4
            // dependent default may call it over an overridable parameter.
            if (row.op == .call) {
                const d = self.mir.instData(inst).call;
                // `lowerClog2` asks whether the card set a parameter (VD-089).
                if (d.callee == .@"$param_given") {
                    const def = if (d.args.len > 0) self.mir.valueDef(self.an.rv(d.args[0])) else Mir.Def.undef;
                    if (def != .param_ref) return "@as(i64, 0)";
                    self.uses.model = true;
                    const bit = self.names.given_bit[def.param_ref];
                    if (bit == none_u32) return "@as(i64, 0)";
                    return try self.arena.print("@as(i64, @intFromBool(model.given__.isSet({d})))", .{bit});
                }
                if (d.callee != .@"$clog2") return null;
                // `lowerClog2` writes the operand and its width, always both.
                assert(d.args.len == 2);
                const a = try i64Const(self, d.args[0], depth + 1) orelse return null;
                const width = try i64Const(self, d.args[1], depth + 1) orelse return null;
                return try self.arena.print("zClog2({s}, {s})", .{ a, width });
            }
            if (row.op == .feq or row.op == .fne or row.op == .flt or row.op == .fle or row.op == .fgt or row.op == .fge) {
                const a = try f64Const(self, av, depth + 1, false) orelse return null;
                const rhs = try f64Const(self, bv, depth + 1, false) orelse return null;
                const op = switch (row.op) {
                    .feq => "==",
                    .fne => "!=",
                    .flt => "<",
                    .fle => "<=",
                    .fgt => ">",
                    .fge => ">=",
                    else => unreachable, // else: the `if` above admits only these six real comparisons
                };
                return try self.arena.print("@as(i64, @intFromBool(({s}) {s} ({s})))", .{ a, op, rhs });
            }
            if (Mir.opClass(row.op) != .unary and Mir.opClass(row.op) != .binary) return null;
            // Table 3-3's relational row over two strings (equality, then
            // "lexicographical ordering"), as §3.4.6's `ebersmoll` example
            // writes in a parameter default. Lowering converted any mixed
            // pair, so a string here is one of two. Mirrors `fold.zig`'s `strBinary`.
            if (try strConst(self, av)) |sa| if (try strConst(self, bv)) |sb| {
                const so: []const u8 = switch (row.op) {
                    .ieq => "== .eq",
                    .ine => "!= .eq",
                    .ilt => "== .lt",
                    .ile => "!= .gt",
                    .igt => "== .gt",
                    .ige => "!= .lt",
                    else => return null, // else: Table 3-3 relates two strings and nothing else; no other op of two has an integer value
                };
                return try self.arena.print("@as(i64, @intFromBool(std.mem.order(u8, {s}, {s}) {s}))", .{ sa, sb, so });
            };
            const a = try i64Const(self, av, depth + 1) orelse return null;
            if (Mir.opClass(row.op) == .unary) return switch (row.op) {
                .opt_barrier => a,
                .ineg => try self.arena.print("@as(i64, @as(i32, @truncate(-%({s}))))", .{a}),
                .iabs => try self.arena.print("zIabs({s})", .{a}),
                .bitnot => try self.arena.print("~({s})", .{a}),
                .lognot => try self.arena.print("@as(i64, @intFromBool(({s}) == 0))", .{a}),
                else => null, // else: every real unary (and `fi_cast`) returned above through `f64Const`; what is left has no integer spelling
            };
            const rhs = try i64Const(self, bv, depth + 1) orelse return null;
            const op: []const u8 = switch (row.op) {
                .iadd => "+%",
                .isub => "-%",
                .imul => "*%",
                .bitand => "&",
                .bitor => "|",
                .bitxor, .bitxnor => "^",
                .ieq => "==",
                .ine => "!=",
                .ilt => "<",
                .ile => "<=",
                .igt => ">",
                .ige => ">=",
                else => "", // else: read only by the prongs below that print an infix `op`
            };
            return switch (row.op) {
                .iadd, .isub, .imul => try self.arena.print("@as(i64, @as(i32, @truncate(({s}) {s} ({s}))))", .{ a, op, rhs }),
                .bitand, .bitor, .bitxor => try self.arena.print("(({s}) {s} ({s}))", .{ a, op, rhs }),
                .bitxnor => try self.arena.print("~(({s}) ^ ({s}))", .{ a, rhs }),
                .ieq, .ine, .ilt, .ile, .igt, .ige => try self.arena.print("@as(i64, @intFromBool(({s}) {s} ({s})))", .{ a, op, rhs }),
                // i65 holds minInt(i64)/-1 before the wrap. A zero divisor
                // yields 0, as `renderOp`'s `.idiv` does (W0653).
                .idiv => try self.arena.print("(if (({s}) == 0) @as(i64, 0) else @as(i64, @as(i32, @truncate(@divTrunc(@as(i65, {s}), @as(i65, {s}))))))", .{ rhs, a, rhs }),
                .imod => try self.arena.print("{s}({s}, {s})", .{ gen_render.imodFn(self), a, rhs }),
                .logand, .logor => try self.arena.print("@as(i64, @intFromBool((({s}) != 0) {s} (({s}) != 0)))", .{ a, if (row.op == .logand) "and" else "or", rhs }),
                .shl => try self.arena.print("@as(i64, @as(i32, @truncate(zShl({s}, {s}))))", .{ a, rhs }),
                .shr => try self.arena.print("zShr({s}, {s})", .{ a, rhs }),
                .imin, .imax => try self.arena.print("@as(i64, {s}({s}, {s}))", .{ if (row.op == .imin) "@min" else "@max", a, rhs }),
                // `fold.ipow32` as device text, as in `renderOp`.
                .ipow => try self.arena.print("{s}({s}, {s})", .{ gen_render.ipow_fn, a, rhs }),
                // Real-valued binaries: `tyOf(v) == .real` and the float
                // comparisons both returned above.
                .fadd, .fsub, .fmul, .fdiv, .fmod, .flt, .fgt, .fle, .fge, .feq, .fne, .pow, .hypot, .fmin, .fmax, .atan2 => null,
                // The `.unary` return and the opClass filter above keep every
                // other class out.
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
            };
        },
        .undef, .str_const, .block_param => return null,
    }
}

/// Returns a plain-f64 expression for `v` over `model.<p>` leaves (a
/// parameter expression or operator control argument), or null when the host
/// cannot evaluate it outside S. Literal subtrees fold to one number. Never
/// looks through a parameter's default: the host overrides parameters.
///
/// With `in_unit`, the text lands in a unit body: it names unit-local slots
/// (avoiding quadratic re-rendering of parameter chains) and admits only
/// `devSafe` opcodes, since a unit body also compiles for nvptx without libm.
pub fn f64Const(self: *Gen, v0: Mir.Value, depth: u32, in_unit: bool) Error!?[]const u8 {
    // ponytail: loop-carried and multiway phis are not rendered; that needs
    // execution of the constant-function CFG.
    if (depth > 32) return null;
    const v = self.an.rv(v0);
    if (in_unit) {
        // Already materialized: name it and never fold past it, or its
        // declaration would be unread. `depth > 0` because at depth 0 the
        // caller is this slot's own declaration.
        if (depth > 0 and self.an.dFree(v)) {
            const i = @backingInt(v);
            // A setup field is already a plain f64.
            if (i < self.an.nv and self.plan.isRoot(v)) return try gen_setup.rootRef(self, v, true);
            // One that differs per point of a batch: `.val()` would pick
            // one, so the caller keeps it an `S` value (the same f64
            // arithmetic on a lane-free value).
            if (float_lanes.perPoint(self, v)) return null;
            if (i < self.an.nv and self.plan.cached(v))
                return try self.arena.print("c.f{d}.val()", .{self.core.lo_idx[i]});
            if (i < self.an.nv and self.plan.slot[i] != none_u32) {
                gen_unit.probeUse(self, self.plan.slot[i]);
                return try self.arena.print("{s}.val()", .{try gen_unit.slotRefStr(self, i)});
            }
        }
        // A planner literal (`UnitPlan.literal`) is a leaf whose operands the
        // unit never planned: its number, whatever they would name.
        if (v != .undef and self.plan.literal(v)) return try gen_file.fmtF64(self, self.an.foldConst(v, false).?.f);
        // Fold a literal chain to one number unless it would swallow a slot.
        if (!gen_render.foldHidesSlot(self, v, 0)) {
            if (self.an.foldConst(v, false)) |k| return try gen_file.fmtF64(self, k.f);
        }
    } else {
        // A real parameter may depend on integer arithmetic. Evaluate that
        // subtree at its integer width before converting its final value.
        if (self.an.tyOf(v) == .int) {
            const integer = try i64Const(self, v, depth + 1) orelse return null;
            return try self.arena.print("@as(f64, @floatFromInt({s}))", .{integer});
        }
        if (self.an.foldConst(v0, false)) |k| return try gen_file.fmtF64(self, k.f);
    }
    switch (self.mir.valueDef(v)) {
        .param_ref => |p| {
            self.uses.model = true;
            return switch (Analysis.tyOfParam(self.lowered.params.items[p].ty)) {
                .real => try self.arena.print("model.{s}", .{self.names.p_names[p]}),
                .int => try self.arena.print("@as(f64, @floatFromInt(model.{s}))", .{self.names.p_names[p]}),
                .str => "0.0",
                .wide => unreachable, // `tyOfParam` types no parameter wide
            };
        },
        .inst_result => |inst| {
            const row = self.mir.instRow(inst);
            // A unit body also compiles for nvptx, which has no libm, so it
            // takes only `opcode_zig`'s `dev_safe` opcodes: arithmetic LLVM
            // lowers to one PTX instruction (sqrt/floor/ceil are sqrt.rn.f64
            // and cvt.rmi/rpi.f64.f64). Real opcodes only: f64 drops §3.2's
            // 32-bit wraparound, so an integer residual goes through `intBin32`.
            if (in_unit and !opcode_zig.get(row.op).dev_safe) return null;
            if (!in_unit and (row.op == .select or row.op == .phi)) return hostConditionalExpr(self, inst, depth, .real);
            // §9.15 a parameter default over `$simparam`, in the analog
            // block's order (`Lowered.simparamAnswer`): a host field is a
            // Model read, so `emitDerive` renders it.
            if (row.op == .call) {
                const d = self.mir.instData(inst).call;
                if (d.callee != .@"$simparam") return null;
                const name = gen_call.strArg(self, d.args, 0) orelse return null;
                switch (self.lowered.simparamAnswer(name, d.args.len > 1)) {
                    .host => |h| {
                        self.uses.model = true;
                        return try self.arena.print("model.{s}", .{h.field});
                    },
                    .value => |x| return try gen_file.fmtF64(self, x),
                    .fallback => return try f64Const(self, d.args[1], depth + 1, in_unit),
                    // No card-time value: W1050, the host's field to write.
                    .runtime, .unknown => return null,
                }
            }
            switch (Mir.opClass(row.op)) {
                // Fragments from `opcode_zig`'s `host_f64` column, because
                // `allocPrint` needs a comptime format.
                .unary => {
                    const a = try f64Const(self, @fromBackingInt(@intCast(row.a)), depth + 1, in_unit) orelse return null;
                    const fix = opcode_zig.get(row.op).host_f64 orelse return null;
                    assert(fix.len == 2);
                    return try self.arena.print("{s}{s}{s}", .{ fix[0], a, fix[1] });
                },
                .binary => {
                    if (row.op == .fmod) {
                        const a = try f64Const(self, @fromBackingInt(@intCast(row.a)), depth + 1, in_unit) orelse return null;
                        const b2 = try f64Const(self, @fromBackingInt(@intCast(row.b)), depth + 1, in_unit) orelse return null;
                        return try self.arena.print("(if (({s}) == 0.0) @panic(\"VerA: real parameter remainder divisor is zero\") else @rem({s}, {s}))", .{ b2, a, b2 });
                    }
                    const fix = opcode_zig.get(row.op).host_f64 orelse return null;
                    assert(fix.len == 3);
                    const a = try f64Const(self, @fromBackingInt(@intCast(row.a)), depth + 1, in_unit) orelse return null;
                    const b2 = try f64Const(self, @fromBackingInt(@intCast(row.b)), depth + 1, in_unit) orelse return null;
                    return try self.arena.print("{s}{s}{s}{s}{s}", .{
                        fix[0], a, fix[1], b2, fix[2],
                    });
                },
                // `select`/`phi` returned above; the rest are not values, and
                // a §3.2.2 array element is not derivable from a model card.
                .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => return null,
            }
        },
        .undef, .float_const, .int_const, .str_const, .block_param => return null,
    }
}

/// Returns `f64Const(v)` where the LRM requires a constant or parameter
/// expression. Otherwise reports E0515 at the source, marks the build fatal
/// and returns "0.0".
pub fn f64Expr(self: *Gen, v0: Mir.Value) Error![]const u8 {
    if (try f64Const(self, v0, 0, false)) |s| return s;
    // Point at the argument's defining expression, else the operator call.
    const v = self.an.rv(v0);
    const def = self.mir.valueDef(v);
    const tok = if (def == .inst_result) self.mir.instTok(def.inst_result) else Mir.no_tok;
    if (self.diags) |bag| try bag.add(
        .codegen,
        .E0515,
        self.lowered.tokenSpan(if (tok == Mir.no_tok) self.ctrl_tok else tok),
        "this argument is computed during the solve; only literals, parameters " ++
            "and arithmetic over them are available where the host evaluates it",
        .{},
    );
    self.poison("LRM 4.5: an analog operator control argument " ++
        "must be a constant or parameter expression");
    assert(self.any_fatal);
    assert(self.fatal != null);
    return "0.0";
}

/// Returns `f64Expr(args[i])`, or `dflt` when the argument is absent.
pub fn argF64(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
    if (i >= args.len) return dflt;
    return f64Expr(self, args[i]);
}

/// Returns whether a §4.5 control argument is a solve result rather than a
/// constant or parameter expression. Rolls back `f64Const`'s `uses.model`
/// side effect.
pub fn ctrlIsDynamic(self: *Gen, v: Mir.Value) Error!bool {
    const saved = self.uses.model;
    defer self.uses.model = saved;
    return (try f64Const(self, v, 0, false)) == null;
}
