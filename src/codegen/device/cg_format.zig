//! A §9.4.2/§9.4.3 format string and its operands -> `std.fmt` text and the
//! print operands it reads: each conversion's Zig spec (flags, width,
//! precision), IEEE 1364 §17.1.1.3's automatic decimal field, the per-operand
//! scratch a composed field needs, and each operand rendered in the type its
//! conversion wants.
//! Cites: §9.4.2, §9.4.3 (Table 9-23), IEEE 1364 §17.1.1.3.
//!
//! Contents:
//! - `pub const PrintArg = struct`
//! - `pub const Spec = struct`
//! - `pub const WidthRecord = struct`
//! - `pub fn decimalField(g: *Gen, v: Mir.Value) ?usize`
//! - `pub fn translateFormat(g: *Gen, src: []const u8, operands: []const Mir.Value, fmt: *std.ArrayList(u8), ops: *cg_display.Ops) Error!usize`
//! - `pub fn fieldCols(r: WidthRecord) usize`
//! - `pub fn appendConv(g: *Gen, fmt: *std.ArrayList(u8), ops: *cg_display.Ops, operand: Mir.Value, conv_raw: u8, spec_arg: Spec) Error!void`
//! - `pub fn renderPrintArg(g: *Gen, p: PrintArg, i: usize) Error!void`
//! - members: `PrintArg.Mode`, `PrintArg.scratch`, `PrintArg.onStack`, `PrintArg.textMax`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const VTy = Analysis.VTy;
const strcap = @import("cg_strcap.zig");
const str_real = @import("kernels").str_real;
const cg_display = @import("cg_display.zig");

/// One rendered `std.debug.print` operand: the value, the Zig type the chosen
/// conversion needs it in, and HOW it is rendered. `%h` on a real is a
/// real→integer conversion (§4.2.1.1), not a reinterpretation, so `want` is
/// not always the value's own type.
pub const PrintArg = struct {
    v: Mir.Value,
    want: VTy,
    how: Mode = .plain,
    spec: Spec = .{},
    /// `.creal`: the source's conversion letter, case kept, because `%E`/`%G`
    /// print the exponent marker and INF/NAN in upper case.
    conv: u8 = 0,
    /// Original integer width, before SSA and the i64 storage carrier.
    bits: u7 = 64,
    /// Where this operand's `{…}` starts in the call's Zig format text: a
    /// call with more operands than one `std.fmt` call takes is split here.
    at: usize = 0,

    /// How `renderPrintArg` spells the operand: which helper, if any, sits
    /// between the value and the Zig format verb.
    pub const Mode = enum {
        /// Straight through the Zig verb the conversion mapped to.
        plain,
        /// §9.4.3 `%c`: the operand's low byte (Table 9-22 "display as an
        /// ASCII character"), narrowed to the `u8` Zig's `{c}` takes.
        chr,
        /// `%<width>d` with no sign/zero flag: render the decimal TEXT through
        /// `zPadInt` and pad it as a string. See `emitDisplayTask` for why.
        pad,
        /// `%+d` / `% d` / `%0<width>d`: C puts the sign inside the field
        /// (`+42`, ` 42`, `-0042`), which no Zig format spec can spell, so the
        /// field text is composed in per-op scratch and printed as `{s}`.
        cint,
        /// §9.4.3 Table 9-23's real conversions (`%e`, `%f`, `%g`, engineering
        /// `%r`) through `str_real.zCReal`, which follows C11 7.21.6.1
        /// (round half to even) where Zig's float verbs do not. The kernel
        /// composes the whole field, sign and padding included.
        creal,
        /// `%h`/`%o`/`%b`: the two's-complement bit pattern of the operand.
        /// Zig's radix verbs on an i64 print `-2a` instead, hence a u64
        /// bitcast around the rendered integer.
        bits,
        /// §9.4.5: most-significant byte first, with leading zero bytes removed.
        ascii,
    };

    /// Bytes of per-op scratch the emitted block declares, or null for the
    /// modes that render straight into the print's argument tuple.
    /// Lowering bounds every width and precision a source writes at 2^30
    /// (E0828, #45); the sums saturate besides, so no spec can overflow
    /// them, and a saturated row is E1011's (`fits`).
    pub fn scratch(self: PrintArg) ?usize {
        return switch (self.how) {
            .ascii => @sizeOf(i64),
            .pad => 24, // i64's widest decimal (20 chars) plus slack
            .cint => @max(24, self.spec.width +| 2), // the full zero-filled field
            // The widest `%f` body is a sign, f64's 309 integer digits, the
            // point and the precision; the field can be wider still.
            .creal => @max(self.spec.width, self.spec.p(6) +| 320) +| 8,
            else => null,
        };
    }

    /// Whether the scratch is a stack array (`max_stack`) or a static row,
    /// which the emitted block holds as a pointer.
    pub fn onStack(self: PrintArg) bool {
        // The widest scratch a field of `max_stack` width and precision
        // takes: `.creal`'s.
        const most = Spec.max_stack + 320 + 8;
        comptime assert(most > Spec.max_stack);
        return (self.scratch() orelse 0) <= most;
    }

    /// How the emitted block names the scratch as a slice: `&zb<i>` for the
    /// stack array, `zb<i>` for the static row's pointer.
    fn amp(self: PrintArg) []const u8 {
        return if (self.onStack()) "&" else "";
    }

    /// The most bytes this operand renders, field padding included: the
    /// composed modes' scratch, a radix's 64 digits, f64's widest decimal, a
    /// string operand's capacity (`cg_strcap`).
    pub fn textMax(self: PrintArg, g: *Gen) Error!u64 {
        const body: u64 = switch (self.how) {
            .creal, .pad, .cint, .ascii => self.scratch().?,
            .bits => 64,
            .chr => 1,
            .plain => switch (self.want) {
                .int => 20,
                .real => std.fmt.float.bufferSize(.decimal, f64),
                .str => try strcap.cap(g, self.v),
                .wide => unreachable, // lowering hands a task no wide value: a whole wide `reg` read is E0222
            },
        };
        const most = @max(body, self.spec.width);
        assert(most >= self.spec.width);
        return most;
    }
};

/// Parsed §9.4.3 conversion prefix: `%[flags][width][.precision]conv`. Table
/// 9-23 grants the real conversions "the full formatting capabilities
/// available in the C language", so C11 7.21.6.1 defines each flag; the
/// integer conversions share the grammar. Width and precision are numbers
/// because the composed C-style fields need them as arithmetic.
pub const Spec = struct {
    /// '-' left-justify; C makes it override '0'.
    left: bool = false,
    /// '+' always spell the sign.
    plus: bool = false,
    /// ' ' a space where the sign would be; '+' wins.
    space: bool = false,
    /// '0' pad with zeros AFTER the sign.
    zero: bool = false,
    /// '#' C's alternative form; lowering admits it on %e/%f/%g only (E0825).
    alt: bool = false,
    /// The field width; 0 = no width given.
    width: usize = 0,
    /// The precision; null = no precision given.
    prec: ?usize = null,

    // The scratch for a composed field is a stack array in the emitted block
    // up to what a field of this width and precision needs; a wider field's
    // scratch is a static row (`str_store.zSRow`), so no field makes a
    // huge frame (`PrintArg.onStack`).
    const max_stack = 4096;
    fn p(self: Spec, default: usize) usize {
        return self.prec orelse default;
    }
};

/// The width lowering recorded on a display operand (`$display$width`,
/// analog/systask.zig): `bits`, and whether the operand is signed, which
/// only a `%d` record states (a radix shows the bit pattern either way).
pub const WidthRecord = struct { bits: u7, signed: bool };

/// IEEE 1364 §17.1.1.3's automatic decimal field for `%d` (and §9.4.3's
/// bare default) of `v`: the columns of the largest value it can hold, its
/// sign included, so a 32-bit `integer` is 11 ("-2147483648"), as the
/// digital engine prints it (`kernels/fmt.zig` `autoWidth`). Lowering
/// records an integer operand's width and sign (`systask.decimalWidth`); a
/// real is the 64-bit signed integer it converts to, 20 columns
/// (docs/specification/Vague_Decisions.md VD-120). Null for an integer with no
/// record (a 1-bit result, or a sink lowering does not size), a string
/// operand (§2.7's integer has no fixed width) and a one-column field.
pub fn decimalField(g: *Gen, v: Mir.Value) ?usize {
    const r: WidthRecord = switch (g.an.tyOf(g.an.rv(v))) {
        .int => widthRecord(g, v) orelse return null,
        .real => .{ .bits = 64, .signed = true },
        .str, .wide => return null,
    };
    const cols = fieldCols(r);
    assert(cols >= 1);
    return if (cols > 1) cols else null;
}

/// Translates one §9.4.2/§9.4.3 format string into `std.fmt` text appended to
/// `fmt` (literal `{`/`}` doubled), appending one `PrintArg` per conversion.
/// Returns how many of `operands` were consumed, so the §9.4.1 walk resumes
/// after them. A conversion with no operand renders 0.0; §9.4.3 makes that a
/// pairing violation, which `Lower.checkFormatPairing` diagnoses.
pub fn translateFormat(
    g: *Gen,
    src: []const u8,
    operands: []const Mir.Value,
    fmt: *std.ArrayList(u8),
    ops: *cg_display.Ops,
) Error!usize {
    const a = g.arena;
    const ops_before = ops.items.len;
    var next: usize = 0;
    var i: usize = 0;
    var steps: usize = 0;
    while (i < src.len) : (steps += 1) {
        // Every pass consumes at least one byte of `src`.
        assert(steps <= i);
        assert(steps < src.len);
        const c = src[i];
        if (c == '{' or c == '}') { // std.fmt's own escape
            try fmt.append(a, c);
            try fmt.append(a, c);
            i += 1;
            continue;
        }
        if (c != '%') {
            try fmt.append(a, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= src.len) break;
        if (src[i] == '%') { // §9.4.3 `%%` is a literal percent
            try fmt.append(a, '%');
            i += 1;
            continue;
        }
        // §9.4.3 `%[flags][width][.precision]conv`: the C prefix Table 9-23
        // grants. Parsed into numbers here; `appendConv` decides per
        // conversion whether Zig can spell it or a composed field is needed.
        var spec: Spec = .{};
        while (i < src.len) : (i += 1) switch (str_real.zcFlag(src[i]) orelse break) {
            str_real.zc_left => spec.left = true,
            str_real.zc_plus => spec.plus = true,
            str_real.zc_space => spec.space = true,
            str_real.zc_zero => spec.zero = true,
            str_real.zc_alt => spec.alt = true,
            else => unreachable, // `zcFlag` returns one of the five bits
        };
        const width_at = i;
        while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
        // An overflow saturates; lowering has refused any field past 2^30
        // (E0828), so only a format it never judged could reach that.
        if (i > width_at)
            spec.width = std.fmt.parseUnsigned(usize, src[width_at..i], 10) catch std.math.maxInt(usize);
        if (i < src.len and src[i] == '.') {
            i += 1;
            const prec_at = i;
            while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
            spec.prec = std.fmt.parseUnsigned(usize, src[prec_at..i], 10) catch std.math.maxInt(usize);
        }
        if (i >= src.len) break;
        const conv = src[i];
        i += 1;
        // §9.4.2's `%%` is two characters; lowering refuses a flag, width or
        // precision before the second `%` (E0826, #42), so none reaches here
        // to be taken for a consuming conversion.
        assert(conv != '%');
        // §9.4.3 `%m` names the enclosing module, and `%l` consumes no operand
        // either: "for each % character (except %m, %% and %l) … a
        // corresponding expression argument shall be supplied".
        if (conv == 'm' or conv == 'M') {
            try fmt.appendSlice(a, g.mir.name);
            continue;
        }
        // Table 9-22's `%l` is "library.cell". A Verilog-A source takes no
        // library map (`vera --libmap` configures a .v design), and IEEE
        // 1364-2005 §13.2.1 compiles a file no map matches "into a library
        // named work"; the cell is the module, as `%m` names it. The digital
        // runner prints the same shape (`work.top`).
        if (conv == 'l' or conv == 'L') {
            try fmt.appendSlice(a, "work.");
            try fmt.appendSlice(a, g.mir.name);
            continue;
        }
        const operand = if (next < operands.len) operands[next] else Mir.Value.f_zero;
        next += 1;
        try appendConv(g, fmt, ops, operand, conv, spec);
    }
    // Every scan stops at the end of `src`, and each consuming conversion
    // appended exactly one operand.
    assert(i == src.len);
    assert(ops.items.len - ops_before == next);
    return @min(next, operands.len);
}

/// The decimal columns of record `r`'s largest value: 2^bits - 1 unsigned,
/// -2^(bits-1) signed (its magnitude's digits plus the sign).
pub fn fieldCols(r: WidthRecord) usize {
    assert(r.bits >= 1);
    assert(r.bits <= 64);
    const most: u64 = if (r.signed) @as(u64, 1) << @intCast(r.bits - 1) else @as(u64, std.math.maxInt(u64)) >> @intCast(@as(u8, 64) - r.bits);
    const cols = std.math.log10_int(most) + 1 + @intFromBool(r.signed);
    assert(cols >= 1);
    assert(cols <= 20);
    return cols;
}

/// Appends one conversion's `{…}` to `fmt` and its operand to `ops`.
/// `conv_raw == 0` means the §9.4.3 default: the operand's natural form.
/// Asserts that `conv_raw` is not `%` (a `%%` is literal text) and that a
/// default conversion comes with an empty spec.
pub fn appendConv(
    g: *Gen,
    fmt: *std.ArrayList(u8),
    ops: *cg_display.Ops,
    operand: Mir.Value,
    conv_raw: u8,
    spec_arg: Spec,
) Error!void {
    assert(conv_raw != '%');
    if (conv_raw == 0) assert(std.meta.eql(spec_arg, Spec{}));
    const a = g.arena;
    const v = operand;
    const rec = widthRecord(g, v);
    const bits: u7 = if (rec) |r| r.bits else 64;
    const conv = std.ascii.toLower(conv_raw);
    const ty = g.an.tyOf(g.an.rv(v));
    // §9.4.3 a bare operand is "the default decimal format", `%d`'s field.
    if (conv == 0 and ty == .int) return appendConv(g, fmt, ops, operand, 'd', spec_arg);
    // IEEE 1364 §17.1.1.3 automatic sizing: the radices "always" show leading
    // zeros at a width lowering recorded, a decimal field pads with spaces to
    // the largest value's columns (`decimalField`), and `%0h`/`%0d` (the '0'
    // flag with no width) "overrides" both.
    var spec = spec_arg;
    if (spec.width == 0 and !spec.zero and !spec.left and !spec.plus and !spec.space) switch (conv) {
        'h', 'x' => if (rec != null) {
            spec = .{ .width = (@as(usize, bits) + 3) / 4, .zero = true };
        },
        'o' => if (rec != null) {
            spec = .{ .width = (@as(usize, bits) + 2) / 3, .zero = true };
        },
        'b' => if (rec != null) {
            spec = .{ .width = bits, .zero = true };
        },
        'd' => if (decimalField(g, v)) |cols| {
            spec = .{ .width = cols };
        },
        else => {},
    };
    const at = fmt.items.len;
    const ops_before = ops.items.len;
    switch (conv) {
        // §9.4.3 Table 9-23's four real conversions "have the full formatting
        // capabilities available in the C language"; `%r` adds §2.6.2's
        // engineering notation. One kernel composes the whole field. An
        // integer operand converts to real first (§4.2.1.1).
        'e', 'f', 'g', 'r' => {
            try fmt.appendSlice(a, "{s}");
            try ops.append(a, .{ .at = at, .v = v, .want = .real, .how = .creal, .spec = spec, .conv = conv_raw });
        },
        // §9.4.3 Table 9-22: a radix conversion shows the operand's
        // two's-complement bit pattern at its width (IEEE 1364 §17.1.1.2):
        // the width lowering recorded (`systask.intSize`, 32 for an `integer`
        // or an unsized literal, §3.2), so `%h` of integer -5 is fffffffb, and
        // an operand with no record its minimal digits. `.bits` bitcasts to u64
        // because Zig's `{x}` on an i64 writes `-2a`. A real rounds first
        // (§4.2.1.1). An unsigned field has no sign, so the spec passes through.
        'b', 'o', 'h', 'x' => {
            try fmt.append(a, '{');
            try fmt.append(a, if (conv == 'h') 'x' else conv);
            try appendZigSpec(g, fmt, spec, null);
            try fmt.append(a, '}');
            try ops.append(a, .{ .at = at, .v = v, .want = .int, .how = .bits, .spec = spec, .bits = bits });
        },
        // Table 9-22 gives %c the single character: the operand's low byte,
        // whatever its type (a string goes through its §2.7 integer value).
        'c' => {
            try fmt.appendSlice(a, "{c");
            try appendZigSpec(g, fmt, spec, null);
            try fmt.append(a, '}');
            try ops.append(a, .{ .at = at, .v = v, .want = .int, .how = .chr, .spec = spec });
        },
        's' => {
            if (ty == .int) {
                try appendStrField(g, fmt, spec, false);
            } else {
                try fmt.appendSlice(a, "{s");
                try appendZigSpec(g, fmt, spec, null);
                try fmt.append(a, '}');
            }
            try ops.append(a, .{ .at = at, .v = v, .want = ty, .how = if (ty == .int) .ascii else .plain, .spec = spec, .bits = bits });
        },
        'd' => {
            // §2.7 makes a string literal an unsigned base-256 integer when
            // used as an operand, so `$strobe("%d", "\n")` prints 10;
            // `renderVal(.int)` does the digits.
            const zero_fill = spec.zero and !spec.left and spec.width > 0;
            if (spec.plus or spec.space or zero_fill) {
                // C 7.21.6.1: '+'/' ' put a sign character in the field and
                // '0' packs zeros between sign and digits (`+42`, ` 42`,
                // `-0042`). Zig's `{d:0>5}` writes `00-42`, so the field is
                // composed in scratch (`renderPrintArg`'s .cint arm).
                try appendStrField(g, fmt, spec, zero_fill);
                try ops.append(a, .{ .at = at, .v = v, .want = .int, .how = .cint, .spec = spec });
            } else if (spec.width > 0) {
                // A width alone makes std.fmt spell the sign (`{d:>5}` writes
                // `+42`), so the decimal TEXT pads instead, via `zPadInt`.
                try appendStrField(g, fmt, spec, false);
                try ops.append(a, .{ .at = at, .v = v, .want = .int, .how = .pad, .spec = spec });
            } else {
                try fmt.appendSlice(a, "{d}");
                try ops.append(a, .{ .at = at, .v = v, .want = .int, .spec = spec });
            }
        },
        else => {
            // The Zig verb for the remaining conversions. `conv == 0` on a
            // real or string is §9.4.3's "default decimal format" in the
            // value's own type (an integer took `%d` above; a real's
            // shortest round trip is `buildArgs`'s deviation); a string prints its text,
            // which every `CHECK` macro's `%s` depends on. `%t`/`%u`/`%z`/`%v`
            // are rows an analog device has no data for; they print the value.
            const verb: []const u8 = switch (conv) {
                's' => "s",
                't', 'u', 'z', 'v' => "d",
                else => if (ty == .str) "s" else "d",
            };
            try fmt.append(a, '{');
            try fmt.appendSlice(a, verb);
            try appendZigSpec(g, fmt, spec, null);
            try fmt.append(a, '}');
            try ops.append(a, .{ .at = at, .v = v, .want = ty, .spec = spec });
        },
    }
    // One `{…}` and one operand per conversion.
    assert(ops.items.len == ops_before + 1);
    assert(fmt.items.len > at);
}

/// Emits operand `i` of a print's argument tuple. A real crosses into the
/// format layer through `.val()`. The `.ascii`/`.cint` arms emit labeled block
/// expressions whose scratch is the `zb{i}` array `emitScratch` declared.
pub fn renderPrintArg(g: *Gen, p: PrintArg, i: usize) Error!void {
    const len_before = g.out.items.len;
    // `appendConv` pairs every helper mode with the type it reads.
    switch (p.how) {
        .pad, .cint, .chr, .bits, .ascii => assert(p.want == .int),
        .creal => assert(p.want == .real),
        .plain => {},
    }
    switch (p.how) {
        .ascii => {
            // Mask the i64 carrier to the source width so sign extension adds
            // no characters. Only leading zero bytes vanish; interior and
            // trailing NULs are data.
            try g.b("zs{d}: {{ std.mem.writeInt(u64, &zb{d}, @as(u{d}, @truncate(@as(u64, @bitCast(@as(i64, ", .{ i, i, p.bits });
            try g.renderVal(p.v, .int);
            try g.b("))))), .big); break :zs{d} std.mem.trimStart(u8, &zb{d}, &.{{0}}); }}", .{ i, i });
        },
        .pad => {
            try g.b("zPadInt(&zb{d}, ", .{i});
            try g.renderVal(p.v, .int);
            try g.b(")", .{});
        },
        .bits => {
            // The pattern at the operand's own width (`PrintArg.bits`): §3.2
            // makes an `integer` 32 bits, so -5 is fffffffb, not sixteen digits.
            if (p.bits < 64) try g.b("@as(u{d}, @truncate(", .{p.bits});
            try g.b("@as(u64, @bitCast(@as(i64, ", .{});
            try g.renderVal(p.v, .int);
            try g.b(")))", .{});
            if (p.bits < 64) try g.b("))", .{});
        },
        .chr => {
            try g.b("@as(u8, @truncate(@as(u64, @bitCast(@as(i64, ", .{});
            try g.renderVal(p.v, .int);
            try g.b(")))))", .{});
        },
        .cint => {
            // C 7.21.6.1 sign placement. Zero-fill: zeros go after the sign,
            // so each branch prints its sign and pads |v| to what is left.
            // @abs on an i64 returns u64, so minInt needs no special case.
            // Without zero-fill the outer `{s:>W}` does any padding.
            const sign: []const u8 = if (p.spec.plus) "+" else if (p.spec.space) " " else "";
            const w = p.spec.width;
            // A zero-filled field has a width, so `w - 1` leaves room for the sign.
            const zero_fill = p.spec.zero and !p.spec.left and w > 0;
            try g.b("zi{d}: {{ const zv: i64 = ", .{i});
            try g.renderVal(p.v, .int);
            if (zero_fill) {
                // @abs in both branches: Zig spells `+42` for a signed int
                // once a width fixes the field; a u64 has no sign to spell.
                try g.b("; if (zv < 0) break :zi{d} std.mem.print({s}zb{d}, \"-{{d:0>{d}}}\", .{{@abs(zv)}}) catch unreachable", .{ i, p.amp(), i, w - 1 });
                try g.b("; break :zi{d} std.mem.print({s}zb{d}, \"{s}{{d:0>{d}}}\", .{{@abs(zv)}}) catch unreachable; }}", .{ i, p.amp(), i, sign, w - sign.len });
            } else {
                try g.b("; break :zi{d} std.mem.print({s}zb{d}, \"{{s}}{{d}}\", .{{ if (zv < 0) \"\" else \"{s}\", zv }}) catch unreachable; }}", .{ i, p.amp(), i, sign });
            }
        },
        .creal => {
            // C11 7.21.6.1's flag bits, `str_real.zc_*`: 1 '-', 2 '+',
            // 4 ' ', 8 '0', 16 '#'. The kernel composes the whole field.
            assert(p.conv != 0); // the source's letter: 'e', 'f', 'g' or 'r', either case
            const flags: u8 = (if (p.spec.left) str_real.zc_left else 0) |
                (if (p.spec.plus) str_real.zc_plus else 0) |
                (if (p.spec.space) str_real.zc_space else 0) |
                (if (p.spec.zero) str_real.zc_zero else 0) |
                (if (p.spec.alt) str_real.zc_alt else 0);
            try g.b("zCReal({s}zb{d}, (", .{ p.amp(), i });
            try g.renderVal(p.v, .real);
            try g.b(").val(), '{c}', {d}, {d}, {d})", .{
                p.conv,
                flags,
                p.spec.width,
                if (p.spec.prec) |pr| @as(i64, @intCast(pr)) else -1,
            });
        },
        .plain => switch (p.want) {
            .real => {
                try g.b("(", .{});
                try g.renderVal(p.v, .real);
                try g.b(").val()", .{});
            },
            .int => try g.renderVal(p.v, .int),
            .str => try g.renderVal(p.v, .str),
            .wide => unreachable, // lowering hands a task no wide value: a whole wide `reg` read is E0222
        },
    }
    assert(g.out.items.len > len_before);
}

// ---- private ----

/// The Zig `:[fill][align][width][.precision]` tail, for the conversions whose
/// C and Zig renderings agree (radix on an unsigned, `%f`, `%g`, `%s`, `%c`).
/// Emits nothing when the source gave nothing. `extra_prec` is `%f`'s C
/// default of six decimals, applied only when the source did not say
/// otherwise.
fn appendZigSpec(g: *Gen, fmt: *std.ArrayList(u8), spec: Spec, extra_prec: ?[]const u8) Error!void {
    const a = g.arena;
    if (spec.width == 0 and spec.prec == null and extra_prec == null) return;
    const len_before = fmt.items.len;
    var buf: [48]u8 = undefined;
    // `.{d}` of any usize fits, so the prints below cannot fail.
    comptime assert(buf.len >= std.math.log10_int(@as(usize, std.math.maxInt(usize))) + 2);
    try fmt.append(a, ':');
    if (spec.width > 0) {
        // Zig's fill/alignment are only meaningful WITH a width.
        if (spec.zero) try fmt.append(a, '0');
        try fmt.append(a, if (spec.left) '<' else '>');
        try fmt.appendSlice(a, std.mem.print(&buf, "{d}", .{spec.width}) catch unreachable);
    }
    if (spec.prec) |p| {
        try fmt.appendSlice(a, std.mem.print(&buf, ".{d}", .{p}) catch unreachable);
    } else if (extra_prec) |p| {
        try fmt.appendSlice(a, p);
    }
    // The ':' and at least one of width, precision or `extra_prec`.
    assert(fmt.items.len > len_before + 1);
}

/// `{s}` with the outer alignment, for a field composed in per-op scratch
/// (`.cint`, `.pad`, `.ascii`). `full` marks a field already exactly its width
/// (a zero-filled integer), which no outer alignment may touch.
fn appendStrField(g: *Gen, fmt: *std.ArrayList(u8), spec: Spec, full: bool) Error!void {
    const a = g.arena;
    const len_before = fmt.items.len;
    if (full or spec.width == 0) return fmt.appendSlice(a, "{s}");
    var buf: [48]u8 = undefined;
    // `{s:<W}` of any usize W fits.
    comptime assert(buf.len >= std.math.log10_int(@as(usize, std.math.maxInt(usize))) + 1 + 5);
    try fmt.appendSlice(a, std.mem.print(&buf, "{{s:{c}{d}}}", .{
        @as(u8, if (spec.left) '<' else '>'), spec.width,
    }) catch unreachable);
    assert(fmt.items.len >= len_before + "{s:>0}".len);
}

fn widthRecord(g: *Gen, v: Mir.Value) ?WidthRecord {
    const def = g.mir.valueDef(g.an.rv(v));
    if (def != .inst_result) return null;
    const data = g.mir.instData(def.inst_result);
    if (data != .call or data.call.callee != .@"$display$width") return null;
    // (value, width) for a radix or `%s`, (value, width, signed) for `%d`.
    const args = data.call.args;
    assert(args.len == 2 or args.len == 3);
    const bits = g.mir.valueDef(args[1]).int_const;
    assert(bits >= 1);
    assert(bits <= 64);
    return .{ .bits = @intCast(bits), .signed = args.len == 3 and g.mir.valueDef(args[2]).int_const != 0 };
}

test fieldCols {
    // Against the largest values written out by hand.
    const cases = [_]struct { r: WidthRecord, cols: usize }{
        .{ .r = .{ .bits = 32, .signed = true }, .cols = 11 }, // -2147483648
        .{ .r = .{ .bits = 64, .signed = true }, .cols = 20 }, // -9223372036854775808
        .{ .r = .{ .bits = 12, .signed = false }, .cols = 4 }, // 4095
        .{ .r = .{ .bits = 64, .signed = false }, .cols = 20 }, // 18446744073709551615
        .{ .r = .{ .bits = 8, .signed = true }, .cols = 4 }, // -128
        .{ .r = .{ .bits = 1, .signed = false }, .cols = 1 }, // 1
    };
    for (cases) |c| try std.testing.expectEqual(c.cols, fieldCols(c.r));
}
