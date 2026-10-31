//! §12.10 vpi_get_analog_value and §12.7-§12.9's time, step and frequency:
//! a node, branch or quantity -> its value at the bound library's solution,
//! in a Table 12-2 format.
//! Cites: VAMS-2023 §5.4.1, §12.7-§12.10, Table 12-2; ISO C11 7.21.6.1
//! (%e, %g).
//!
//! Contents:
//! - `pub const ValueError = error`
//! - `pub const Value = struct`
//! - `pub fn vpi_get_analog_value(obj: abi.vpiHandle, value_p: ?*AnalogValue) void`
//! - `pub fn vpi_get_analog_time() f64`
//! - `pub fn vpi_get_analog_delta() f64`
//! - `pub fn vpi_get_analog_freq() f64`

const std = @import("std");
const Lowered = @import("ir").Lowered;
const ground = @import("ir").Lowered.ground;
const abi = @import("abi.zig");
const analog = @import("analog.zig");
const schema = @import("schema.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const user = @import("vpi_user.zig");
const Binding = @import("Binding.zig");
const AnalogValue = abi.AnalogValue;
const Obj = schema.Obj;

/// `NoAnalysis`: no library or no solution yet. `NoSolution`: the library
/// holds no value of this quantity (an unknown or row past what it
/// publishes: a calls-only `Lib`). `Unknowable`: a flow the device does not
/// publish. `SmallSignal`: a flow source's flow at an AC point, which this
/// host does not linearise per row.
pub const ValueError = error{ NoAnalysis, NoSolution, Unknowable, SmallSignal };

/// §11.6.7 a quantity's "real value" and "imaginary value".
pub const Value = struct { re: f64, im: f64 = 0 };

/// §12.10's own string buffers, real and imaginary.
var analog_buf: [2][analog_len]u8 = undefined;

/// The longest part Table 12-2 can spell, sentinel included. vpiDecStrVal is
/// Zig's shortest round-trip decimal: at most 17 significant digits, so a
/// value of at least 1 has at most 309 integer digits and no fraction, and one
/// below 1 is "0." then at most 323 zeros (5e-324) then its digits. With the
/// sign that is 1 + 2 + 323 + 17; %e and %g are shorter.
const analog_len = 1 + 2 + 323 + 17 + 1;

/// "shall retrieve the simulation value of VPI analog vpiFlow or vpiPotential
/// (node or branch) quantity objects. The value shall be placed in an
/// s_vpi_analog_value structure, which has been allocated by the user."
///
/// A non-quantity object or a NULL structure is refused. The value is the
/// current solution of analog.zig's analysis; with none, the error is
/// NOANALYSIS, and a flow the model cannot tell from a parallel branch's is
/// SHARED. An instance's unnamed branch over a pair other instances also
/// drive reads its own share. The imaginary part is 0 except at an AC point
/// (`quantityValue`).
pub export fn vpi_get_analog_value(obj: abi.vpiHandle, value_p: ?*AnalogValue) void {
    _ = status.enter("vpi_get_analog_value") orelse return;
    const o = status.object("vpi_get_analog_value", obj) orelse return;
    if (o.kind != .quantity) {
        status.fail("NOTQUANTITY", "vpi_get_analog_value: a {s} is not a vpiFlow or vpiPotential quantity", .{@tagName(o.kind)});
        return;
    }
    const v = value_p orelse {
        status.fail("BADVALUE", "vpi_get_analog_value: value_p is NULL", .{});
        return;
    };
    const val = quantityValue(o) catch |e| {
        switch (e) {
            error.NoAnalysis => status.fail("NOANALYSIS", "vpi_get_analog_value: no analysis has solved this quantity in this process", .{}),
            error.NoSolution => status.fail("NOSOLUTION", "vpi_get_analog_value: no solution is attached: the host's analog library publishes no value of this quantity", .{}),
            // Two named branches over one pair, or an instance that drives
            // the pair only through another's branch (§5.6.8.2): the model
            // has no row of this branch's own to read.
            error.Unknowable => status.fail("SHARED", "vpi_get_analog_value: this branch's flow cannot be told apart from a parallel branch's", .{}),
            error.SmallSignal => status.fail("NOTSUPPORTED", "vpi_get_analog_value: the small-signal flow of a flow contribution is not computed at an AC point; its potentials are", .{}),
        }
        return;
    };
    switch (v.format) {
        user.vpiRealVal => {
            v.real = .{ .real = val.re };
            v.imaginary = .{ .real = val.im };
        },
        user.vpiExpStrVal, user.vpiDecStrVal, user.vpiStringVal => {
            // Table 12-2. The strings live in THIS routine's buffer — "different
            // from the buffer which vpi_get_str() shall use" and "overwritten
            // with each call".
            // vpiStringVal: "The call shall reset the format field to
            // vpiExpStrVal or vpiDecStrVal to the selected format." The real
            // part's choice is the one reported.
            var chose: c_int = v.format;
            var im_chose: c_int = v.format;
            const a = analogString(&analog_buf[0], val.re, v.format, &chose) orelse return;
            const b = analogString(&analog_buf[1], val.im, v.format, &im_chose) orelse return;
            v.format = chose;
            v.real.str = a;
            v.imaginary.str = b;
        },
        else => status.fail("BADFORMAT", "vpi_get_analog_value: format {d} is not one of Table 12-2's", .{v.format}),
    }
}

/// §12.9 "the time of the solution attempted or of the latest converged and
/// accepted solution otherwise. The function shall return zero (0) during DC
/// or the time zero transient solution."
pub export fn vpi_get_analog_time() f64 {
    if (status.refused("vpi_get_analog_time")) return 0;
    if (analog.current) |a| if (a.kind != .tran) return 0;
    return analog.t_now;
}

/// §12.7 "the elapsed time between the latest converged and accepted
/// solution and the solution being calculated. The function shall return
/// zero (0) during DC or the time zero transient solution." Inside an
/// acceptance callback the solution "being calculated" is the one just
/// accepted, so it is the step that reached it.
pub export fn vpi_get_analog_delta() f64 {
    if (status.refused("vpi_get_analog_delta")) return 0;
    if (analog.current) |a| if (a.kind != .tran) return 0;
    return analog.delta;
}

/// §12.8 "the current frequency used in the small-signal analysis. The
/// function shall return zero (0) during DC or transient analysis." Nonzero
/// only at an AC sweep's small-signal points, not at its operating point.
pub export fn vpi_get_analog_freq() f64 {
    if (status.refused("vpi_get_analog_freq")) return 0;
    return analog.freq;
}

// ---- private ----

fn unknownAt(x: [*]const f64, row: u32) f64 {
    return if (row == ground) 0 else x[row];
}

/// Whether `bi`'s `Lib.x` holds `row`: ground reads 0 and needs no slot.
fn holds(bi: *const Binding, row: u32) bool {
    return row == ground or row < bi.n_x;
}

/// Returns quantity `q`'s value (§11.6.7): at an AC point the small-signal
/// phasor, elsewhere the large-signal value with imaginary part 0. A
/// potential is the difference of two unknowns. A flow is an unknown for a
/// potential source, and for a flow source the §5.6 row the device publishes
/// (`codegen.Options.vpi_contribs`): resistive part plus the backward-Euler
/// derivative of the reactive part over the step being solved. When several
/// instances' unnamed branches share the row, it is this instance's own share
/// (`vpiShares`, §5.4.1), the same way.
fn quantityValue(q: *const Obj) ValueError!Value {
    const bi = analog.bound() orelse return error.NoAnalysis;
    const l = bi.lib orelse return error.NoAnalysis;
    const d = &session.design.?;
    const flow_u = bi.flow_u;
    const b = schema.coldOf(&d.objects[schema.coldOf(q).branch orelse return error.NoAnalysis]);
    // The library is outside data: every slot read below is checked against
    // what it published, before the solution is.
    if (!holds(bi, b.hi_row) or !holds(bi, b.lo_row)) return error.NoSolution;
    if (b.contrib_pot) |k| if (k >= flow_u.len or (flow_u[k] >= 0 and @as(usize, @intCast(flow_u[k])) >= bi.n_x)) return error.NoSolution;
    if (b.contrib_flow != null and flow_u.len == 0) return error.NoSolution;
    if (!bi.have_solution) return error.NoAnalysis;
    const ac = analog.freq != 0;
    const x = if (ac) bi.ac_x.ptr else l.x();
    const xi = bi.ac_x[bi.ac_x.len / 2 ..].ptr;
    const is_flow = b.flow != null and &d.objects[b.flow.?] == q;
    if (!is_flow) return .{
        .re = unknownAt(x, b.hi_row) - unknownAt(x, b.lo_row),
        .im = if (ac) unknownAt(xi, b.hi_row) - unknownAt(xi, b.lo_row) else 0,
    };
    if (b.flow_unknowable) return error.Unknowable;
    const sign: f64 = if (b.flow_neg) -1 else 1;
    if (b.contrib_pot) |k| {
        if (flow_u[k] < 0) return error.Unknowable;
        const u: usize = @intCast(flow_u[k]);
        return .{ .re = sign * x[u], .im = if (ac) sign * xi[u] else 0 };
    }
    if (b.contrib_flow) |row| {
        if (ac) return error.SmallSignal;
        bi.refreshRows(l);
        // A share's values follow the rows'.
        const k = if (b.contrib_share) |sh| flow_u.len + sh else row;
        if (2 * k + 1 >= bi.now_vals.len) return error.Unknowable;
        var v = bi.now_vals[2 * k];
        if (analog.delta > 0) v += (bi.now_vals[2 * k + 1] - bi.prev_react[k]) / analog.delta;
        return .{ .re = sign * v };
    }
    // §5.6.1.3: a branch with no source retains nothing, and is an open
    // circuit — its flow is zero.
    return .{ .re = 0 };
}

/// One part of an analog value as Table 12-2 spells it: vpiExpStrVal "like
/// printf %e", vpiDecStrVal "decimal char(s)", vpiStringVal "like printf
/// %g" — reporting which of the other two %g chose in `chose`.
fn analogString(buf: *[analog_len]u8, x: f64, format: c_int, chose: *c_int) ?[*:0]u8 {
    const text = switch (format) {
        user.vpiExpStrVal => printfE(buf, x, 6),
        user.vpiDecStrVal => std.mem.printSentinel(buf, "{d}", .{x}, 0) catch null,
        user.vpiStringVal => printfG(buf, x, chose),
        else => null,
    } orelse {
        status.fail("BADFORMAT", "vpi_get_analog_value: {e} does not fit the value buffer", .{x});
        return null;
    };
    return @constCast(text.ptr);
}

/// C's `%.<prec>e`: one digit, the fraction, `e`, a sign and at least two
/// exponent digits. Zig's `{e}` rounds correctly and spells the exponent
/// bare (`2.5e-3`), so only the exponent is re-spelled.
fn printfE(buf: *[analog_len]u8, x: f64, prec: usize) ?[:0]const u8 {
    if (!std.math.isFinite(x)) return nonFinite(buf, x);
    var tmp: [64]u8 = undefined;
    const e = splitE(&tmp, x, prec) orelse return null;
    return spellE(buf, e.mantissa, e.exp);
}

/// Zig's `{e:.<prec>}` of finite `x`, written into `tmp`, split at its `e`.
fn splitE(tmp: *[64]u8, x: f64, prec: usize) ?struct { mantissa: []const u8, exp: i32 } {
    const raw = std.mem.print(tmp, "{e:.[1]}", .{ x, prec }) catch return null;
    const at = std.mem.findScalar(u8, raw, 'e') orelse return null;
    const exp = std.fmt.parseInt(i32, raw[at + 1 ..], 10) catch return null;
    return .{ .mantissa = raw[0..at], .exp = exp };
}

/// C's exponent spelling after `mantissa`: `e`, a sign, at least two digits.
fn spellE(buf: *[analog_len]u8, mantissa: []const u8, exp: i32) ?[:0]const u8 {
    const sign: u8 = if (exp < 0) '-' else '+';
    return std.mem.printSentinel(buf, "{s}e{c}{d:0>2}", .{ mantissa, sign, @abs(exp) }, 0) catch null;
}

/// C's `%g` (precision 6): %e when the exponent is below -4 or at least 6,
/// %f otherwise, trailing zeros and a bare point dropped. `chose` becomes
/// vpiExpStrVal or vpiDecStrVal after the form taken.
fn printfG(buf: *[analog_len]u8, x: f64, chose: *c_int) ?[:0]const u8 {
    if (x == 0) {
        chose.* = user.vpiDecStrVal;
        return std.mem.printSentinel(buf, "0", .{}, 0) catch null;
    }
    // An infinity or NaN has no exponent to choose a style by.
    if (!std.math.isFinite(x)) {
        chose.* = user.vpiDecStrVal;
        return nonFinite(buf, x);
    }
    var tmp: [64]u8 = undefined;
    const e = splitE(&tmp, x, 5) orelse return null;
    if (e.exp < -4 or e.exp >= 6) {
        chose.* = user.vpiExpStrVal;
        return spellE(buf, dropZeros(e.mantissa), e.exp);
    }
    chose.* = user.vpiDecStrVal;
    const decimals: usize = @intCast(5 - e.exp);
    const fixed = std.mem.print(&tmp, "{d:.[1]}", .{ x, decimals }) catch return null;
    return std.mem.printSentinel(buf, "{s}", .{dropZeros(fixed)}, 0) catch null;
}

/// %g's trailing zeros of a fraction, and then a bare point, dropped.
fn dropZeros(digits: []const u8) []const u8 {
    if (std.mem.findScalar(u8, digits, '.') == null) return digits;
    return std.mem.trimEnd(u8, std.mem.trimEnd(u8, digits, "0"), ".");
}

// C11 7.21.6.1's spelling of an infinity or a NaN under %e and %g: `[-]inf`,
// `[-]nan`, the sign from the sign bit. Zig's `{e}` writes the same words but
// has no exponent for the callers above to re-spell.
fn nonFinite(buf: *[analog_len]u8, x: f64) ?[:0]const u8 {
    const word: []const u8 = if (std.math.isNan(x)) "nan" else "inf";
    const sign: []const u8 = if (std.math.signbit(x)) "-" else "";
    return std.mem.printSentinel(buf, "{s}{s}", .{ sign, word }, 0) catch null;
}

test "§12.10 Table 12-2: vpiExpStrVal is C's %e, two exponent digits and a sign" {
    var buf: [analog_len]u8 = undefined;
    // Hand-derived as C's printf("%e") spells each.
    for ([_]struct { f64, []const u8 }{
        .{ 1234.5, "1.234500e+03" },
        .{ -0.00025, "-2.500000e-04" },
        .{ 0, "0.000000e+00" },
        .{ 1e100, "1.000000e+100" },
    }) |case| try std.testing.expectEqualStrings(case[1], printfE(&buf, case[0], 6) orelse "(refused)");
}

test "§12.10 Table 12-2: vpiStringVal is C's %g, and reports the form it took" {
    var buf: [analog_len]u8 = undefined;
    // C11 7.21.6.1 %g at precision 6: style e when the exponent is below -4
    // or at least 6, else style f with 5 - exponent fraction digits; then
    // trailing zeros and a bare point go. 9999999 rounds up into 1e+07.
    for ([_]struct { f64, []const u8, c_int }{
        .{ 0, "0", user.vpiDecStrVal },
        .{ 2.5, "2.5", user.vpiDecStrVal },
        .{ -1.5, "-1.5", user.vpiDecStrVal },
        .{ 100, "100", user.vpiDecStrVal },
        .{ 123456, "123456", user.vpiDecStrVal },
        .{ 1234567, "1.23457e+06", user.vpiExpStrVal },
        .{ 9999999, "1e+07", user.vpiExpStrVal },
        .{ 0.0001, "0.0001", user.vpiDecStrVal },
        .{ 0.00001, "1e-05", user.vpiExpStrVal },
    }) |case| {
        var chose: c_int = 0;
        try std.testing.expectEqualStrings(case[1], printfG(&buf, case[0], &chose) orelse "(refused)");
        try std.testing.expectEqual(case[2], chose);
    }
}

test "§12.10 Table 12-2: a non-finite value is C's inf, -inf or nan in the e and g forms" {
    // C11 7.21.6.1: "A double argument representing an infinity is converted
    // in one of the styles [-]inf or [-]infinity ... A double argument
    // representing a NaN is converted in one of the styles [-]nan". %g of
    // one has no exponent, so it reports vpiDecStrVal.
    var buf: [analog_len]u8 = undefined;
    for ([_]struct { f64, []const u8 }{
        .{ std.math.inf(f64), "inf" },
        .{ -std.math.inf(f64), "-inf" },
        .{ std.math.nan(f64), "nan" },
    }) |case| {
        var chose: c_int = 0;
        try std.testing.expectEqualStrings(case[1], printfE(&buf, case[0], 6) orelse "(refused)");
        try std.testing.expectEqualStrings(case[1], printfG(&buf, case[0], &chose) orelse "(refused)");
        try std.testing.expectEqual(user.vpiDecStrVal, chose);
    }
}

test "§12.10 analogString: vpiDecStrVal is the shortest decimal; another format is refused" {
    var buf: [analog_len]u8 = undefined;
    var chose: c_int = 0;
    const text = analogString(&buf, 0.5, user.vpiDecStrVal, &chose) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("0.5", std.mem.span(text));
    try std.testing.expect(analogString(&buf, 0.5, 99, &chose) == null);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
}

test "§12.10 Table 12-2: every finite real spells whole in the value buffer" {
    var chose: c_int = 0;
    var buf: [analog_len]u8 = undefined;
    for ([_]f64{ std.math.floatMax(f64), -std.math.floatMax(f64), -std.math.floatTrueMin(f64), -std.math.floatMin(f64), -1.2345678901234567e-300, 1e308 }) |x| {
        for ([_]c_int{ user.vpiDecStrVal, user.vpiExpStrVal, user.vpiStringVal }) |f| {
            const t = analogString(&buf, x, f, &chose) orelse return error.TestUnexpectedResult;
            const text = std.mem.span(t);
            const back = try std.fmt.parseFloat(f64, text);
            // %e and %g keep 6 or 7 digits; the decimal keeps every one.
            if (f == user.vpiDecStrVal) try std.testing.expectEqual(x, back) else try std.testing.expectApproxEqRel(x, back, 1e-5);
        }
    }
}

test "§12.7-§12.9, §12.36 with no library: nothing to run, reject or re-solve" {
    analog.setPoint(null, 0, 0, 0);
    var b: Binding = .{};
    try std.testing.expectError(error.NoLibrary, b.run(.{ .kind = .op }));
    try std.testing.expect(!analog.rejectStep());
    try std.testing.expect(!analog.failConverge());
    try std.testing.expect(analog.analysis() == null);
    try std.testing.expectEqual(@as(f64, 0), analog.acceptedTime());
    try std.testing.expectEqual(@as(f64, 0), vpi_get_analog_freq());
    try std.testing.expectEqual(@as(f64, 0), vpi_get_analog_delta());
    try std.testing.expectEqual(@as(f64, 0), vpi_get_analog_time());
    const q: Obj = .{ .kind = .quantity, .owner = .none, .name = "", .full = "" };
    try std.testing.expectError(error.NoAnalysis, quantityValue(&q));
}

test "holds: a calls-only library holds no unknown, ground needs none" {
    var b: Binding = .{};
    try std.testing.expect(holds(&b, ground));
    try std.testing.expect(!holds(&b, 0));
    b.n_x = 2;
    try std.testing.expect(holds(&b, 1));
    try std.testing.expect(!holds(&b, 2));
}
