//! §12.16 vpi_get_value: an object -> its value in a Table 12-4 format. A
//! digital object reads the engine's four-state planes (Figure 12-10's
//! aval/bval, unconverted); a parameter reads its folded constant; an analog
//! call argument reads what the last calltf saw. Also cbValueChange's watch.
//! IEEE 1364-2005 §26.6.19(e): expression and function-call handles evaluate
//! only when read, in their original digital scope, on every request.
//! Cites: VAMS-2023 §12.16, Table 12-4; IEEE 1364-2005 §26.6.13, §26.6.19,
//! §26.6.24, §27.14.
//!
//! Contents:
//! - `pub const Bits = struct`
//! - `pub fn Bits.bit(b: Bits, i: u32) Int.Bit`
//! - `pub fn Bits.known(b: Bits) bool`
//! - `pub fn Bits.low64(b: Bits) u64`
//! - `pub const Store = struct`
//! - `pub fn Store.clear(st: *Store) void`
//! - `pub var get_store: Store`
//! - `pub var cb_store: Store`
//! - `pub fn read(o: *const Obj, v: *Value, st: *Store) void`
//! - `pub fn vpi_get_value(obj: abi.vpiHandle, value_p: ?*Value) void`
//! - `pub fn watch(o: *const Obj) void`

const std = @import("std");
const Int = @import("frontend").Integer;
const digital = @import("sim").digital;
const sim = @import("sim");
const gpa = std.heap.smp_allocator;
const abi = @import("abi.zig");
const analog_call = @import("analog_call.zig");
const callback_fire = @import("callback_fire.zig");
const run = @import("run.zig");
const schema = @import("schema.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const systf = @import("systf.zig");
const trust = @import("trust.zig");
const value_put = @import("value_put.zig");
const value_text = @import("value_text.zig");
const user = @import("vpi_user.zig");
const Obj = schema.Obj;
const StrengthVal = abi.StrengthVal;
const Time = abi.Time;
const Value = abi.Value;
const VecVal = abi.VecVal;

/// Four-state bits, LSB first, as two parallel planes of u64 words — the
/// engine's own layout, so a digital value is borrowed rather than copied.
pub const Bits = struct {
    width: u32,
    val: []const u64,
    unk: []const u64,
    signed: bool,

    pub fn bit(b: Bits, i: u32) Int.Bit {
        const w = i / 64;
        const o: u6 = @truncate(i);
        const v: u2 = @intCast((b.val[w] >> o) & 1);
        const u: u2 = @intCast((b.unk[w] >> o) & 1);
        return @fromBackingInt(@intCast(v | (u << 1)));
    }

    pub fn known(b: Bits) bool {
        return std.mem.allEqual(u64, b.unk, 0);
    }

    /// The low 64 bits with x and z read as 0 — Table 12-4's vpiIntVal rule
    /// "Any bits x or z in the value of the object are mapped to a 0" —
    /// sign-extended from the object's width when it is signed.
    pub fn low64(b: Bits) u64 {
        var x = b.val[0] & ~b.unk[0];
        if (b.width < 64) {
            x &= value_text.lowMask(b.width);
            if (b.signed and b.width > 0 and (x >> @intCast(b.width - 1)) & 1 == 1)
                x |= ~value_text.lowMask(b.width);
        }
        return x;
    }
};

/// One routine's value storage, valid until that routine's next call
/// (§12.16). Callback delivery owns its own (`cb_store`), so a vpi_get_value
/// inside a callback does not clobber the value the callback was handed.
pub const Store = struct {
    str: std.ArrayList(u8) = .empty,
    vec: std.ArrayList(VecVal) = .empty,
    time: Time = std.mem.zeroes(Time),

    /// Frees the storage; `st` stays usable. Invalidates every value it
    /// handed out.
    pub fn clear(st: *Store) void {
        st.str.clearAndFree(gpa);
        st.vec.clearAndFree(gpa);
    }
};

pub var get_store: Store = .{};

/// The store value-change callbacks deliver from.
pub var cb_store: Store = .{};

// Passed by value on every read: two borrowed planes, a width and a sign.
comptime {
    std.debug.assert(@sizeOf(Bits) == 40);
}

/// What an object's value is, when it has one.
const Source = union(enum) {
    bits: Bits,
    real: f64,
    str: []const u8,
};

var const_word: [2]u64 = undefined;

/// Fills `v` from `o` in the format `v.format` names, into `st`'s storage.
/// Errors are recorded (`vpi_chk_error`) and leave `v` as it was.
pub fn read(o: *const Obj, v: *Value, st: *Store) void {
    // §26.6.14/§27.14: a table entry's vector is ASCII symbols, not the
    // ordinary aval/bval representation of a string's packed bits.
    if (o.kind == .code and o.vtype == user.vpiTableEntry and v.format == user.vpiVectorVal) {
        tableVector(o.value.?.str, v, st) catch {
            status.fail("NOMEM", "vpi_get_value: out of memory", .{});
        };
        return;
    }
    // A named event occurs; it holds no value (its slot is a rendezvous).
    if (o.kind == .code and o.vtype == user.vpiNamedEvent) {
        status.fail("NOVALUE", "vpi_get_value: `{s}` is a named event, which has no value", .{o.full});
        return;
    }
    if (v.format == user.vpiStrengthVal) return strength(o, v);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const src = source(o) orelse if (analog_call.argValue(o)) |r| Source{ .real = r } else blk: {
        if (!o.in_analog and !activeCall(o) and o.src_expr != .none and o.expr_scope != .none) if (run.attached()) |r| {
            const instance = session.design.?.scopes[o.expr_scope.get().?].engine;
            const result = r.vpiEval(scratch.allocator(), instance, o.src_expr) catch {
                status.fail("EXPREVAL", "vpi_get_value: cannot evaluate this digital expression", .{});
                return;
            };
            break :blk switch (result) {
                .bits => |lit| literalSource(lit),
                .real => |f| Source{ .real = f },
            };
        };
        status.fail("NOVALUE", "vpi_get_value: `{s}` has no value this process can read", .{o.full});
        return;
    };
    if (v.format == user.vpiObjTypeVal) v.format = switch (src) {
        .real => user.vpiRealVal,
        .str => user.vpiStringVal,
        // §12.16: "For an integer, vpiIntVal ... For a scalar, ... vpiScalar
        // ... For a time variable, vpiTimeVal with vpiSimTime For a vector,
        // vpiVectorVal". An integer PARAMETER is an integer.
        .bits => |b| if (o.kind == .integer or o.value != null) user.vpiIntVal else if (o.kind == .time_var) user.vpiTimeVal else if (b.width == 1) user.vpiScalarVal else user.vpiVectorVal,
    };
    formatInto(src, v, st) catch {
        status.fail("NOMEM", "vpi_get_value: out of memory", .{});
    };
}

/// §12.16. The object must carry a value; the string, vector and time
/// storage belongs to this routine until its next call.
pub export fn vpi_get_value(obj: abi.vpiHandle, value_p: ?*Value) void {
    if (status.refused("vpi_get_value")) return;
    const v = value_p orelse {
        status.fail("BADVALUE", "vpi_get_value: value_p is NULL", .{});
        return;
    };
    // §12.22.1 a derivative object reads back what calltf put on it.
    if (analog_call.asDeriv(obj)) |dv| {
        v.format = user.vpiRealVal;
        v.value.real = dv.value;
        return;
    }
    var o = trust.asObj(obj) orelse {
        status.fail("BADHANDLE", "vpi_get_value: that handle is not an object with a value", .{});
        return;
    };
    // IEEE 1364-2005 §26.6.13: a prim term's value is its terminal's.
    if (o.kind == .code and o.vtype == user.vpiPrimTerm) {
        const e = schema.edgeTo(o, user.vpiExpr);
        if (e == schema.ObjId.none) {
            status.fail("NOVALUE", "vpi_get_value: that terminal's expression is not one this model holds", .{});
            return;
        }
        o = session.design.?.obj(e);
    }
    read(o, v, &get_store);
}

/// Watch `o`'s slot for changes; the engine calls `onChange` for it from now
/// on. Cheap to repeat.
pub fn watch(o: *const Obj) void {
    const r = run.attached() orelse return;
    r.host.change = onChange;
    if (o.slot.get()) |at| r.waits.watch[at].insert(.vpi);
    // An array: every element (§12.31.1 "if the obj is a memory word or a
    // variable array, ... the index field shall contain the index").
    const d = &(session.design orelse return);
    for (schema.coldOf(o).members) |m| if (d.obj(m).slot.get()) |at| r.waits.watch[at].insert(.vpi);
}

// ---- private ----

fn activeCall(o: *const Obj) bool {
    return o.kind == .code and o.vtype == user.vpiSysFuncCall and
        systf.active != null and session.design.?.obj(systf.active.?) == o;
}

fn source(o: *const Obj) ?Source {
    if (schema.coldOf(o).constant_bits) |lit| return literalSource(lit);
    // §26.6.19(b): the active system function's own handle reads its
    // current return value, without recursively invoking its calltf.
    if (activeCall(o)) if (systf.result) |lit| {
        if (systf.active_reg.?.digital.sysfunctype == user.vpiRealFunc) return .{ .real = @bitCast(lit.values()[0]) };
        return literalSource(lit);
    };
    if (o.kind == .code and o.vtype == user.vpiContAssign) return driven(o);
    if (o.slot.get()) |at| {
        const r = run.attached() orelse return null;
        const lit = r.values[at];
        // The engine holds a real as its IEEE 754 bits in the value plane.
        if (r.decls.reals.contains(at)) return .{ .real = @bitCast(lit.planes[0]) };
        return literalSource(lit);
    }
    if (o.value) |c| return switch (c) {
        .int => |i| .{ .bits = constBits(i) },
        .real => |f| .{ .real = f },
        .str => |s| .{ .str = s },
    };
    return null;
}

fn literalSource(lit: Int.Literal) Source {
    return .{ .bits = bitsOf(lit) };
}

/// `lit`'s planes, borrowed.
fn bitsOf(lit: Int.Literal) Bits {
    return .{ .width = lit.width, .val = lit.values(), .unk = lit.unknowns(), .signed = lit.signed };
}

/// IEEE 1364-2005 §26.6.24 cont assign -> value: what its one engine driver
/// drives now. Null when no run holds it, or when its left-hand side is a
/// concatenation, whose drivers each hold a part.
fn driven(o: *const Obj) ?Source {
    const r = run.attached() orelse return null;
    const scope = session.design.?.scope(o.owner).engine;
    var found: ?usize = null;
    for (r.netlist.drivers, 0..) |drv, k| if (drv.tok == o.src_tok and drv.scope == scope) {
        if (found != null) return null;
        found = k;
    };
    const lit = r.netlist.drivers[found orelse return null].current;
    return literalSource(lit);
}

/// A folded integer constant as 32 signed bits: §3.4.1's `integer` parameter.
fn constBits(i: i64) Bits {
    const_word = .{ @bitCast(i), 0 };
    return .{ .width = 32, .val = const_word[0..1], .unk = const_word[1..2], .signed = true };
}

/// IEEE 1364-2005 §27.14: four two-byte ASCII symbols per vecval, first in
/// aval's high half, then its low half, then the two halves of bval. A
/// single-character symbol has a zero second byte; an edge (01) stores 01.
/// `text` is the validated, canonical table decompilation code.zig built.
fn tableVector(text: []const u8, v: *Value, st: *Store) !void {
    st.vec.clearRetainingCapacity();
    var i: usize = 0;
    var n: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == '\t' or c == ':') {
            i += 1;
            continue;
        }
        const symbol: u32 = if (c == '(') (@as(u32, text[i + 1]) << 8) | text[i + 2] else @as(u32, c) << 8;
        i += if (c == '(') @as(usize, 4) else 1;
        if (n % 4 == 0) try st.vec.append(gpa, .{ .aval = 0, .bval = 0 });
        const row = &st.vec.items[n / 4];
        const word = if (n % 4 < 2) &row.aval else &row.bval;
        const shift: u5 = if (n % 2 == 0) 16 else 0;
        word.* = @bitCast(@as(u32, @bitCast(word.*)) | (symbol << shift));
        n += 1;
    }
    v.value.vector = st.vec.items.ptr;
}

/// IEEE 1364-2005 §27.14 vpiStrengthVal: into the application's array, one
/// entry per bit, LSB first. "If the object is a reg or variable, the
/// strength will always be returned as strong."
///
/// ponytail: a net's strength is refused; the engine keeps a net's per-bit
/// strength (`Net.signal`) only on the paths that fold several drivers.
fn strength(o: *const Obj, v: *Value) void {
    const out = v.value.strength orelse {
        status.fail("BADVALUE", "vpi_get_value: vpiStrengthVal with a NULL strength array", .{});
        return;
    };
    const r = run.attached();
    const at = o.slot.get() orelse 0;
    if (o.slot == .none or r == null or r.?.netlist.slot_nets.contains(at) or r.?.decls.reals.contains(at)) {
        status.fail("BADFORMAT", "vpi_get_value: vpiStrengthVal is answered for a reg or integer variable only", .{});
        return;
    }
    const b = bitsOf(r.?.values[at]);
    const bits: [*]StrengthVal = @ptrCast(out);
    for (0..b.width) |i| bits[i] = .{ .logic = scalar(b.bit(@intCast(i))), .s0 = user.vpiStrongDrive, .s1 = user.vpiStrongDrive };
}

fn scalar(b: Int.Bit) c_int {
    return switch (b) {
        .zero => user.vpi0,
        .one => user.vpi1,
        .z => user.vpiZ,
        .x => user.vpiX,
    };
}

fn formatInto(src: Source, v: *Value, st: *Store) !void {
    switch (v.format) {
        user.vpiSuppressVal => {},
        user.vpiBinStrVal, user.vpiOctStrVal, user.vpiHexStrVal, user.vpiDecStrVal, user.vpiStringVal => {
            st.str.clearRetainingCapacity();
            switch (src) {
                .bits => |b| try value_text.radixString(&st.str, b, v.format),
                .real => |f| {
                    // NOTE to Table 12-4: a real "shall be converted to an
                    // integer using the rounding defined by the Verilog-AMS
                    // HDL" before any format but vpiRealVal.
                    if (v.format == user.vpiStringVal) {
                        try st.str.print(gpa, "{d}", .{f});
                    } else try value_text.radixString(&st.str, constBits(value_text.roundAway(f)), v.format);
                },
                .str => |s| {
                    if (v.format != user.vpiStringVal) return badFormat(v.format, "string");
                    try st.str.appendSlice(gpa, s);
                },
            }
            try st.str.append(gpa, 0);
            v.value.str = st.str.items.ptr;
        },
        user.vpiScalarVal => switch (src) {
            .bits => |b| v.value.scalar = scalar(b.bit(0)),
            else => return badFormat(v.format, "non-bit"),
        },
        user.vpiIntVal => v.value.integer = switch (src) {
            .bits => |b| @bitCast(@as(u32, @truncate(b.low64()))),
            .real => |f| @truncate(value_text.roundAway(f)),
            .str => return badFormat(v.format, "string"),
        },
        user.vpiRealVal => v.value.real = switch (src) {
            .bits => |b| value_text.toReal(b),
            .real => |f| f,
            .str => return badFormat(v.format, "string"),
        },
        user.vpiVectorVal => {
            const b = switch (src) {
                .bits => |b| b,
                .real => |f| constBits(value_text.roundAway(f)),
                .str => return badFormat(v.format, "string"),
            };
            const n = (b.width + 31) / 32;
            st.vec.clearRetainingCapacity();
            try st.vec.ensureTotalCapacity(gpa, n);
            for (0..n) |k| {
                const w = k / 2;
                const shift: u6 = if (k % 2 == 0) 0 else 32;
                var a: u32 = @truncate(b.val[w] >> shift);
                var u: u32 = @truncate(b.unk[w] >> shift);
                // Bits past the object's width are not part of it.
                const top = b.width - @as(u32, @intCast(k)) * 32;
                if (top < 32) {
                    const m = (@as(u32, 1) << @intCast(top)) - 1;
                    a &= m;
                    u &= m;
                }
                st.vec.appendAssumeCapacity(.{ .aval = @bitCast(a), .bval = @bitCast(u) });
            }
            v.value.vector = st.vec.items.ptr;
        },
        user.vpiTimeVal => {
            const b = switch (src) {
                .bits => |b| b,
                else => return badFormat(v.format, "non-bit"),
            };
            const x = b.low64();
            st.time = .{ .type = user.vpiSimTime, .high = @truncate(x >> 32), .low = @truncate(x), .real = 0 };
            v.value.time = &st.time;
        },
        else => return badFormat(v.format, "any"),
    }
}

fn badFormat(format: c_int, what: []const u8) error{}!void {
    status.fail("BADFORMAT", "value format {d} is not answered for a {s} value", .{ format, what });
}

fn onChange(_: *digital.Run, slot: u32) void {
    callback_fire.fireSlot(slot);
}

/// The bit-at-a-time spelling `radixString` replaced: the differential
/// tests' oracle.
fn radixOracle(out: *std.ArrayList(u8), b: Bits, format: c_int) !void {
    const g: u32 = switch (format) {
        user.vpiBinStrVal => 1,
        user.vpiOctStrVal => 3,
        user.vpiHexStrVal => 4,
        else => 8,
    };
    var k = (b.width + g - 1) / g;
    while (k > 0) {
        k -= 1;
        var xs: u32 = 0;
        var zs: u32 = 0;
        var d: u8 = 0;
        var i = @min(k * g + g, b.width);
        while (i > k * g) {
            i -= 1;
            const bit = b.bit(i);
            d = (d << 1) | @intFromBool(bit == .one);
            xs += @intFromBool(bit == .x);
            zs += @intFromBool(bit == .z);
        }
        const n = @min(k * g + g, b.width) - k * g;
        if (g == 8) {
            if (d != 0) try out.append(gpa, d);
        } else try out.append(gpa, if (xs == n) 'x' else if (zs == n) 'z' else if (xs != 0) 'X' else if (zs != 0) 'Z' else "0123456789abcdef"[d]);
    }
}

test "Table 12-4: an octal or hex group that is all x/z prints x/z, a partly unknown one X/Z" {
    // msb..lsb 1 x 0 1 z z z z: value plane 1101_0000, unknown plane
    // 0100_1111 (Figure 12-10: 1/1 is x, 0/1 is z).
    const val = [1]u64{0xD0};
    const unk = [1]u64{0x4F};
    const b: Bits = .{ .width = 8, .val = &val, .unk = &unk, .signed = false };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // Hex groups [7:4] = 1x01 (partly x), [3:0] = zzzz. Octal groups [7:6] =
    // 1x, [5:3] = 01z (partly z, no x), [2:0] = zzz. Decimal reads the whole
    // value as one group: partly x.
    for ([_]struct { c_int, []const u8 }{
        .{ user.vpiBinStrVal, "1x01zzzz" },
        .{ user.vpiHexStrVal, "Xz" },
        .{ user.vpiOctStrVal, "XZz" },
        .{ user.vpiDecStrVal, "X" },
    }) |case| {
        out.clearRetainingCapacity();
        try value_text.radixString(&out, b, case[0]);
        try std.testing.expectEqualStrings(case[1], out.items);
    }
    // All z, all x: lower case, in every radix.
    const zeros = [1]u64{0};
    const all = [1]u64{0xFF};
    for ([_]struct { []const u64, u8 }{ .{ &zeros, 'z' }, .{ &all, 'x' } }) |case| {
        for ([_]c_int{ user.vpiOctStrVal, user.vpiHexStrVal, user.vpiDecStrVal }) |format| {
            out.clearRetainingCapacity();
            try value_text.radixString(&out, .{ .width = 8, .val = case[0], .unk = &all, .signed = false }, format);
            for (out.items) |c| try std.testing.expectEqual(case[1], c);
        }
    }
}

test "Table 12-4 vpiIntVal: x/z read as 0, a signed value sign-extends from its width" {
    var st: Store = .{};
    defer st.clear();
    var v: Value = std.mem.zeroes(Value);
    v.format = user.vpiIntVal;
    const val = [1]u64{0b1010};
    const known = [1]u64{0};
    const x1 = [1]u64{0b0010};
    // 1010 signed is -6, unsigned 10; with bit 1 x it reads 1000: -8.
    try formatInto(.{ .bits = .{ .width = 4, .val = &val, .unk = &known, .signed = true } }, &v, &st);
    try std.testing.expectEqual(@as(c_int, -6), v.value.integer);
    try formatInto(.{ .bits = .{ .width = 4, .val = &val, .unk = &known, .signed = false } }, &v, &st);
    try std.testing.expectEqual(@as(c_int, 10), v.value.integer);
    try formatInto(.{ .bits = .{ .width = 4, .val = &val, .unk = &x1, .signed = true } }, &v, &st);
    try std.testing.expectEqual(@as(c_int, -8), v.value.integer);
}

test "Table 12-4 vpiVectorVal: 32-bit words, bits past the width cleared" {
    var st: Store = .{};
    defer st.clear();
    var v: Value = std.mem.zeroes(Value);
    v.format = user.vpiVectorVal;
    // 36 bits of ones, with garbage above them in the plane: two words, the
    // second holding the top 4 bits.
    const val = [1]u64{std.math.maxInt(u64)};
    const unk = [1]u64{0};
    try formatInto(.{ .bits = .{ .width = 36, .val = &val, .unk = &unk, .signed = false } }, &v, &st);
    try std.testing.expectEqual(@as(usize, 2), st.vec.items.len);
    try std.testing.expectEqual(@as(c_int, -1), v.value.vector[0].aval);
    try std.testing.expectEqual(@as(c_int, 0xF), v.value.vector[1].aval);
    try std.testing.expectEqual(@as(c_int, 0), v.value.vector[1].bval);
}

test "IEEE 1364-2005 §27.14: a table entry's vector is two-byte symbols, four per vecval" {
    var st: Store = .{};
    defer st.clear();
    var v: Value = std.mem.zeroes(Value);
    // Symbols `(01)`, `0`, `1`: aval's high half, aval's low half, bval's
    // high half. An edge stores both characters, a level its one in the
    // high byte.
    try tableVector("(01) 0 : 1", &v, &st);
    try std.testing.expectEqual(@as(usize, 1), st.vec.items.len);
    try std.testing.expectEqual(@as(u32, 0x3031_3000), @as(u32, @bitCast(v.value.vector[0].aval)));
    try std.testing.expectEqual(@as(u32, 0x3100_0000), @as(u32, @bitCast(v.value.vector[0].bval)));
    // A fifth symbol starts a second vecval.
    try tableVector("1 1 1 1 : 0", &v, &st);
    try std.testing.expectEqual(@as(usize, 2), st.vec.items.len);
    try std.testing.expectEqual(@as(u32, 0x3000_0000), @as(u32, @bitCast(v.value.vector[1].aval)));
}

test "Table 12-4 string formats: widths 0..200 at every offset, against the bit-at-a-time oracle" {
    var prng: std.Random.DefaultPrng = .init(0x1364);
    const random = prng.random();
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    var planes: [2 * 5]u64 = undefined;
    for (0..201) |width| {
        // Dense x/z, sparse, and none; then every value bit set.
        for (0..4) |round| {
            for (&planes) |*w| w.* = random.int(u64);
            const val = planes[0..4];
            const unk = planes[5..9];
            switch (round) {
                0 => {},
                1 => for (unk) |*u| {
                    u.* &= random.int(u64) & random.int(u64);
                },
                2 => @memset(unk, 0),
                else => {
                    @memset(val, ~@as(u64, 0));
                    @memset(unk, 0);
                },
            }
            // A misaligned start: the planes begin one word in.
            const b: Bits = .{ .width = @intCast(width), .val = planes[round % 2 ..][0..4], .unk = planes[5 + round % 2 ..][0..4], .signed = false };
            for ([_]c_int{ user.vpiBinStrVal, user.vpiOctStrVal, user.vpiHexStrVal, user.vpiStringVal }) |format| {
                got.clearRetainingCapacity();
                want.clearRetainingCapacity();
                try value_text.radixString(&got, b, format);
                try radixOracle(&want, b, format);
                try std.testing.expectEqualStrings(want.items, got.items);
            }
            // A binary string a get wrote, x and z included, puts back the
            // same planes, masked to the width.
            got.clearRetainingCapacity();
            try value_text.radixString(&got, b, user.vpiBinStrVal);
            try got.append(gpa, 0);
            var v: Value = std.mem.zeroes(Value);
            v.format = user.vpiBinStrVal;
            v.value.str = got.items.ptr;
            const n = @max(1, (width + 63) / 64);
            var back: [8]u64 = undefined;
            try value_put.toPlanes(&v, @intCast(width), back[0 .. 2 * n]);
            for (0..n) |w| {
                const m = value_text.lowMask(@intCast(@min(64, width - 64 * w)));
                try std.testing.expectEqual(b.val[w] & m, back[w]);
                try std.testing.expectEqual(b.unk[w] & m, back[n + w]);
            }
        }
    }
}
