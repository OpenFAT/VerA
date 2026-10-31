//! §9.4.3 format strings: a task's arguments in, E0810/E0819/E0825/E0826/
//! E0828 out for a conversion its operand cannot pair with, and each integer
//! operand's IEEE 1364 width and sign recorded for the formatter
//! (`$display$width`).
//!
//! Cites: §2.7, §3.2, §3.3, §3.5.1, §5.4.1, §5.5.1, §5.5.2, §7, §7.3.1,
//! §9.4.1, §9.4.2, §9.4.3, §9.4.5, §9.5.2, §9.7.1, §9.7.2, §9.7.3, §17.1.1.2,
//! §17.1.1.3; IEEE 1364-2005 §5.4.1, §17.1.1.3.
//!
//! Contents:
//! - `pub fn checkFormatPairing(self: *Lower, tok: u32, args: []const Ast.ExprId) Oom!void`
//! - `pub fn prepareFormatArgs(self: *Lower, tok: u32, live: []const Ast.ExprId, tys: []const Ty, vals: []Mir.Value, skip: usize) Oom!void`
//! - `pub fn messageStart(c: Mir.Callee, tys: []const Ty) usize`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const str_k = @import("kernels").str_kernels;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr_name = @import("expr_name.zig");
const lower_sysfunc_args = @import("sysfunc_args.zig");
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const TypedValue = Lower.TypedValue;

/// One conversion `nextConv` found: its letter, lowercased, whether its
/// flags carried '#', whether anything (a flag, a width, a precision) stood
/// between the `%` and the letter, and the larger of its width and
/// precision (0 when neither is written; saturating).
const Conv = struct { letter: u8, alt: bool, prefixed: bool = false, field: u64 = 0 };

/// The largest field width or precision an analog-context format may
/// write (#45; `docs/specification/Vague_Decisions.md` §7): 2^30. The device
/// kernel `str_kernels.zCReal` indexes digits as i32, the precision plus
/// f64's 309 integer digits and its rounding position, and `cg_display`
/// sizes each field's scratch as width + precision + 328 bytes in a u64;
/// at 2^30 both are exact with room to spare. Past it is E0828.
const max_format_field: u64 = 1 << 30;

/// An integer expression's width in bits (1..64, the carrier) and sign.
const IntSize = struct { bits: u7, signed: bool };

const one_bit: IntSize = .{ .bits = 1, .signed = false };

/// §3.2's `integer`, the width the analog context computes every integer
/// operation at (`render.intBin32`, VD-116), and IEEE 1364 Table 5-22's
/// unsized constant ("Same as integer").
const integer: IntSize = .{ .bits = 32, .signed = true };

/// §9.4.3: "for each % character (except %m, %% and %l) that appears in a
/// string, a corresponding expression argument shall be supplied after the
/// string."
///
/// Only a shortfall is diagnosed. The same clause gives a surplus a meaning
/// ("displayed using the default decimal format"), and §9.7.3 puts a
/// non-string first in `$fatal(n, "…")`, so the format is the first argument
/// that folds to a string, the rule `cg_display.emitDisplayTask` uses. A format
/// built at run time is not checked.
pub fn checkFormatPairing(self: *Lower, tok: u32, args: []const Ast.ExprId) Oom!void {
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0);
    const at, const fmt = for (args, 0..) |a, i| {
        if (try lower_sysfunc_args.outputLiteral(self, a)) |text| break .{ i, text };
        if (lower_constfold.constEval(self, a)) |c| switch (c) {
            .str => |s| break .{ i, s },
            else => {},
        };
    } else return;

    var need: usize = 0;
    var i: usize = 0;
    while (nextConv(fmt, &i)) |c| {
        if (consumes(c.letter)) need += 1;
    }

    // A null argument (`,,`) is still an argument — §9.4.1 gives it a
    // rendering — so the supply is the slot count, not the non-empty one.
    assert(at < args.len);
    const have = args.len - (at + 1);
    if (have >= need) return;
    try self.err(tok, .E0810, "the format string has {d} consuming format specifiers but {d} arguments follow it", .{ need, have });
}

/// §9.4.3's other pairing rule: each conversion against its operand's type.
/// `checkFormatPairing` counts; this checks that each pair can be rendered
/// (E0819), so a mismatch is reported here rather than failing the device build.
///
/// Walk every format run as `cg_display.buildArgs` does, skipping consumed
/// operands so a string used by `%s` does not become a new format. Numeric
/// `%s` operands also retain their source width through an identity call.
/// A shortfall stops where the operands stop; E0810 already owns it.
/// The first `skip` operands are not message text (`messageStart`): no
/// format reads them, and they keep their own values.
pub fn prepareFormatArgs(self: *Lower, tok: u32, live: []const Ast.ExprId, tys: []const Ty, vals: []Mir.Value, skip: usize) Oom!void {
    assert(live.len == tys.len);
    assert(skip <= live.len);
    var at: usize = skip;
    while (at < live.len) {
        // Use the actual lowered bytes, including direct literal NUL escapes,
        // so validation and emission inspect the same format.
        const lowered = self.mir.valueDef(vals[at]);
        const fmt_or: ?[]const u8 = if (lowered == .str_const) lowered.str_const else if (lower_constfold.constEval(self, live[at])) |c| switch (c) {
            .str => |str| str,
            else => null,
        } else null;
        const fmt = fmt_or orelse {
            // §9.4.3 a bare operand takes "the default decimal format" — `%d`'s field.
            if (tys[at] == .integer) try decimalWidth(self, live[at], &vals[at]);
            at += 1;
            continue;
        };
        var next = at + 1;
        var i: usize = 0;
        while (nextConv(fmt, &i)) |cv| {
            // #42: §9.4.2 Table 9-21's `%%` is two characters, and C11
            // 7.21.6.1p8 says the same ("The complete conversion
            // specification shall be %%"), so neither gives `%5%` a meaning.
            if (cv.letter == '%' and cv.prefixed) {
                try self.err(tok, .E0826, "a flag, width or precision before the second `%` of `%%`", .{});
                continue;
            }
            // #45: source text writes the width and precision, so their
            // bound is a diagnostic here, never an assert downstream.
            if (cv.field > max_format_field)
                try self.err(tok, .E0828, "`%{c}` has a field width or precision past {d}", .{ cv.letter, max_format_field });
            // §9.4.3 grants C's '#' to Table 9-23's real conversions only.
            if (cv.alt and !str_k.zcAltOk(cv.letter))
                try self.err(tok, .E0825, "`%#{c}`: '#' is C's alternative form, which §9.4.3 grants only to %e, %f and %g", .{cv.letter});
            if (!consumes(cv.letter)) continue;
            const conv = cv.letter;
            if (next >= tys.len) return; // ran out of operands: E0810's finding, not ours
            const ty = tys[next];
            const arg = live[next];
            next += 1;
            // §9.4.1 gives a null argument one rendering, the space, which
            // `%s` prints; any other conversion would print a value it has not.
            if (arg == .none) {
                if (conv != 's') try self.err(tok, .E0819, "`%{c}` consumes a null argument, which §9.4.1 gives only a space; write `%s`", .{conv});
                continue;
            }
            // What `cg_display.appendConv` renders per (conversion, type):
            //   %d/%b/%o/%h/%x — any type; a string takes §2.7's integer view.
            //   %c             — an integer's low byte (Table 9-22); a real rounds.
            //   %s             — text, or §9.4.5's integer ASCII byte sequence.
            //                    Real operands still need a defined conversion.
            //   %e/%f/%g/%r and the %t/%u/%z/%v decimal defaults — numbers only.
            //   anything else  — the operand's natural form, every type.
            const bad = switch (conv) {
                's' => ty != .string and ty != .integer,
                'c' => ty == .string,
                'e', 'f', 'g', 'r', 't', 'u', 'z', 'v' => ty == .string,
                else => false,
            };
            if (!bad) {
                if (conv == 's') {
                    if (ty == .integer) {
                        vals[next - 1] = try formatOperand(self, arg, .{ .v = vals[next - 1], .ty = ty });
                    } else if (self.mir.valueDef(vals[next - 1]) == .str_const) {
                        // §9.4.5 suppresses leading zero bytes of a literal's
                        // packed byte sequence, before field padding. Stored
                        // strings already exclude every NUL (§3.3).
                        const bytes = self.mir.valueDef(vals[next - 1]).str_const;
                        vals[next - 1] = try self.mir.addStrConst(self.arena, std.mem.trimStart(u8, bytes, &.{0}));
                    }
                } else if ((conv == 'h' or conv == 'x' or conv == 'o' or conv == 'b') and ty == .integer) {
                    // A radix conversion shows the operand's bit pattern at
                    // its own width (1364-2005 §17.1.1.2) with its leading
                    // zeros (§17.1.1.3), and §3.2 makes an `integer` 32 bits:
                    // -5 is fffffffb, 255 is 000000ff (#77). The width is
                    // `intSize`'s, the one `%d` sizes by; an unknown one keeps
                    // the carrier's minimal pattern instead of becoming `%s`'s
                    // E0819 refusal.
                    if (intSize(self, arg)) |size| vals[next - 1] = try self.call("$display$width", &.{
                        vals[next - 1], try self.mir.addIntConst(self.arena, size.bits),
                    });
                } else if (conv == 'd' and ty == .integer and !cv.prefixed) {
                    // A flag or width replaces §17.1.1.3's automatic size.
                    try decimalWidth(self, arg, &vals[next - 1]);
                }
                continue;
            }
            var b = self.errWith(self.file.exprs.mainTok(arg), .E0819);
            b.msg("`%{c}` on a {s} operand", .{ conv, @tagName(ty) });
            if (conv == 's') {
                b.help("print the number with `%g` or `%d`", .{});
            } else if (conv == 'c') {
                b.help("`%c` takes a character code; use `%s` for the text", .{});
            } else {
                b.help("use `%s` for the text, or `%d` for the string's integer value", .{});
            }
            try b.emit();
        }
        at = next;
    }
}

/// How many leading operands of task `c` are not message text: §9.5.2's
/// descriptor, §9.7.3's finish_number, which `cg_display.emitDisplayTask`
/// drops when it is not a string, and §9.7.1's `$finish`/`$stop` level,
/// which `cg_display.finishLevel` reads as a constant.
pub fn messageStart(c: Mir.Callee, tys: []const Ty) usize {
    assert(Mir.callee.takesFormat(c) or Mir.callee.family(c) == .simctl);
    if (Mir.callee.family(c) == .file_out) if (Mir.callee.fdArg(c)) |fd| return @min(tys.len, @as(usize, fd) + 1);
    if (c == .@"$fatal" and tys.len > 0 and tys[0] != .string) return 1;
    // §9.7.1/§9.7.2: `$finish`'s and `$stop`'s one operand is the diagnostic
    // level `finishLevel` reads as a constant, never message text.
    if (c == .@"$finish" or c == .@"$stop") return tys.len;
    return 0;
}

// ---- private ----

/// §9.4.3 `%[flags][width][.precision]conv`: the next conversion at or after
/// `i.*`, `%%` included (letter '%'), with `i.*` moved past it; null when
/// the format ends first. The flags are `str_kernels.zcFlag`'s set, the one
/// `cg_display` and `zSFormatRt` read, so a flag is never taken for the
/// letter (#41); of them only '#' is reported. A digit is read as a digit
/// before as a flag, so the '0' of `%10d` is part of the width while a
/// leading '0' (the flag) adds nothing to it.
fn nextConv(fmt: []const u8, i: *usize) ?Conv {
    assert(i.* <= fmt.len);
    const p = std.mem.findScalarPos(u8, fmt, i.*, '%') orelse return null;
    i.* = p + 1;
    var alt = false;
    var run: u64 = 0; // the number being read: the width, then the precision
    var field: u64 = 0;
    while (i.* < fmt.len) : (i.* += 1) {
        const c = fmt[i.*];
        if (std.ascii.isDigit(c)) {
            run = run *| 10 +| (c - '0');
            field = @max(field, run);
        } else if (c == '.') {
            run = 0;
        } else if (str_k.zcFlag(c)) |f| {
            alt = alt or f == str_k.zc_alt;
            run = 0;
        } else break;
    }
    if (i.* >= fmt.len) return null;
    const letter = std.ascii.toLower(fmt[i.*]);
    const prefixed = i.* > p + 1;
    i.* += 1;
    assert(i.* <= fmt.len);
    return .{ .letter = letter, .alt = alt, .prefixed = prefixed, .field = field };
}

/// §9.4.3: "for each % character (except %m, %% and %l) ... a corresponding
/// expression argument shall be supplied". `%5%` is refused (E0826, #42)
/// and counted as `%%` is, consuming nothing, so E0810 does not add a
/// second finding for it.
fn consumes(letter: u8) bool {
    assert(!std.ascii.isUpper(letter)); // `nextConv` lowercased it
    return letter != '%' and letter != 'm' and letter != 'l';
}

/// Preserve the source integer width before SSA replaces variables with their
/// values. The synthetic identity is consumed by the display formatter only;
/// other conversions still see the same numeric value.
fn formatOperand(self: *Lower, e: Ast.ExprId, tv: TypedValue) Oom!Mir.Value {
    assert(e == .none or self.exprValid(e));
    assert(self.valueValid(tv.v));
    assert(self.blockValid(self.cur));
    const size = intSize(self, e) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0819, "numeric `%s` needs a preserved integral width; this expression's sizing is not implemented", .{});
        return tv.v;
    };
    return self.call("$display$width", &.{ tv.v, try self.mir.addIntConst(self.arena, size.bits) });
}

/// IEEE 1364 §17.1.1.3: "the values written to the output ... are sized
/// automatically", a decimal field as wide as the operand's largest value,
/// which needs its width and signedness (#61): recorded as
/// `$display$width(value, bits, signed)` for `cg_display.decimalField`. A
/// 1-bit result needs one column, which an operand with no record prints.
/// An operand `intSize` cannot size takes an `integer`'s field.
fn decimalWidth(self: *Lower, e: Ast.ExprId, v: *Mir.Value) Oom!void {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    const size = intSize(self, e) orelse integer;
    if (size.bits == 1 and !size.signed) return;
    v.* = try self.call("$display$width", &.{
        v.*,
        try self.mir.addIntConst(self.arena, size.bits),
        try self.mir.addIntConst(self.arena, @intFromBool(size.signed)),
    });
}

/// The width and sign of integer operand `e`, the one rule every display
/// conversion sizes by: `%d`'s field (`decimalWidth`), the radix digits and
/// `%s`'s bytes (#77). IEEE 1364 §5.4.1 Table 5-22 and §5.5.1, read in the
/// analog context: a sized literal keeps its width (§3.5.1), an unsized one
/// is an `integer` (Table 5-22), or 64 bits when its value needs more (§3.5.1
/// "at least 32", VD-124); a relational, equality, logical or reduction
/// result is 1 bit, unsigned; a `reg` or a ranged parameter keeps its own
/// (`identSize`); every other operator over operands of at most 32 bits is
/// an `integer`, because the analog context computes it as one (VD-116).
/// Null when the carrier does not hold the expression's IEEE 1364 bits: an
/// operator over a wider operand (the analog operation wraps it to 32 bits),
/// a `?:` whose narrower arm is signed and the result unsigned (§5.5.2 would
/// zero-extend what the carrier holds sign-extended), a parameter a model
/// card can give another width (VD-089), or a constant past 64 bits.
fn intSize(self: *Lower, e: Ast.ExprId) ?IntSize {
    assert(e == .none or self.exprValid(e));
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => blk: {
            const lit = ex.intLiteral(e);
            if (lit.width > 64) break :blk null;
            if (lit.width != 0) break :blk .{ .bits = @intCast(lit.width), .signed = lit.signed };
            const fits = std.math.cast(i32, lit.value) != null or std.math.cast(u32, lit.value) != null;
            break :blk .{ .bits = if (fits) 32 else 64, .signed = lit.signed };
        },
        .logic_literal => null, // a constant past the carrier, or four-state (E0130)
        .unary => switch (ex.unOp(e)) {
            .plus => intSize(self, ex.lhs(e)),
            .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => one_bit,
            .minus, .bit_not => narrowOperands(self, ex.lhs(e), null),
        },
        .binary => switch (ex.binOp(e)) {
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => one_bit,
            // Table 5-22: the right operand of a shift or `**` is
            // self-determined, so only the left one sizes the result.
            .shl, .shr, .ashl, .ashr, .pow => narrowOperands(self, ex.lhs(e), null),
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => narrowOperands(self, ex.lhs(e), ex.rhs(e)),
        },
        .ternary => blk: {
            const then = intSize(self, ex.rhs(e)) orelse break :blk null;
            const els = intSize(self, ex.ternaryElse(e)) orelse break :blk null;
            // Table 5-22: max(L(j), L(k)); §5.5.1: signed only if both are.
            const signed = then.signed and els.signed;
            const narrow = if (then.bits < els.bits) then else els;
            if (then.bits != els.bits and narrow.signed and !signed) break :blk null;
            break :blk .{ .bits = @max(then.bits, els.bits), .signed = signed };
        },
        .ident => identSize(self, self.file.str(ex.strOf(e))),
        .sys_call => if (Mir.Callee.fromName(self.file.str(ex.strOf(e))) == .@"$realtobits") .{ .bits = 64, .signed = false } else integer,
        else => integer, // else: any other integer-valued expression (a call, a select) is §7.3.1's or §3.2's `integer`
    };
}

/// `integer` when each operand is sized and at most 32 bits wide, the
/// operands the analog context's 32-bit operation keeps whole; else null.
fn narrowOperands(self: *Lower, a: Ast.ExprId, b: ?Ast.ExprId) ?IntSize {
    assert(a == .none or self.exprValid(a));
    if ((intSize(self, a) orelse return null).bits > 32) return null;
    if (b) |r| if ((intSize(self, r) orelse return null).bits > 32) return null;
    return integer;
}

/// A name's width and sign, in `lower_wide.identType`'s order: a variable
/// (only a `reg` has a width of its own), a discrete input with a range, a
/// parameter. An `integer`, an unranged discrete input (Table 7-1 reads it
/// as an integer) and a width past 64 are `integer`. Null for a parameter
/// with no type or range a model card can set, whose width is the card
/// value's (`lower_constfold.hostSizedParam`, VD-089), known only at run time.
fn identSize(self: *Lower, name: []const u8) ?IntSize {
    assert(name.len != 0);
    var w: u32 = 32;
    var signed = true;
    if (self.vars.get(name)) |slot| {
        if (slot.reg_width) |rw| {
            w = rw;
            signed = slot.reg_signed;
        }
    } else if (self.out.discrete_inputs.contains(name)) {
        if (self.reg_ranges.get(name)) |rr| {
            w = rr.width;
            signed = rr.signed;
        }
    } else if (!lower_expr_name.funcParamShadows(self, name)) if (self.param_index.get(name)) |pi| {
        if (lower_constfold.hostSizedParam(self, name) != null) return null;
        const p = self.out.params.items[pi];
        w = p.source_width orelse 32;
        signed = p.source_signed orelse true;
    };
    if (w == 0 or w > 64) return integer;
    assert(w <= 64);
    return .{ .bits = @intCast(w), .signed = signed };
}

test "§9.4.3 nextConv: C11 7.21.6.1's five flags, '#' included, never read as the letter (#41)" {
    const cases = [_]struct { fmt: []const u8, want: []const Conv }{
        .{ .fmt = "%g", .want = &.{.{ .letter = 'g', .alt = false }} },
        .{ .fmt = "%#g", .want = &.{.{ .letter = 'g', .alt = true, .prefixed = true }} },
        .{ .fmt = "%-+ 0#12.3E", .want = &.{.{ .letter = 'e', .alt = true, .prefixed = true }} },
        .{ .fmt = "a%#xb", .want = &.{.{ .letter = 'x', .alt = true, .prefixed = true }} },
        .{ .fmt = "%#m %#l", .want = &.{ .{ .letter = 'm', .alt = true, .prefixed = true }, .{ .letter = 'l', .alt = true, .prefixed = true } } },
        .{ .fmt = "100%% %d", .want = &.{ .{ .letter = '%', .alt = false }, .{ .letter = 'd', .alt = false } } },
        // #42: `%5%`, `%-%` and `%.%` end in '%' with something before it.
        .{ .fmt = "%5% %-% %.%", .want = &.{
            .{ .letter = '%', .alt = false, .prefixed = true },
            .{ .letter = '%', .alt = false, .prefixed = true },
            .{ .letter = '%', .alt = false, .prefixed = true },
        } },
        .{ .fmt = "%#", .want = &.{} }, // the format ends inside the flags
        .{ .fmt = "", .want = &.{} },
    };
    for (cases) |c| {
        var i: usize = 0;
        for (c.want) |w| {
            const got = nextConv(c.fmt, &i) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(w.letter, got.letter);
            try std.testing.expectEqual(w.alt, got.alt);
            try std.testing.expectEqual(w.prefixed, got.prefixed);
        }
        try std.testing.expect(nextConv(c.fmt, &i) == null);
    }
    // #45: the field is the larger of the width and the precision; a '0'
    // inside a number is a digit, a leading one the flag; a u64 overflow
    // saturates.
    const fields = [_]struct { fmt: []const u8, field: u64 }{
        .{ .fmt = "%d", .field = 0 },
        .{ .fmt = "%10d", .field = 10 },
        .{ .fmt = "%010.3f", .field = 10 },
        .{ .fmt = "%3.100e", .field = 100 },
        .{ .fmt = "%.0f", .field = 0 },
        .{ .fmt = "%-+ 0#7g", .field = 7 },
        .{ .fmt = "%99999999999999999999999d", .field = std.math.maxInt(u64) },
    };
    for (fields) |c| {
        var i: usize = 0;
        const got = nextConv(c.fmt, &i) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(c.field, got.field);
    }
    // §9.4.3's count: `%#m` and `%#l` consume nothing, `%#g` one argument.
    try std.testing.expect(!consumes('m') and !consumes('l') and !consumes('%'));
    try std.testing.expect(consumes('g') and consumes('x'));
}

test "§9.4.3/IEEE 1364 §5.4.1 one width rule sizes %h and %d of an integer expression (#77)" {
    // `intSize` is the one rule; this pins what lowering records for each
    // operand, `$display$width(value, bits)` for a radix and
    // `(value, bits, signed)` for `%d`, in conversion order.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module w(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter host = 3;
        \\  integer i;
        \\  analog begin
        \\    i = 255;
        \\    $display("%h %h %h %h %b %h %h %h %h %h %h", i - 300, i * 1, -i, (i > 3) ? i : 0, i & 3,
        \\             -42, 255, 64'h1, 'h1_0000_0000, host, $realtobits(1.5) & 1);
        \\    $display("%d %d %d", (i > 3) ? 8'd5 : 4'd3, host, 'hff);
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());
    const Rec = struct { bits: i64, signed: ?i64 = null };
    const want = [_]Rec{
        // Table 5-22 over 32-bit operands is §3.2's `integer` (VD-116),
        // whatever the operator: i-300, i*1, -i, the `?:` of two integers,
        // i&3, and an unsized literal, negated or not.
        .{ .bits = 32 }, // i - 300
        .{ .bits = 32 }, // i * 1
        .{ .bits = 32 }, // -i
        .{ .bits = 32 }, // (i > 3) ? i : 0
        .{ .bits = 32 }, // i & 3
        .{ .bits = 32 }, // -42
        .{ .bits = 32 }, // 255
        // A sized 64-bit literal, and an unsized one whose value needs more
        // than 32 bits (§3.5.1 "at least 32", VD-124). `host` (a card value
        // has its own width, VD-089) and `&` over $realtobits's 64 bits (the
        // analog operation does not keep them) record nothing.
        .{ .bits = 64 }, // 64'h1
        .{ .bits = 64 }, // 'h1_0000_0000
        // `%d`: max(8, 4) unsigned; `host` falls back to an `integer`'s
        // field; an unsized based literal is unsigned (§3.5.1).
        .{ .bits = 8, .signed = 0 }, // (i > 3) ? 8'd5 : 4'd3
        .{ .bits = 32, .signed = 1 }, // host
        .{ .bits = 32, .signed = 0 }, // 'hff
    };
    var got: std.ArrayList(Rec) = .empty;
    defer got.deinit(std.testing.allocator);
    for (0..h.mir.blockCount()) |bi| {
        const b: Mir.Block = @fromBackingInt(@intCast(bi));
        var it = h.mir.blockInsts(b);
        while (it.next()) |inst| {
            if (h.mir.instOp(inst) != .call) continue;
            const c = h.mir.instData(inst).call;
            if (c.callee != .@"$display$width") continue;
            try got.append(std.testing.allocator, .{
                .bits = h.mir.valueDef(c.args[1]).int_const,
                .signed = if (c.args.len == 3) h.mir.valueDef(c.args[2]).int_const else null,
            });
        }
    }
    try std.testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| {
        try std.testing.expectEqual(w.bits, g.bits);
        try std.testing.expectEqual(w.signed, g.signed);
    }
}
