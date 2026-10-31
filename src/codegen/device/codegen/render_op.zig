//! One MIR opcode over its operands -> its Zig expression: the `S` method or
//! device kernel each opcode spells (`opcode_zig.zig`'s rows), integer
//! arithmetic wrapped to §3.2's 32 bits, comparisons, and derivative-free
//! operands written as plain constants.
//! Cites: §3.2, §4.2.1, §4.2.4, §4.2.11, §4.3.1 (Table 4-14), §4.3.2
//! (Table 4-15), IEEE 1364 §17.11.
//!
//! Contents:
//! - `pub const ipow_fn`
//! - `pub fn imodFn(self: *const Gen) []const u8`
//! - `pub fn renderOp(self: *Gen, op: Mir.Opcode, a: Mir.Value, b2: Mir.Value, res_ty: VTy) Error!void`
//! - `pub fn helper2(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void`
//! - `pub fn kernelArg(self: *Gen, v: Mir.Value, m: []const u64) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_host = @import("host_expr.zig");
const gen_mask = @import("mask.zig");
const gen_file = @import("file.zig");
const family = @import("family.zig");
const opcode_zig = @import("opcode_zig.zig");
const Mir = @import("ir").Mir;
const Error = codegen.Error;
const VTy = codegen.VTy;
const gen_render = @import("render.zig");

/// `.ipow`'s device text: `kernels/fold.zig`'s `ipow32` as a callable expression. Locals
/// carry a `zp_` prefix because Zig refuses a name that shadows any enclosing
/// scope's.
pub const ipow_fn = "(struct { fn zp_f(zp_b: i64, zp_n: i64) i64 { " ++
    "if (zp_n < 0) return if (zp_b == 1) 1 else if (zp_b == -1) (if (@rem(zp_n, 2) == 0) 1 else -1) else 0; " ++
    "var zp_x: i32 = @truncate(zp_b); var zp_e = zp_n; var zp_r: i32 = 1; " ++
    "while (zp_e > 0) : (zp_e >>= 1) { if (zp_e & 1 != 0) zp_r *%= zp_x; zp_x *%= zp_x; } " ++
    "return zp_r; } }.zp_f)";

/// Integer `/` with a zero divisor defined as 0 (see `renderOp`'s `.idiv`).
const idiv_fn = "(struct { fn zd_f(zd_a: i64, zd_b: i64) i64 { " ++
    // In i65, so minInt(i64) / -1 wraps as `i64Const`'s host spelling does
    // instead of trapping; the caller truncates to §3.2's 32 bits.
    "return if (zd_b == 0) 0 else @truncate(@divTrunc(@as(i65, zd_a), zd_b)); } }.zd_f)";

/// §4.2.4 permits a varying divisor but requires an error when it is zero.
/// Executables report E0601; solver devices trap without importing host I/O
/// onto GPU targets. -1 divides every integer exactly, including minInt(i64),
/// whose hardware signed remainder would otherwise overflow its quotient.
/// Both ordinary expressions and model-card derivation use this spelling.
pub fn imodFn(self: *const Gen) []const u8 {
    const head = "(struct { fn zm_f(zm_a: i64, zm_b: i64) i64 { if (zm_b == 0) { ";
    const tail = " } return if (zm_b == -1) 0 else @rem(zm_a, zm_b); } }.zm_f)";
    return if (self.display == .emit)
        head ++ "std.debug.print(\"error[E0601]: LRM 4.2.4: integer modulus divisor is zero\\n\", .{}); std.process.exit(1);" ++ tail
    else
        head ++ "@trap();" ++ tail;
}

/// Writes one opcode over its operands. Also serves the `$`-prefixed math
/// functions (IEEE 1364 §17.11).
///
/// Asserts that `op` is a unary or binary opcode.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn renderOp(self: *Gen, op: Mir.Opcode, a: Mir.Value, b2: Mir.Value, res_ty: VTy) Error!void {
    assert(Mir.opClass(op) == .unary or Mir.opClass(op) == .binary);
    assert(res_ty == .real or res_ty == .int or res_ty == .str or res_ty == .wide);
    // §3.3.1 string relations: lowering types both operands `.string` and
    // picks the integer comparison opcodes for them.
    if (self.an.tyOf(self.an.rv(a)) == .str or self.an.tyOf(self.an.rv(b2)) == .str) {
        const rel: ?[]const u8 = switch (op) {
            .ieq, .feq => "== 0",
            .ine, .fne => "!= 0",
            .ilt, .flt => "< 0",
            .ile, .fle => "<= 0",
            .igt, .fgt => "> 0",
            .ige, .fge => ">= 0",
            else => null, // else: §3.3.1 relates strings with these six; any other op falls to its numeric form
        };
        if (rel) |r| {
            try self.b("@as(i64, @intFromBool(zStrCmp(", .{});
            try gen_render.renderVal(self, a, .str);
            try self.b(", ", .{});
            try gen_render.renderVal(self, b2, .str);
            try self.b(") {s}))", .{r});
            return;
        }
    }
    switch (op) {
        // §4.2.4 real arithmetic. With one operand derivative-free, `scale`
        // and `addC` skip the zero-lane multiply and add that `.strict` will
        // not fold. Each rewrite is value-preserving under IEEE 754 (`a - k`
        // is `a + (-k)`). `fdiv` keeps `div`: `a * (1/k)` is not `a / k`.
        .fadd, .fsub, .fmul => {
            // A derivative-free operand that still differs per point (a
            // `ddx`-stripped probe) goes through `zMulP`/`zAddP`/`zSubP`:
            // `scale`/`addC` of its value in a one-point family, the same
            // arithmetic kept per point in a batch.
            const pa = perPoint(self, a);
            const pb = perPoint(self, b2);
            if (pb or (pa and !self.an.dFree(b2))) {
                const k, const o = if (pb) .{ b2, a } else .{ a, b2 };
                try self.b("{s}(S, (", .{switch (op) {
                    .fmul => "zMulP",
                    .fsub => if (pb) "zSubP" else "zAddP",
                    else => "zAddP", // else: the prong is `.fadd, .fsub, .fmul`
                }});
                try gen_render.renderVal(self, o, .real);
                try self.b("){s}, ", .{if (op == .fsub and !pb) ".neg()" else ""});
                try gen_render.renderVal(self, k, .real);
                return self.b(")", .{});
            }
            if (self.an.dFree(b2)) {
                try self.b("(", .{});
                try gen_render.renderVal(self, a, .real);
                try self.b(").{s}(", .{if (op == .fmul) "scale" else "addC"});
                if (op == .fsub) try writeNegConst(self, b2) else try writeConst(self, b2);
                return self.b(")", .{});
            }
            if (self.an.dFree(a)) {
                try self.b("(", .{});
                try gen_render.renderVal(self, b2, .real);
                // k - b: negate first, so the constant still arrives through
                // `addC` and the derivative costs one negation.
                try self.b("){s}.{s}(", .{
                    if (op == .fsub) ".neg()" else "",
                    if (op == .fmul) "scale" else "addC",
                });
                try writeConst(self, a);
                return self.b(")", .{});
            }
            try method2(self, a, switch (op) {
                .fadd => "add",
                .fsub => "sub",
                else => "mul", // else: the prong is `.fadd, .fsub, .fmul`
            }, b2);
        },
        // §4.3.1/§4.3.2 math: one `S` method or kernel per opcode
        // (`opcode_zig`'s `s` column; `.custom` here is a compile error).
        // expm1/log1p are primitives, not compositions of exp/log, because
        // Table 4-14 names them for the cancellation those would suffer.
        inline .fdiv,
        .fneg,
        .fmod,
        .sqrt,
        .exp,
        .ln,
        .sin,
        .cos,
        .tanh,
        .sinh,
        .cosh,
        .atan,
        .fabs,
        .expm1,
        .ln1p,
        .log10,
        .tan,
        .asin,
        .acos,
        .asinh,
        .acosh,
        .atanh,
        .floor,
        .ceil,
        .hypot,
        .atan2,
        .fmin,
        .fmax,
        => |o| {
            const r = comptime opcode_zig.get(o);
            const binary = comptime Mir.opClass(o) == .binary;
            if (r.pins_lanes) {
                float_lanes.pinLanes(self, a);
                if (binary) float_lanes.pinLanes(self, b2);
            }
            // §4.3.2 a domain error is reported where the op runs, not where
            // `setup` speculates it outside its guard (`Setup.spec`).
            if (comptime r.checked) |c| {
                if (binary) @compileError("renderOp: a `checked` spelling is unary, `" ++ @tagName(o) ++ "` is binary");
                if (!self.su.spec) return switch (c) {
                    .helper => |h| helper1(self, h, a),
                    .helper_s => |h| helperS(self, h, a),
                    .method, .custom => @compileError("renderOp: `" ++ @tagName(o) ++ "`'s checked spelling is a kernel"),
                };
            }
            switch (r.s) {
                .method => |m| if (binary) try method2(self, a, m, b2) else try method1(self, a, m),
                .helper => |h| if (binary) try helper2(self, h, a, b2) else try helper1(self, h, a),
                .helper_s => |h| if (binary) @compileError("renderOp: `helper_s` is unary, `" ++ @tagName(o) ++ "` is binary") else try helperS(self, h, a),
                .custom => @compileError("renderOp: opcode_zig gives `" ++ @tagName(o) ++ "` no S spelling"),
            }
        },
        .pow => {
            // `S.pow` takes an f64 exponent. A literal exponent folds with
            // `resolve_params = false`, so a model-card override is never
            // baked in as the declared default. A solve-constant exponent
            // (`pow(1 - v/pj, 1 - mj)`) takes the same route spelled as an
            // expression, which keeps it off `zPow`'s lane-pinning path.
            // `UnitPlan.foldedExponent` mirrors this test; change both.
            const par_exp: ?[]const u8 = if (self.an.foldConst(b2, false) == null and self.an.dFree(b2))
                try gen_host.f64Const(self, b2, 1, true)
            else
                null;
            // §4.3.2 the domain check (`zPowK`) wherever the op runs, and
            // the bare method where `setup` speculates it (`Setup.spec`).
            const k_text: ?[]const u8 = if (self.an.foldConst(b2, false)) |k| try gen_file.fmtF64(self, k) else par_exp;
            if (k_text) |k| {
                if (self.su.spec) try self.b("(", .{}) else try self.b("zPowK(S, ", .{});
                try gen_render.renderVal(self, a, .real);
                if (self.su.spec) try self.b(").pow({s})", .{k}) else try self.b(", {s})", .{k});
            } else {
                // zPow linearizes around `.val()` of both operands
                // (including §4.3.1's negative-base steering): a batch
                // family runs it point by point (`zPowL`, the lead protocol).
                float_lanes.leadLanes(self, a);
                float_lanes.leadLanes(self, b2);
                // The last argument drops the ∂/∂y term (and its `ln`) when
                // the exponent cannot move with the solve.
                const m = gen_mask.hex(try gen_mask.join(self.arena, family.mask(self, a), family.mask(self, b2)), false);
                try self.b("zPowL(S, 0x{f}, zTo(S, 0x{f}, ", .{ m, m });
                try gen_render.renderVal(self, a, .real);
                try self.b("), zTo(S, 0x{f}, ", .{m});
                try gen_render.renderVal(self, b2, .real);
                try self.b("), {})", .{!self.an.dFree(b2)});
            }
        },
        // §4.2.1 conversions
        .if_cast => {
            try self.b("S.con(@as(f64, @floatFromInt(", .{});
            try gen_render.renderVal(self, a, .int);
            try self.b(")))", .{});
        },
        .fi_cast => {
            // §4.2.1.1 rounds and leaves overflow undefined; `lossyCast`
            // (saturate, NaN to 0) avoids UB under ReleaseFast and matches
            // `fold.Const.asInt`'s fold.
            float_lanes.leadLanes(self, a); // a real→int collapse is a decision
            try self.b("zRoundI(S, ", .{});
            try gen_render.renderVal(self, a, .real);
            try self.b(")", .{});
        },
        .opt_barrier => try gen_render.renderVal(self, a, res_ty),
        // VerA's `vera_nodiff` (§2.9): the operand's value with no lanes. The
        // `.val()` is a scalar decision on an x-varying value.
        .dstop => {
            float_lanes.leadLanes(self, a);
            try self.b("zStrip(S, ", .{});
            try gen_render.renderVal(self, a, .real);
            try self.b(")", .{});
        },
        // §5.6.1.2 path-integrated reactive latches: value only, fixed
        // across one Newton attempt (advanced by stateCtl(.commit)). The
        // coefficient's dA enters only times (B - pb), which is zero at
        // every committed point, so the AD Jacobian is exact.
        .path_prev, .path_acc => {
            const v = self.an.rv(a);
            const fam = if (op == .path_prev) self.core.prev_vals else self.core.acc_vals;
            const k = std.mem.findScalar(Mir.Value, fam, v).?; // plan_core.plan queued every site
            self.cur.uses.inst = true; // the latch read keeps `inst` in the signature
            float_lanes.instLanes(self, false);
            try self.b("zInst(S, inst, \"{s}__{d}\")", .{ @as([]const u8, if (op == .path_prev) "pb" else "pq"), k });
        },
        // §3.2 integer arithmetic at 32-bit two's complement width
        // (`kernels/fold.zig`'s `wrap32`). `%` never widens; `/` overflows only for
        // -2^31 / -1, whose wrapped answer is -2^31.
        .iadd => try intBin32(self, a, "+%", b2),
        .isub => try intBin32(self, a, "-%", b2),
        .imul => try intBin32(self, a, "*%", b2),
        .idiv => {
            // §4.2.4 has no zero rule for `/`, so a divisor the prover
            // cannot show non-zero is accepted (with W0653) and goes through
            // `idiv_fn`, where x / 0 is 0. A literal other than 0 and -1 keeps
            // the bare `@divTrunc`: -1 overflows at minInt(i64), which a
            // saturated real -> int conversion can hold.
            const lit = self.mir.valueDef(self.an.rv(b2));
            const bare = lit == .int_const and lit.int_const != 0 and lit.int_const != -1;
            try self.b("@as(i64, @as(i32, @truncate(", .{});
            try intCall2(self, if (bare) "@divTrunc" else idiv_fn, a, b2);
            try self.b(")))", .{});
        },
        .imod => try intCall2(self, imodFn(self), a, b2),
        .ineg => {
            try self.b("@as(i64, @as(i32, @truncate(-%(", .{});
            try gen_render.renderVal(self, a, .int);
            try self.b("))))", .{});
        },
        .iabs => try intCall1(self, "zIabs", a),
        .imin => try intCall2(self, "@min", a, b2),
        .imax => try intCall2(self, "@max", a, b2),
        // Inline rather than a shared helper, which would grow every device.
        // An anonymous struct, so two nested `**` cannot collide on a label.
        .ipow => try intCall2(self, ipow_fn, a, b2),
        // §4.2.5/§4.2.7 relational and equality, integer 0/1
        .flt => try cmpReal(self, a, .lt, b2),
        .fgt => try cmpReal(self, a, .gt, b2),
        .fle => try cmpReal(self, a, .lte, b2),
        .fge => try cmpReal(self, a, .gte, b2),
        .feq => try cmpReal(self, a, .eq, b2),
        .fne => try cmpReal(self, a, .neq, b2),
        .ilt => try cmpInt(self, a, "<", b2),
        .igt => try cmpInt(self, a, ">", b2),
        .ile => try cmpInt(self, a, "<=", b2),
        .ige => try cmpInt(self, a, ">=", b2),
        .ieq => try cmpInt(self, a, "==", b2),
        .ine => try cmpInt(self, a, "!=", b2),
        // §4.2.8 logical
        .logand, .logor => {
            try self.b("@as(i64, @intFromBool((", .{});
            try gen_render.renderVal(self, a, .int);
            try self.b(") != 0 {s} (", .{if (op == .logand) "and" else "or"});
            try gen_render.renderVal(self, b2, .int);
            try self.b(") != 0))", .{});
        },
        .lognot => {
            try self.b("@as(i64, @intFromBool((", .{});
            try gen_render.renderVal(self, a, .int);
            try self.b(") == 0))", .{});
        },
        // §4.2.9 bitwise
        .bitand => try intBin(self, a, "&", b2),
        .bitor => try intBin(self, a, "|", b2),
        .bitxor => try intBin(self, a, "^", b2),
        .bitxnor => {
            try self.b("~(", .{});
            try intBin(self, a, "^", b2);
            try self.b(")", .{});
        },
        .bitnot => {
            try self.b("~(", .{});
            try gen_render.renderVal(self, a, .int);
            try self.b(")", .{});
        },
        // §4.2.11 shifts. The truncation is §3.2's width (`1 << 31` is
        // negative, `1 << 32` is zero). `zShl` defines an over-wide or
        // negative count instead of UB.
        .shl => {
            try self.b("@as(i64, @as(i32, @truncate(", .{});
            try intCall2(self, "zShl", a, b2);
            try self.b(")))", .{});
        },
        // §4.2.11 "fill the vacated bit positions with zeroes" at §3.2.1's
        // 32-bit width, so not `std.math.shr(i64, ...)`, which sign-fills.
        // `zShr` defines an over-wide or negative count as 0.
        .shr => try intCall2(self, "zShr", a, b2),
        // §3.2.2 array ops are rendered by `renderLoad`/`emitArrayStmt`.
        .phi, .select, .call, .branch, .jump, .anew, .fload, .iload, .store => unreachable,
    }
}

/// Writes a two-operand kernel call at the union of the operands' masks.
/// Asserts that `name` names the kernel.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn helper2(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void {
    assert(name.len != 0);
    const m = try gen_mask.join(self.arena, family.mask(self, a), family.mask(self, b2));
    try kernelOpen(self, name, m);
    try kernelArg(self, a, m);
    try self.b(", ", .{});
    try kernelArg(self, b2, m);
    assert(m.len == self.mw);
    try kernelClose(self);
}

/// Writes one real kernel operand, widened to the kernel's mask.
/// Asserts that `m` is one mask (`Gen.mw` words).
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn kernelArg(self: *Gen, v: Mir.Value, m: []const u64) Error!void {
    assert(m.len == self.mw);
    const len_before = self.out.items.len;
    try self.b("zLw(S, 0x{f}, ", .{gen_mask.hex(m, false)});
    try gen_render.renderVal(self, v, .real);
    assert(self.out.items.len > len_before + "zLw(S, 0x, ".len);
    try self.b(")", .{});
}

// ---- private ----

/// Whether real `v` is derivative-free yet x-dependent: a `.val()` of it
/// would be one point's value (see `renderOp`'s `.fadd, .fsub, .fmul`).
fn perPoint(self: *Gen, v: Mir.Value) bool {
    assert(self.an.vty.len == self.an.nv);
    return self.an.dFree(v) and float_lanes.perPoint(self, v) and self.an.tyOf(self.an.rv(v)) == .real;
}

/// Writes the f64 value of a derivative-free operand (callers check `dFree`).
/// Prefers the arithmetic itself (`model.is`); falls back to `.val()` of the
/// rendered S for values with no GPU-safe f64 spelling (`$temperature`, a
/// transcendental of a parameter). Depth 1: naming the operand's own slot
/// is wanted here, unlike `renderInst`'s depth-0 self-reference.
fn writeConst(self: *Gen, v: Mir.Value) Error!void {
    assert(self.an.dFree(v));
    if (try gen_host.f64Const(self, v, 1, true)) |s| return self.b("{s}", .{s});
    // A derivative-free value can still differ per point (a `ddx`-stripped
    // probe): `.val()` collapses it to one, so a batch is not exact.
    float_lanes.pinLanes(self, v);
    try self.b("(", .{});
    try gen_render.renderVal(self, v, .real);
    try self.b(").val()", .{});
}

/// Writes `writeConst` negated, for `a - k` as `a.addC(-k)`. A literal
/// negates in the formatter (`addC(-1.0)`), not with a `-(...)` wrapper.
fn writeNegConst(self: *Gen, v: Mir.Value) Error!void {
    assert(self.an.dFree(v));
    // Same guard as `f64Const`.
    if (!gen_render.foldHidesSlot(self, v, 0)) {
        if (self.an.foldConst(v, false)) |k| return self.b("{s}", .{try gen_file.fmtF64(self, -k)});
    }
    try self.b("-(", .{});
    try writeConst(self, v);
    try self.b(")", .{});
}

fn method1(self: *Gen, a: Mir.Value, name: []const u8) Error!void {
    assert(name.len != 0);
    try self.b("(", .{});
    try gen_render.renderVal(self, a, .real);
    try self.b(").{s}()", .{name});
}

fn method2(self: *Gen, a: Mir.Value, name: []const u8, b2: Mir.Value) Error!void {
    assert(name.len != 0);
    try self.b("(", .{});
    try gen_render.renderVal(self, a, .real);
    try self.b(").{s}(", .{name});
    try gen_render.renderVal(self, b2, .real);
    try self.b(")", .{});
}

/// `name(S, a)` with `S` as written: `zAbs` takes the family itself.
fn helperS(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
    assert(name.len != 0);
    try self.b("{s}(S, ", .{name});
    try gen_render.renderVal(self, a, .real);
    try self.b(")", .{});
}

/// Writes a one-operand kernel call at the operand's mask.
fn helper1(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
    assert(name.len != 0);
    const m = family.mask(self, a);
    try kernelOpen(self, name, m);
    try kernelArg(self, a, m);
    try kernelClose(self);
}

/// Writes `zLu(S, m, name(zL(S, m), `: kernels take one scalar, which a
/// family is at one mask. `m` is the result's. Close with `kernelClose`.
fn kernelOpen(self: *Gen, name: []const u8, m: []const u64) Error!void {
    assert(name.len != 0);
    assert(m.len == self.mw);
    const h = gen_mask.hex(m, false);
    try self.b("zLu(S, 0x{f}, {s}(zL(S, 0x{f}), ", .{ h, name, h });
}

/// Writes the two parens `kernelOpen` left open.
fn kernelClose(self: *Gen) Error!void {
    assert(self.out.items.len != 0);
    try self.b("))", .{});
}

/// Writes `(a) opx (b2)` over integers, unwrapped: only for the bitwise ops
/// that cannot leave §3.2's range.
fn intBin(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
    assert(opx.len != 0);
    try self.b("((", .{});
    try gen_render.renderVal(self, a, .int);
    try self.b(") {s} (", .{opx});
    try gen_render.renderVal(self, b2, .int);
    try self.b("))", .{});
}

/// Writes `intBin` truncated to §3.2's 32-bit width (`fold.wrap32`). `opx`
/// must be a wrapping op (`+%`): an overflowing i64 `+` would panic before
/// the truncation.
fn intBin32(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
    assert(std.mem.endsWith(u8, opx, "%")); // `+%`, `-%`, `*%`: wrapping.
    try self.b("@as(i64, @as(i32, @truncate(", .{});
    try intBin(self, a, opx, b2);
    try self.b(")))", .{});
}

/// Writes `name(a)` over an integer operand.
fn intCall1(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
    assert(name.len != 0);
    try self.b("{s}(", .{name});
    try gen_render.renderVal(self, a, .int);
    try self.b(")", .{});
}

// ponytail: integer callees infer their type; add a typed variant only for a caller.
fn intCall2(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void {
    assert(name.len != 0);
    try self.b("{s}(", .{name});
    try gen_render.renderVal(self, a, .int);
    try self.b(", ", .{});
    try gen_render.renderVal(self, b2, .int);
    try self.b(")", .{});
}

/// `op`'s tag names are the device kernel `zCmp`'s operator names.
fn cmpReal(self: *Gen, a: Mir.Value, op: std.math.CompareOperator, b2: Mir.Value) Error!void {
    assert(self.an.tyOf(self.an.rv(a)) != .str);
    float_lanes.leadLanes(self, a);
    float_lanes.leadLanes(self, b2);
    try self.b("@as(i64, @intFromBool(zCmp(S, .{s}, ", .{@tagName(op)});
    try gen_render.renderVal(self, a, .real);
    try self.b(", ", .{});
    try gen_render.renderVal(self, b2, .real);
    try self.b(")))", .{});
}

fn cmpInt(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
    assert(opx.len != 0);
    try self.b("@as(i64, @intFromBool((", .{});
    try gen_render.renderVal(self, a, .int);
    try self.b(") {s} (", .{opx});
    try gen_render.renderVal(self, b2, .int);
    try self.b(")))", .{});
}
