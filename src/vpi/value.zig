//! §12.16 vpi_get_value, §12.30 vpi_put_value and cbValueChange delivery, in
//! every Table 12-4 format. A digital object reads the engine's four-state
//! planes (Figure 12-10's aval/bval, unconverted); a parameter reads its folded
//! constant; an analog call argument or derivative object reads what the last
//! calltf saw or put. Node and branch values are §12.10's, in `analog.zig`.
//! Puts go through the engine's write path, so they wake waiting processes
//! and fire value-change callbacks as a procedural assignment does.
//! IEEE 1364-2005 §26.6.19(e): expression and function-call handles evaluate
//! only when read, in their original digital scope, on every request.

const std = @import("std");
const sim = @import("sim");
const Int = @import("frontend").Integer;
const root = @import("root.zig");
const coldOf = root.coldOf;
const property = @import("property.zig");
const handle = @import("handle.zig");
const systf = @import("systf.zig");
const callback = @import("callback.zig");
const run = @import("run.zig");
const analog = @import("analog.zig");

const digital = sim.digital;
const exec = digital.exec;
const Obj = root.Obj;
const Value = callback.Value;
const VecVal = callback.VecVal;
const Time = callback.Time;
const vpiHandle = root.vpiHandle;

// Table 12-4 formats, Annex G numbering.
pub const vpiBinStrVal: c_int = 1;
pub const vpiOctStrVal: c_int = 2;
pub const vpiDecStrVal: c_int = 3;
pub const vpiHexStrVal: c_int = 4;
pub const vpiScalarVal: c_int = 5;
pub const vpiIntVal: c_int = 6;
pub const vpiRealVal: c_int = 7;
pub const vpiStringVal: c_int = 8;
pub const vpiVectorVal: c_int = 9;
pub const vpiStrengthVal: c_int = 10;
pub const vpiTimeVal: c_int = 11;
pub const vpiObjTypeVal: c_int = 12;
pub const vpiSuppressVal: c_int = 13;

// vpiScalarVal values.
pub const vpi0: c_int = 0;
pub const vpi1: c_int = 1;
pub const vpiZ: c_int = 2;
pub const vpiX: c_int = 3;
pub const vpiH: c_int = 4;
pub const vpiL: c_int = 5;

/// IEEE 1364-2005 Annex G's strength of a reg or variable.
pub const vpiStrongDrive: c_int = 0x40;

// §12.30 flags.
pub const vpiNoDelay: c_int = 1;
pub const vpiInertialDelay: c_int = 2;
pub const vpiTransportDelay: c_int = 3;
pub const vpiPureTransportDelay: c_int = 4;
pub const vpiForceFlag: c_int = 5;
pub const vpiReleaseFlag: c_int = 6;
pub const vpiCancelEvent: c_int = 7;
pub const vpiReturnEvent: c_int = 0x1000;

pub const vpiSchedEvent: c_int = 53;
pub const vpiScheduled: c_int = 46;

const gpa = std.heap.smp_allocator;

// ---------------------------------------------------------------------------
// A value, as read
// ---------------------------------------------------------------------------

/// Four-state bits, LSB first, as two parallel planes of u64 words — the
/// engine's own layout, so a digital value is borrowed rather than copied.
const Bits = struct {
    width: u32,
    val: []const u64,
    unk: []const u64,
    signed: bool,

    fn bit(b: Bits, i: u32) Int.Bit {
        const w = i / 64;
        const o: u6 = @truncate(i);
        const v: u2 = @intCast((b.val[w] >> o) & 1);
        const u: u2 = @intCast((b.unk[w] >> o) & 1);
        return @fromBackingInt(@intCast(v | (u << 1)));
    }

    fn known(b: Bits) bool {
        return std.mem.allEqual(u64, b.unk, 0);
    }

    /// The low 64 bits with x and z read as 0 — Table 12-4's vpiIntVal rule
    /// "Any bits x or z in the value of the object are mapped to a 0" —
    /// sign-extended from the object's width when it is signed.
    fn low64(b: Bits) u64 {
        var x = b.val[0] & ~b.unk[0];
        if (b.width < 64) {
            x &= lowMask(b.width);
            if (b.signed and b.width > 0 and (x >> @intCast(b.width - 1)) & 1 == 1)
                x |= ~lowMask(b.width);
        }
        return x;
    }
};

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

fn activeCall(o: *const Obj) bool {
    return o.kind == .code and o.vtype == root.code.vpiSysFuncCall and
        systf.active != null and &root.design.?.objects[systf.active.?] == o;
}

fn source(o: *const Obj) ?Source {
    if (coldOf(o).constant_bits) |lit| return literalSource(lit);
    // §26.6.19(b): the active system function's own handle reads its
    // current return value, without recursively invoking its calltf.
    if (activeCall(o)) if (systf.result) |lit| {
        if (systf.active_reg.?.digital.sysfunctype == systf.vpiRealFunc) return .{ .real = @bitCast(lit.values()[0]) };
        return literalSource(lit);
    };
    if (o.kind == .code and o.vtype == root.code.vpiContAssign) return driven(o);
    if (o.slot.get()) |at| {
        const r = run.attached() orelse return null;
        const lit = r.values[at];
        // The engine holds a real as its IEEE 754 bits in the value plane.
        if (r.reals.contains(at)) return .{ .real = @bitCast(lit.planes[0]) };
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
    const scope = root.design.?.scopes[o.owner.get().?].engine;
    var found: ?usize = null;
    for (r.drivers, 0..) |drv, k| if (drv.tok == o.src_tok and drv.scope == scope) {
        if (found != null) return null;
        found = k;
    };
    const lit = r.drivers[found orelse return null].current;
    return literalSource(lit);
}

var const_word: [2]u64 = undefined;

/// A folded integer constant as 32 signed bits: §3.4.1's `integer` parameter.
fn constBits(i: i64) Bits {
    const_word = .{ @bitCast(i), 0 };
    return .{ .width = 32, .val = const_word[0..1], .unk = const_word[1..2], .signed = true };
}

// ---------------------------------------------------------------------------
// The formats
// ---------------------------------------------------------------------------

/// One routine's value storage, valid until that routine's next call
/// (§12.16). Callback delivery owns its own (`cb_store`), so a vpi_get_value
/// inside a callback does not clobber the value the callback was handed.
pub const Store = struct {
    str: std.ArrayList(u8) = .empty,
    vec: std.ArrayList(VecVal) = .empty,
    time: Time = std.mem.zeroes(Time),

    /// Frees the storage; `st` stays usable. Invalidates every value it
    /// handed out.
    fn clear(st: *Store) void {
        st.str.clearAndFree(gpa);
        st.vec.clearAndFree(gpa);
    }
};

var get_store: Store = .{};
/// The store value-change callbacks deliver from.
pub var cb_store: Store = .{};

/// Fills `v` from `o` in the format `v.format` names, into `st`'s storage.
/// Errors are recorded (`vpi_chk_error`) and leave `v` as it was.
pub fn read(o: *const Obj, v: *Value, st: *Store) void {
    // §26.6.14/§27.14: a table entry's vector is ASCII symbols, not the
    // ordinary aval/bval representation of a string's packed bits.
    if (o.kind == .code and o.vtype == root.code.vpiTableEntry and v.format == vpiVectorVal) {
        tableVector(o.value.?.str, v, st) catch {
            root.fail("NOMEM", "vpi_get_value: out of memory", .{});
        };
        return;
    }
    // A named event occurs; it holds no value (its slot is a rendezvous).
    if (o.kind == .code and o.vtype == root.code.vpiNamedEvent) {
        root.fail("NOVALUE", "vpi_get_value: `{s}` is a named event, which has no value", .{o.full});
        return;
    }
    if (v.format == vpiStrengthVal) return strength(o, v);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const src = source(o) orelse if (analog.argValue(o)) |r| Source{ .real = r } else blk: {
        if (!o.in_analog and !activeCall(o) and o.src_expr != .none and o.expr_scope != .none) if (run.attached()) |r| {
            const instance = root.design.?.scopes[o.expr_scope.get().?].engine;
            const result = r.vpiEval(scratch.allocator(), instance, o.src_expr) catch {
                root.fail("EXPREVAL", "vpi_get_value: cannot evaluate this digital expression", .{});
                return;
            };
            break :blk switch (result) {
                .bits => |lit| literalSource(lit),
                .real => |f| Source{ .real = f },
            };
        };
        root.fail("NOVALUE", "vpi_get_value: `{s}` has no value this process can read", .{o.full});
        return;
    };
    if (v.format == vpiObjTypeVal) v.format = switch (src) {
        .real => vpiRealVal,
        .str => vpiStringVal,
        // §12.16: "For an integer, vpiIntVal ... For a scalar, ... vpiScalar
        // ... For a time variable, vpiTimeVal with vpiSimTime For a vector,
        // vpiVectorVal". An integer PARAMETER is an integer.
        .bits => |b| if (o.kind == .integer or o.value != null) vpiIntVal else if (o.kind == .time_var) vpiTimeVal else if (b.width == 1) vpiScalarVal else vpiVectorVal,
    };
    formatInto(src, v, st) catch {
        root.fail("NOMEM", "vpi_get_value: out of memory", .{});
    };
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
        root.fail("BADVALUE", "vpi_get_value: vpiStrengthVal with a NULL strength array", .{});
        return;
    };
    const r = run.attached();
    const at = o.slot.get() orelse 0;
    if (o.slot == .none or r == null or r.?.net_of.contains(at) or r.?.reals.contains(at)) {
        root.fail("BADFORMAT", "vpi_get_value: vpiStrengthVal is answered for a reg or integer variable only", .{});
        return;
    }
    const b = bitsOf(r.?.values[at]);
    const bits: [*]callback.StrengthVal = @ptrCast(out);
    for (0..b.width) |i| bits[i] = .{ .logic = scalar(b.bit(@intCast(i))), .s0 = vpiStrongDrive, .s1 = vpiStrongDrive };
}

fn scalar(b: Int.Bit) c_int {
    return switch (b) {
        .zero => vpi0,
        .one => vpi1,
        .z => vpiZ,
        .x => vpiX,
    };
}

fn formatInto(src: Source, v: *Value, st: *Store) !void {
    switch (v.format) {
        vpiSuppressVal => {},
        vpiBinStrVal, vpiOctStrVal, vpiHexStrVal, vpiDecStrVal, vpiStringVal => {
            st.str.clearRetainingCapacity();
            switch (src) {
                .bits => |b| try radixString(&st.str, b, v.format),
                .real => |f| {
                    // NOTE to Table 12-4: a real "shall be converted to an
                    // integer using the rounding defined by the Verilog-AMS
                    // HDL" before any format but vpiRealVal.
                    if (v.format == vpiStringVal) {
                        try st.str.print(gpa, "{d}", .{f});
                    } else try radixString(&st.str, constBits(roundAway(f)), v.format);
                },
                .str => |s| {
                    if (v.format != vpiStringVal) return badFormat(v.format, "string");
                    try st.str.appendSlice(gpa, s);
                },
            }
            try st.str.append(gpa, 0);
            v.value.str = st.str.items.ptr;
        },
        vpiScalarVal => switch (src) {
            .bits => |b| v.value.scalar = scalar(b.bit(0)),
            else => return badFormat(v.format, "non-bit"),
        },
        vpiIntVal => v.value.integer = switch (src) {
            .bits => |b| @bitCast(@as(u32, @truncate(b.low64()))),
            .real => |f| @truncate(roundAway(f)),
            .str => return badFormat(v.format, "string"),
        },
        vpiRealVal => v.value.real = switch (src) {
            .bits => |b| toReal(b),
            .real => |f| f,
            .str => return badFormat(v.format, "string"),
        },
        vpiVectorVal => {
            const b = switch (src) {
                .bits => |b| b,
                .real => |f| constBits(roundAway(f)),
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
        vpiTimeVal => {
            const b = switch (src) {
                .bits => |b| b,
                else => return badFormat(v.format, "non-bit"),
            };
            const x = b.low64();
            st.time = .{ .type = callback.vpiSimTime, .high = @truncate(x >> 32), .low = @truncate(x), .real = 0 };
            v.value.time = &st.time;
        },
        else => return badFormat(v.format, "any"),
    }
}

fn badFormat(format: c_int, what: []const u8) error{}!void {
    root.fail("BADFORMAT", "value format {d} is not answered for a {s} value", .{ format, what });
}

/// §4.2.1.1 real-to-integer: nearest, ties away from zero.
fn roundAway(f: f64) i64 {
    if (!std.math.isFinite(f)) return 0;
    return std.math.lossyCast(i64, @round(f));
}

fn toReal(b: Bits) f64 {
    if (b.width <= 64) {
        const x = b.low64();
        return if (b.signed) @floatFromInt(@as(i64, @bitCast(x))) else @floatFromInt(x);
    }
    // Wider than 64: sum the words MSB first, x/z read as 0 and bits past
    // the width cleared. A signed value whose top bit is set is negative:
    // sum its magnitude ~u + 1 instead and negate. The +1 carries through
    // exactly the zero words below the lowest nonzero one (`lo`), so each
    // magnitude word is known without a buffer.
    const n: usize = (b.width + 63) / 64;
    const neg = b.signed and b.bit(b.width - 1) == .one;
    var lo: usize = 0;
    while (lo < n and (b.val[lo] & ~b.unk[lo]) == 0) lo += 1;
    var r: f64 = 0;
    var k = n;
    while (k > 0) {
        k -= 1;
        const u = b.val[k] & ~b.unk[k];
        var w: u64 = if (!neg) u else if (k < lo) 0 else if (k == lo) 0 -% u else ~u;
        if (k == n - 1 and b.width % 64 != 0) w &= lowMask(b.width % 64);
        r = r * 18446744073709551616.0 + @as(f64, @floatFromInt(w));
    }
    return if (neg) -r else r;
}

/// Table 12-4's string formats. Octal and hex group from the LSB; a group
/// that is ALL x (z) prints `x` (`z`), one that is only PARTLY x (z) prints
/// `X` (`Z`) — x winning over z when a group holds both, as it would in any
/// expression reading the group.
fn radixString(out: *std.ArrayList(u8), b: Bits, format: c_int) !void {
    switch (format) {
        vpiBinStrVal => binText(try out.addManyAsSlice(gpa, b.width), b.val, b.unk),
        vpiOctStrVal, vpiHexStrVal => {
            const g: u32 = if (format == vpiOctStrVal) 3 else 4;
            const dst = try out.addManyAsSlice(gpa, (b.width + g - 1) / g);
            // dst[0] is the most significant group, the only partial one.
            for (dst, 0..) |*c, j| {
                const lo = @as(u32, @intCast(dst.len - 1 - j)) * g;
                c.* = groupChar(b, lo, @min(lo + g, b.width));
            }
        },
        vpiDecStrVal => {
            if (!b.known()) {
                // The same all/some rule over the whole value: a decimal digit
                // has no bits of its own to be unknown in.
                try out.append(gpa, groupChar(b, 0, b.width));
                return;
            }
            try decimal(out, b);
        },
        vpiStringVal => {
            // "each 8-bit group of the value of the object is assumed to
            // represent an ASCII character", MSB first. A NUL group prints
            // nothing: it is the padding of a register wider than its text.
            // An x or z bit reads as 0.
            try out.ensureUnusedCapacity(gpa, (b.width + 7) / 8);
            var k = (b.width + 7) / 8;
            while (k > 0) {
                k -= 1;
                const lo = k * 8;
                const n = @min(8, b.width - lo);
                const c: u8 = @intCast(field(b.val, lo, n) & ~field(b.unk, lo, n));
                if (c != 0) out.appendAssumeCapacity(c);
            }
        },
        else => unreachable,
    }
}

/// Byte `x` spread to eight bytes of 0 or 1, its MSB in the first byte.
const spread: [256]u64 = blk: {
    @setEvalBranchQuota(4000);
    var t: [256]u64 = undefined;
    for (&t, 0..) |*w, x| {
        w.* = 0;
        for (0..8) |j| w.* |= @as(u64, (x >> (7 - j)) & 1) << (8 * j);
    }
    break :blk t;
};

/// vpiBinStrVal's characters, MSB first: `dst.len` bits of the planes `val`
/// and `unk` (Figure 12-10), eight per step once the top `dst.len % 8` are
/// written. A byte of chars is 0x30 + v + 0x4a*u - 3*(v&u): '0', '1', 'z'
/// (0x7a), 'x' (0x78), with no carry between bytes.
fn binText(dst: []u8, val: []const u64, unk: []const u64) void {
    const head = dst.len % 8;
    for (dst[0..head], 0..) |*c, j| {
        const i = dst.len - 1 - j;
        const o: u6 = @truncate(i);
        const v: u8 = @truncate(val[i / 64] >> o & 1);
        const u: u8 = @truncate(unk[i / 64] >> o & 1);
        c.* = "01zx"[v | u << 1];
    }
    var k = head;
    var i = dst.len - head;
    while (i > 0) : (k += 8) {
        i -= 8;
        const o: u6 = @truncate(i);
        const v = spread[@as(u8, @truncate(val[i / 64] >> o))];
        const u = spread[@as(u8, @truncate(unk[i / 64] >> o))];
        std.mem.writeInt(u64, dst[k..][0..8], 0x3030303030303030 +% v +% 0x4a *% u -% 3 *% (v & u), .little);
    }
}

/// Bits [lo, lo + n) of `plane`, n in 1..64, as the low bits of a word.
/// Asserts the plane holds them.
fn field(plane: []const u64, lo: u32, n: u32) u64 {
    std.debug.assert(n >= 1 and n <= 64);
    std.debug.assert((lo + n + 63) / 64 <= plane.len);
    const w = lo / 64;
    const o: u6 = @truncate(lo);
    var x = plane[w] >> o;
    if (o != 0 and o + n > 64) x |= plane[w + 1] << @intCast(64 - @as(u32, o));
    return x & lowMask(n);
}

fn lowMask(n: u32) u64 {
    return if (n >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
}

/// Two's-complement negation of the little-endian words in place.
fn negate(words: []u64) void {
    var carry: u1 = 1;
    for (words) |*w| {
        const r = @addWithOverflow(~w.*, @as(u64, carry));
        w.* = r[0];
        carry = r[1];
    }
}

/// ORs the `n`-bit `bits` (n in 1..64) into `plane` at bit `lo`, dropping
/// what falls at or past `width`; `plane` holds `width` bits.
fn orField(plane: []u64, lo: usize, bits: u64, n: u32, width: u32) void {
    if (lo >= width) return;
    const x = bits & lowMask(@intCast(@min(n, width - lo)));
    const w = lo / 64;
    const o: u6 = @truncate(lo);
    plane[w] |= x << o;
    if (o != 0 and o + n > 64) plane[w + 1] |= x >> @intCast(64 - @as(u32, o));
}

/// Bits [lo, hi) of `b` as one character: `x`/`z` when every bit is x/z,
/// `X` when any is x, `Z` when any is z, else the value's hex digit (which
/// needs hi - lo <= 4).
fn groupChar(b: Bits, lo: u32, hi: u32) u8 {
    var all_x = true;
    var all_z = true;
    var any_x = false;
    var any_z = false;
    var d: u64 = 0;
    var i = lo;
    while (i < hi) {
        const n = @min(hi - i, 64);
        const m = lowMask(n);
        const v = field(b.val, i, n);
        const u = field(b.unk, i, n);
        all_x = all_x and v & u == m;
        all_z = all_z and ~v & u == m;
        any_x = any_x or v & u != 0;
        any_z = any_z or ~v & u & m != 0;
        d = v;
        i += n;
    }
    if (all_x) return 'x';
    if (all_z) return 'z';
    if (any_x) return 'X';
    if (any_z) return 'Z';
    return "0123456789abcdef"[@intCast(d)];
}

/// Decimal of a fully known value, any width: repeated division of the
/// magnitude by 10. Signed objects print their sign.
fn decimal(out: *std.ArrayList(u8), b: Bits) !void {
    // Up to 1024 bits on the stack: the common widths never allocate.
    var stack: [16]u64 = undefined;
    const words = if (b.val.len <= stack.len) stack[0..b.val.len] else try gpa.alloc(u64, b.val.len);
    defer if (words.ptr != @as([*]u64, &stack)) gpa.free(words);
    @memcpy(words, b.val);
    // Mask to width, then negate a signed negative value.
    if (b.width % 64 != 0) words[words.len - 1] &= lowMask(b.width % 64);
    const neg = b.signed and b.bit(b.width - 1) == .one;
    if (neg) {
        negate(words);
        if (b.width % 64 != 0) words[words.len - 1] &= lowMask(b.width % 64);
    }
    const start = out.items.len;
    while (true) {
        var rem: u128 = 0;
        var k = words.len;
        // OR of the quotient words: zero once the magnitude is.
        var left: u64 = 0;
        while (k > 0) {
            k -= 1;
            const cur = (rem << 64) | words[k];
            words[k] = @intCast(cur / 10);
            rem = cur % 10;
            left |= words[k];
        }
        try out.append(gpa, '0' + @as(u8, @intCast(rem)));
        if (left == 0) break;
    }
    if (neg) try out.append(gpa, '-');
    std.mem.reverse(u8, out.items[start..]);
}

/// §12.16. The object must carry a value; the string, vector and time
/// storage belongs to this routine until its next call.
pub export fn vpi_get_value(obj: vpiHandle, value_p: ?*Value) void {
    if (root.refused("vpi_get_value")) return;
    const v = value_p orelse {
        root.fail("BADVALUE", "vpi_get_value: value_p is NULL", .{});
        return;
    };
    // §12.22.1 a derivative object reads back what calltf put on it.
    if (analog.asDeriv(obj)) |dv| {
        v.format = vpiRealVal;
        v.value.real = dv.value;
        return;
    }
    var o = root.asObj(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_value: that handle is not an object with a value", .{});
        return;
    };
    // IEEE 1364-2005 §26.6.13: a prim term's value is its terminal's.
    if (o.kind == .code and o.vtype == root.code.vpiPrimTerm) {
        const e = root.edgeTo(o, root.code.vpiExpr);
        if (e == root.no_obj) {
            root.fail("NOVALUE", "vpi_get_value: that terminal's expression is not one this model holds", .{});
            return;
        }
        o = &root.design.?.objects[e];
    }
    read(o, v, &get_store);
}

// ---------------------------------------------------------------------------
// §12.30 vpi_put_value
// ---------------------------------------------------------------------------

/// One event a put scheduled. The handle is `live`'s key; the record stays in
/// `events` while the event can still fire, so a later inertial or transport
/// put can cancel it after the application freed the handle (§12.30: freeing
/// the handle "shall not effect the event").
pub const Event = struct {
    handle: sim.scheduler.Handle,
    slot: u32,
    time: u64,
};

var events: std.ArrayList(*Event) = .empty;
var live: std.AutoHashMapUnmanaged(usize, *Event) = .empty;

/// Returns `h` as a live scheduled-event handle, or null; never dereferences
/// a foreign pointer.
pub fn asEvent(h: vpiHandle) ?*Event {
    const p = h orelse return null;
    return live.get(@intFromPtr(p));
}

/// Invalidates `e`'s handle; a still-scheduled event fires regardless.
pub fn freeEvent(e: *Event) void {
    _ = live.remove(@intFromPtr(e));
}

/// Returns whether `e` is still waiting to fire; false with no run attached.
pub fn scheduled(e: *const Event) bool {
    const r = run.attached() orelse return false;
    return r.scheduler.payloadOf(e.handle) != null;
}

/// Drops every event record and handle.
pub fn reset() void {
    for (events.items) |e| gpa.destroy(e);
    events.clearAndFree(gpa);
    live.clearAndFree(gpa);
    get_store.clear();
    cb_store.clear();
    put_buf.clearAndFree(gpa);
}

/// IEEE 1364-2005 C.7's reset "Cancels all scheduled simulation events":
/// every event a put scheduled went with the run the reset replaced, so its
/// handle reads unscheduled and names none of the new run's
/// (`run.zig`'s vpiReset).
pub fn dropScheduled() void {
    for (events.items) |e| e.handle = .{ .slot = .none, .generation = 0 };
}

/// Drop the records of events that fired or were cancelled and whose handle
/// the application no longer holds.
fn prune() void {
    var i: usize = 0;
    while (i < events.items.len) {
        const e = events.items[i];
        if (!scheduled(e) and !live.contains(@intFromPtr(e))) {
            gpa.destroy(events.swapRemove(i));
        } else i += 1;
    }
}

fn cancel(r: *digital.Run, h: sim.scheduler.Handle) void {
    const row = r.scheduler.payloadOf(h) orelse return;
    _ = r.scheduler.cancel(h) catch return;
    r.free_rows.append(r.arena, row) catch {};
}

var put_buf: std.ArrayList(u64) = .empty;

/// "shall set simulation logic values on an object ... The flags argument
/// shall be used to direct the routine to use one of the following delay
/// modes". Returns a vpiSchedEvent handle when vpiReturnEvent is set AND an
/// event was scheduled; otherwise NULL, which is not in itself an error.
pub export fn vpi_put_value(obj: vpiHandle, value_p: ?*Value, time_p: ?*const Time, flags: c_int) vpiHandle {
    if (root.refused("vpi_put_value")) return null;
    const mode = flags & ~vpiReturnEvent;
    if (mode == vpiCancelEvent) {
        // "It shall not be an error to cancel an event which has already
        // occurred." A handle that is not a scheduled event at all is one.
        const e = asEvent(obj) orelse {
            root.fail("BADHANDLE", "vpi_put_value(vpiCancelEvent): that handle is not a vpiSchedEvent", .{});
            return null;
        };
        if (run.attached()) |r| cancel(r, e.handle);
        return null;
    }
    if (run.read_only) {
        root.fail("READONLY", "vpi_put_value: cbReadOnlySynch forbids writing values or scheduling events", .{});
        return null;
    }
    // §12.32.2 a derivative object of the running analog call.
    if (analog.asDeriv(obj)) |dv| {
        const pv = value_p orelse {
            root.fail("BADVALUE", "vpi_put_value: value_p is NULL", .{});
            return null;
        };
        if (pv.format != vpiRealVal) {
            root.fail("BADFORMAT", "vpi_put_value: a derivative is a real, put with vpiRealVal", .{});
            return null;
        }
        _ = analog.putDerivative(dv, pv.value.real);
        return null;
    }
    const o = root.asObj(obj) orelse {
        root.fail("BADHANDLE", "vpi_put_value: that handle is not an object", .{});
        return null;
    };
    // IEEE 1364-2005 §26.6.20 Details b.
    if (o.automatic and (mode == vpiInertialDelay or mode == vpiTransportDelay or mode == vpiPureTransportDelay)) {
        root.fail("AUTOMATIC", "vpi_put_value: `{s}` is an automatic variable, and a put with a delay onto one is illegal", .{o.full});
        return null;
    }
    // §12.30 "The routine can be applied to nets, regs, variables, memory
    // words, system function calls, sequential UDPs, and schedule events" —
    // a parameter is none of those. §11.6.12 NOTE 1 makes its value the
    // elaborated constant, which a put cannot be allowed to rewrite.
    // §11.6.13 NOTE 2: "For primitives, vpi_put_value() shall only be used
    // with sequential UDP primitives." A gate is not one.
    if (o.kind == .code and (o.vtype == root.code.vpiGate or o.vtype == root.code.vpiSwitch)) {
        root.fail("NOPUT", "vpi_put_value: a gate or switch is a primitive, and only a sequential UDP takes a put", .{});
        return null;
    }
    if (o.kind == .parameter) {
        root.fail("NOPUT", "vpi_put_value: `{s}` is a parameter, which vpi_put_value does not apply to", .{o.full});
        return null;
    }
    if (o.kind == .code and o.vtype == root.code.vpiAttribute) {
        root.fail("NOPUT", "vpi_put_value: an attribute is a constant, which vpi_put_value does not apply to", .{});
        return null;
    }
    // IEEE 1364-2005 §20.3: the value the digital call whose calltf is
    // running returns.
    if (o.kind == .code and o.vtype == root.code.vpiSysFuncCall) if (systf.result) |res| if (systf.active) |at| if (&root.design.?.objects[at] == o) {
        const v = value_p orelse {
            root.fail("BADVALUE", "vpi_put_value: value_p is NULL", .{});
            return null;
        };
        toPlanes(v, res.width, res.planes) catch |e| {
            if (e == error.OutOfMemory) return oom();
            return null;
        };
        if (systf.active_reg.?.digital.sysfunctype == systf.vpiRealFunc) {
            const f: f64 = if (v.format == vpiRealVal) v.value.real else @floatFromInt(@as(i64, @bitCast(res.planes[0])));
            @memset(res.planes, 0);
            res.planes[0] = @bitCast(f);
        }
        return null;
    };
    // §12.30 "system function calls": the returned value of the analog call
    // calltf is running for (§12.32.3 "Set returned value to held value"),
    // as a real or an integer (§12.32.1: a vpiIntFunc returns an integer,
    // which the device was compiled to take as one).
    if (o.kind == .code and o.vtype == root.code.vpiSysFuncCall) if (value_p) |pv| if (pv.format == vpiRealVal or pv.format == vpiIntVal) {
        const r: f64 = if (pv.format == vpiRealVal) pv.value.real else @floatFromInt(pv.value.integer);
        if (analog.putResult(o, r)) return null;
    };
    // IEEE 1364-2005 §27.32: "Calling vpi_put_value() on an object of type
    // vpiNamedEvent shall cause the named event to toggle", and value_p may
    // be NULL.
    if (o.kind == .code and o.vtype == root.code.vpiNamedEvent) {
        // §26.6.20: automatic objects require an activation's frame, not
        // the lexical declaration's reusable engine storage. Until VPI
        // frame handles exist, refuse rather than choosing an activation.
        if (o.automatic) {
            root.fail("AUTOMATIC", "vpi_put_value: an automatic event reference requires an activation frame, which is not implemented", .{});
            return null;
        }
        if (mode != vpiNoDelay) {
            root.fail("NOPUT", "vpi_put_value: `{s}` is a named event, toggled now (vpiNoDelay) and not scheduled", .{o.full});
            return null;
        }
        const r = run.attached() orelse return engineFail();
        var selected = o.slot.get();
        if (coldOf(o).event_ref) |ref| {
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            const scope = r.scope;
            defer r.scope = scope;
            r.scope = ref.scope;
            selected = exec.address(r, scratch.allocator(), ref.expr) catch return engineFail();
        }
        if (selected) |at| exec.trigger(r, at) catch return engineFail();
        return null;
    }
    // §12.22.2 an output argument of the analog call calltf is running for,
    // as a real or an integer.
    if (value_p) |pv| if (pv.format == vpiRealVal or pv.format == vpiIntVal) {
        const r: f64 = if (pv.format == vpiRealVal) pv.value.real else @floatFromInt(pv.value.integer);
        if (analog.putArg(o, r)) return null;
    };
    if (o.kind == .code and o.vtype == root.code.vpiUdp) return putUdp(o, value_p, mode);
    const at = o.slot.get() orelse {
        root.fail("NOVALUE", "vpi_put_value: `{s}` has no value this process holds", .{o.full});
        return null;
    };
    // vpiReleaseFlag: "The value_p shall contain the current value of the
    // object" — written back, after the release (IEEE 1364 §9.3.2 puts a
    // net back under its drivers at once).
    if (mode == vpiReleaseFlag) {
        exec.release(run.attached().?, at, true) catch return engineFail();
        if (value_p) |v| read(o, v, &get_store);
        callback.fireOverride(callback.cbRelease, o);
        return null;
    }
    // A net's value is the resolution of its drivers (§7.9). IEEE 1364-2005
    // §27.32: a put "overrides the resolved value of the net. This value
    // shall remain in effect until one of the drivers of the net changes
    // value", which a vpiNoDelay store is: the next resolution overwrites it.
    // A delayed put would need a driver of its own, which the engine does
    // not give an application.
    //
    // ponytail: a driver re-evaluated to the value it already had resolves
    // the net again too, ending the put early.
    const r = run.attached().?;
    if ((mode == vpiInertialDelay or mode == vpiTransportDelay or mode == vpiPureTransportDelay) and r.net_of.contains(at)) {
        root.fail("NETPUT", "vpi_put_value: `{s}` is a net, which takes a put with vpiNoDelay or vpiForceFlag only", .{o.full});
        return null;
    }
    const v = value_p orelse {
        root.fail("BADVALUE", "vpi_put_value: value_p is NULL", .{});
        return null;
    };
    // IEEE 1364-2005 §27.32: "It shall be illegal to specify the format of
    // the value as vpiStringVal when putting a value to a real variable".
    if (v.format == vpiStringVal and r.reals.contains(at)) {
        root.fail("BADFORMAT", "vpi_put_value: vpiStringVal onto the real `{s}` is illegal", .{o.full});
        return null;
    }
    const dest = r.values[at];
    put_buf.resize(gpa, dest.planes.len) catch return oom();
    toPlanes(v, dest.width, put_buf.items) catch |e| {
        if (e == error.OutOfMemory) return oom();
        return null;
    };
    // A real holds IEEE 754 bits: a vpiRealVal as given, any other format as
    // the signed integer it wrote (IEEE 1364 §4.8.2 integer-to-real).
    if (r.reals.contains(at)) {
        const f: f64 = if (v.format == vpiRealVal) v.value.real else @floatFromInt(@as(i64, @bitCast(put_buf.items[0])));
        @memset(put_buf.items, 0);
        put_buf.items[0] = @bitCast(f);
    }
    const lit: Int.Literal = .{ .width = dest.width, .sized = true, .signed = dest.signed, .planes = put_buf.items };

    switch (mode) {
        // "time_p shall be ignored": a force is immediate.
        vpiForceFlag => {
            exec.forceValue(r, at, lit.planes) catch return engineFail();
            callback.fireOverride(callback.cbForce, o);
            return null;
        },
        vpiNoDelay => {
            exec.store(r, at, lit.planes) catch return engineFail();
            return null;
        },
        vpiInertialDelay, vpiTransportDelay, vpiPureTransportDelay => {
            const t = time_p orelse {
                root.fail("BADTIME", "vpi_put_value: a delayed put needs time_p", .{});
                return null;
            };
            const delay = run.ticksOf(t.*, obj) orelse return null;
            const when = run.now() +| delay;
            prune();
            for (events.items) |e| {
                if (e.slot != at or !scheduled(e)) continue;
                // vpiInertialDelay: "All scheduled events on the object shall
                // be removed". vpiTransportDelay: "All events on the object
                // scheduled for times later than this event shall be removed".
                if (mode == vpiInertialDelay or (mode == vpiTransportDelay and e.time > when)) cancel(r, e.handle);
            }
            const h = exec.enqueue(r, .{ .write = .{ .target = at, .value = lit } }, delay, false) catch return engineFail();
            const e = gpa.create(Event) catch return oom();
            e.* = .{ .handle = h, .slot = at, .time = when };
            events.append(gpa, e) catch {
                gpa.destroy(e);
                return oom();
            };
            if (flags & vpiReturnEvent == 0) return null;
            live.put(gpa, @intFromPtr(e), e) catch return oom();
            return @ptrCast(e);
        },
        else => {
            root.fail("BADFLAGS", "vpi_put_value: {d} is not a §12.30 delay mode", .{mode});
            return null;
        },
    }
}

/// §12.30 a put onto a UDP instance: "Sequential UDPs shall be set to the
/// indicated value with no delay regardless of any delay on the primitive
/// instance", so the instance's own delay is skipped. A combinational UDP
/// holds no state to set (§11.6.13 NOTE 2 limits puts to sequential ones),
/// an instance array has one state per element, and a put delayed by time_p
/// would need an event of its own: each is refused.
fn putUdp(o: *const Obj, value_p: ?*const Value, mode: c_int) vpiHandle {
    const r = run.attached() orelse return engineFail();
    const scope = root.design.?.scopes[o.owner.get().?].engine;
    var found: ?u32 = null;
    for (r.drivers, 0..) |drv, k| if (drv.tok == o.src_tok and drv.scope == scope and drv.source == .udp) {
        if (found != null) {
            root.fail("NOPUT", "vpi_put_value: `{s}` is an instance array; put onto one element", .{o.full});
            return null;
        }
        found = @intCast(k);
    };
    const at = found orelse return engineFail();
    if (!r.drivers[at].source.udp.sequential) {
        root.fail("NOPUT", "vpi_put_value: `{s}` is a combinational UDP, and only a sequential UDP takes a put", .{o.full});
        return null;
    }
    if (mode != vpiNoDelay) {
        root.fail("NOPUT", "vpi_put_value: a sequential UDP is set with vpiNoDelay; a delayed put onto one is not implemented", .{});
        return null;
    }
    const v = value_p orelse {
        root.fail("BADVALUE", "vpi_put_value: value_p is NULL", .{});
        return null;
    };
    var planes: [2]u64 = undefined;
    toPlanes(v, 1, &planes) catch |e| {
        if (e == error.OutOfMemory) return oom();
        return null;
    };
    // §8.1.4: a UDP's output is 0, 1 or x; z is not one of them.
    const bit: Int.Bit = switch ((planes[0] & 1) | (planes[1] & 1) << 1) {
        0 => .zero,
        1 => .one,
        else => .x,
    };
    r.vpiPutUdp(at, bit) catch return engineFail();
    return null;
}

fn oom() vpiHandle {
    root.fail("NOMEM", "vpi_put_value: out of memory", .{});
    return null;
}

fn engineFail() vpiHandle {
    root.fail("ENGINE", "vpi_put_value: the digital engine refused the write", .{});
    return null;
}

/// `v` as `width` bits in `planes` (value words, then unknown words).
fn toPlanes(v: *const Value, width: u32, planes: []u64) !void {
    @memset(planes, 0);
    const n = planes.len / 2;
    const val = planes[0..n];
    const unk = planes[n..];
    switch (v.format) {
        vpiIntVal, vpiRealVal, vpiTimeVal => {
            const x: u64 = switch (v.format) {
                vpiIntVal => @bitCast(@as(i64, v.value.integer)),
                vpiRealVal => @bitCast(roundAway(v.value.real)),
                else => blk: {
                    const t = v.value.time orelse return badPut("vpiTimeVal with a NULL time");
                    break :blk (@as(u64, t.high) << 32) | t.low;
                },
            };
            // Sign-extend across the whole object: a negative int or real
            // written to a wide reg is still negative.
            const fill: u64 = if (v.format != vpiTimeVal and @as(i64, @bitCast(x)) < 0) ~@as(u64, 0) else 0;
            for (val, 0..) |*w, k| w.* = if (k == 0) x else fill;
        },
        vpiScalarVal => {
            const bit: Int.Bit = switch (v.value.scalar) {
                vpi0, vpiL => .zero,
                vpi1, vpiH => .one,
                vpiZ => .z,
                vpiX => .x,
                else => return badPut("vpiScalarVal outside vpi0/vpi1/vpiX/vpiZ/vpiH/vpiL"),
            };
            orField(val, 0, @backingInt(bit) & 1, 1, width);
            orField(unk, 0, @backingInt(bit) >> 1, 1, width);
        },
        vpiVectorVal => {
            const vec = v.value.vector orelse return badPut("vpiVectorVal with a NULL vector");
            const words = (width + 31) / 32;
            for (0..words) |k| {
                const a: u64 = @as(u32, @bitCast(vec[k].aval));
                const b: u64 = @as(u32, @bitCast(vec[k].bval));
                const shift: u6 = if (k % 2 == 0) 0 else 32;
                val[k / 2] |= a << shift;
                unk[k / 2] |= b << shift;
            }
        },
        vpiBinStrVal, vpiOctStrVal, vpiHexStrVal => {
            const s = std.mem.span(v.value.str orelse return badPut("a string format with a NULL str"));
            const g: u32 = switch (v.format) {
                vpiBinStrVal => 1,
                vpiOctStrVal => 3,
                else => 4,
            };
            const m = lowMask(g);
            // Every character is checked, those past the width included.
            for (0..s.len) |k| {
                const c = s[s.len - 1 - k];
                const d: u64, const u: u64 = switch (c) {
                    'x', 'X' => .{ m, m },
                    'z', 'Z', '?' => .{ 0, m },
                    else => .{ std.fmt.charToDigit(c, @as(u8, 1) << @intCast(g)) catch return badPut("a digit outside the format's radix"), 0 },
                };
                orField(val, k * g, d, g, width);
                orField(unk, k * g, u, g, width);
            }
        },
        vpiDecStrVal => {
            const s = std.mem.span(v.value.str orelse return badPut("vpiDecStrVal with a NULL str"));
            const neg = s.len > 0 and s[0] == '-';
            for (s[@intFromBool(neg)..]) |c| {
                const d = std.fmt.charToDigit(c, 10) catch return badPut("a non-decimal digit in vpiDecStrVal");
                // val = val * 10 + d, across the words.
                var carry: u128 = d;
                for (val) |*w| {
                    const p = @as(u128, w.*) * 10 + carry;
                    w.* = @truncate(p);
                    carry = p >> 64;
                }
            }
            if (neg) negate(val);
        },
        vpiStringVal => {
            const s = std.mem.span(v.value.str orelse return badPut("vpiStringVal with a NULL str"));
            // The LAST character is the least significant byte.
            for (0..s.len) |k| orField(val, k * 8, s[s.len - 1 - k], 8, width);
        },
        else => return badPut("a value format vpi_put_value does not read"),
    }
    // Nothing past the object's width.
    if (width % 64 != 0) {
        const m = lowMask(width % 64);
        val[n - 1] &= m;
        unk[n - 1] &= m;
    }
}

fn badPut(why: []const u8) error{BadValue} {
    root.fail("BADVALUE", "vpi_put_value: {s}", .{why});
    return error.BadValue;
}

// ---------------------------------------------------------------------------
// cbValueChange delivery
// ---------------------------------------------------------------------------

/// Watch `o`'s slot for changes; the engine calls `onChange` for it from now
/// on. Cheap to repeat.
pub fn watch(o: *const Obj) void {
    const r = run.attached() orelse return;
    r.vpi_change = onChange;
    if (o.slot.get()) |at| r.watch[at].insert(.vpi);
    // An array: every element (§12.31.1 "if the obj is a memory word or a
    // variable array, ... the index field shall contain the index").
    const d = &(root.design orelse return);
    for (coldOf(o).members) |m| if (d.objects[m].slot.get()) |at| r.watch[at].insert(.vpi);
}

fn onChange(_: *digital.Run, slot: u32) void {
    callback.fireSlot(slot);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Harness = @import("run.zig").Harness;

fn getStr(h: vpiHandle, format: c_int) []const u8 {
    var v: Value = std.mem.zeroes(Value);
    v.format = format;
    vpi_get_value(h, &v);
    return std.mem.span(v.value.str);
}

test "§12.16 Table 12-4: every string format over a four-state value" {
    var h: Harness = undefined;
    try h.init(
        \\module v;
        \\  reg [11:0] known, unknown;
        \\  reg [39:0] text;
        \\  reg signed [7:0] neg;
        \\  initial begin
        \\    known = 12'b1010_0111_0001;
        \\    unknown = 12'b1010_zzzz_01x1;
        \\    text = 40'h5665724121;
        \\    neg = -8'sd5;
        \\  end
        \\endmodule
    );
    defer h.deinit();
    try run.simulate();
    const known = handle.vpi_handle_by_name("v.known", null);
    const unknown = handle.vpi_handle_by_name("v.unknown", null);
    try std.testing.expectEqualStrings("101001110001", getStr(known, vpiBinStrVal));
    try std.testing.expectEqualStrings("5161", getStr(known, vpiOctStrVal));
    try std.testing.expectEqualStrings("2673", getStr(known, vpiDecStrVal));
    try std.testing.expectEqualStrings("a71", getStr(known, vpiHexStrVal));
    try std.testing.expectEqualStrings("1010zzzz01x1", getStr(unknown, vpiBinStrVal));
    try std.testing.expectEqualStrings("azX", getStr(unknown, vpiHexStrVal));
    try std.testing.expectEqualStrings("5ZZX", getStr(unknown, vpiOctStrVal));
    try std.testing.expectEqualStrings("VerA!", getStr(handle.vpi_handle_by_name("v.text", null), vpiStringVal));
    try std.testing.expectEqualStrings("-5", getStr(handle.vpi_handle_by_name("v.neg", null), vpiDecStrVal));

    var v: Value = std.mem.zeroes(Value);
    v.format = vpiIntVal;
    vpi_get_value(unknown, &v);
    try std.testing.expectEqual(@as(c_int, 0xa05), v.value.integer);
    v.format = vpiVectorVal;
    vpi_get_value(unknown, &v);
    try std.testing.expectEqual(@as(c_int, 0xa07), v.value.vector[0].aval);
    try std.testing.expectEqual(@as(c_int, 0x0f2), v.value.vector[0].bval);
    v.format = vpiObjTypeVal;
    vpi_get_value(known, &v);
    try std.testing.expectEqual(vpiVectorVal, v.format);
    // A format the routine does not read, and a handle that is not an object.
    v.format = 99;
    vpi_get_value(known, &v);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    vpi_get_value(null, &v);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}

test "§12.30: vpiNoDelay writes now, the delay modes schedule, and events cancel" {
    var h: Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module p;
        \\  reg [7:0] q;
        \\  initial begin q = 0; #50 $finish(0); end
        \\endmodule
    );
    defer h.deinit();
    const q = handle.vpi_handle_by_name("p.q", null);
    var v: Value = std.mem.zeroes(Value);
    var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = 5, .real = 0 };
    v.format = vpiHexStrVal;
    v.value.str = @constCast("a5");
    try std.testing.expect(vpi_put_value(q, &v, null, vpiNoDelay | vpiReturnEvent) == null);
    try std.testing.expectEqualStrings("10100101", getStr(q, vpiBinStrVal));

    v.format = vpiIntVal;
    v.value.integer = 0xAA;
    const aa = vpi_put_value(q, &v, &t, vpiPureTransportDelay | vpiReturnEvent);
    try std.testing.expect(aa != null);
    try std.testing.expectEqual(vpiSchedEvent, property.vpi_get(root.vpiType, aa));
    try std.testing.expectEqual(@as(c_int, 1), property.vpi_get(vpiScheduled, aa));
    // An inertial put removes the 0xAA event.
    v.value.integer = 0xCC;
    t.low = 10;
    try std.testing.expect(vpi_put_value(q, &v, &t, vpiInertialDelay) == null);
    try std.testing.expectEqual(@as(c_int, 0), property.vpi_get(vpiScheduled, aa));
    // Cancelling it again is not an error.
    _ = vpi_put_value(aa, null, null, vpiCancelEvent);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try run.simulate();
    v.format = vpiIntVal;
    vpi_get_value(q, &v);
    try std.testing.expectEqual(@as(c_int, 0xCC), v.value.integer);
}

test "§12.30: vpiForceFlag overrides a net's driver, vpiReleaseFlag hands it back" {
    var h: Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module f;
        \\  reg [7:0] a;
        \\  wire [7:0] w;
        \\  assign w = a + 8'd1;
        \\  initial begin a = 10; #50 $finish(0); end
        \\endmodule
    );
    defer h.deinit();
    try run.simulate();
    const w = handle.vpi_handle_by_name("f.w", null);
    var fmt: Value = std.mem.zeroes(Value);
    fmt.format = vpiIntVal;
    for ([_]c_int{ callback.cbForce, callback.cbRelease }) |reason| {
        const d: callback.CbData = .{ .reason = reason, .cb_rtn = noteOverride, .obj = null, .time = null, .value = &fmt, .index = 0, .user_data = null };
        try std.testing.expect(callback.vpi_register_cb(&d) != null);
    }
    overrides_n = 0;
    var v: Value = std.mem.zeroes(Value);
    v.format = vpiIntVal;
    // A vpiNoDelay put overrides the resolved value until a driver changes
    // (IEEE 1364-2005 §27.32); a delayed one is refused.
    v.value.integer = 7;
    try std.testing.expect(vpi_put_value(w, &v, null, vpiNoDelay) == null);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    vpi_get_value(w, &v);
    try std.testing.expectEqual(@as(c_int, 7), v.value.integer);
    var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = 5, .real = 0 };
    try std.testing.expect(vpi_put_value(w, &v, &t, vpiInertialDelay) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    v.value.integer = 0xF0;
    try std.testing.expect(vpi_put_value(w, &v, null, vpiForceFlag) == null);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    v.value.integer = 0;
    vpi_get_value(w, &v);
    try std.testing.expectEqual(@as(c_int, 0xF0), v.value.integer);
    // Release: value_p comes back holding the driver's value, a + 1.
    v.value.integer = -1;
    _ = vpi_put_value(w, &v, null, vpiReleaseFlag);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 11), v.value.integer);
    // One cbForce carrying the forced value, one cbRelease the released one,
    // each naming the object.
    try std.testing.expectEqualSlices([3]c_int, &.{ .{ callback.cbForce, 0xF0, 1 }, .{ callback.cbRelease, 11, 1 } }, overrides[0..overrides_n]);
}

var overrides: [4][3]c_int = undefined;
var overrides_n: usize = 0;

fn noteOverride(d: *callback.CbData) callconv(.c) c_int {
    overrides[overrides_n] = .{ d.reason, d.value.?.value.integer, @intFromBool(root.asObj(d.obj) != null) };
    overrides_n += 1;
    return 0;
}

test "§12.16: an analog parameter reads the value lowering folded" {
    var res = try @import("vera").compileSource(std.testing.allocator,
        \\module r(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real g = 2.5;
        \\  parameter integer k = 3;
        \\  analog I(p,n) <+ g*k*V(p,n);
        \\endmodule
    , .lint);
    defer res.deinit();
    try root.open(std.testing.allocator, &res);
    defer root.close();
    var v: Value = std.mem.zeroes(Value);
    v.format = vpiRealVal;
    vpi_get_value(handle.vpi_handle_by_name("r.g", null), &v);
    try std.testing.expectEqual(@as(f64, 2.5), v.value.real);
    v.format = vpiObjTypeVal;
    vpi_get_value(handle.vpi_handle_by_name("r.k", null), &v);
    try std.testing.expectEqual(vpiIntVal, v.format);
    v.format = vpiIntVal;
    vpi_get_value(handle.vpi_handle_by_name("r.k", null), &v);
    try std.testing.expectEqual(@as(c_int, 3), v.value.integer);
    // A node's value lives in a device this process does not run.
    vpi_get_value(handle.vpi_handle_by_name("r.p", null), &v);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}

// ---- the formats, over hand-built values: no design needed ----------------

test "Table 12-4 vpiDecStrVal: every 8-bit value, signed and unsigned, against std.fmt" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var want_buf: [8]u8 = undefined;
    const unk = [1]u64{0};
    for (0..256) |x| {
        const val = [1]u64{x};
        for ([_]bool{ false, true }) |signed| {
            out.clearRetainingCapacity();
            try radixString(&out, .{ .width = 8, .val = &val, .unk = &unk, .signed = signed }, vpiDecStrVal);
            const byte: u8 = @intCast(x);
            const want = if (signed)
                try std.mem.print(&want_buf, "{d}", .{@as(i8, @bitCast(byte))})
            else
                try std.mem.print(&want_buf, "{d}", .{byte});
            try std.testing.expectEqualStrings(want, out.items);
        }
    }
}

test "Table 12-4 vpiDecStrVal: wider than 64 bits, and the most negative values" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const two64 = [2]u64{ 0, 1 };
    const ones = [2]u64{ std.math.maxInt(u64), std.math.maxInt(u64) };
    const zero = [2]u64{ 0, 0 };
    // 2^64, unsigned in 128 bits.
    try radixString(&out, .{ .width = 128, .val = &two64, .unk = &zero, .signed = false }, vpiDecStrVal);
    try std.testing.expectEqualStrings("18446744073709551616", out.items);
    // Every bit one, signed: -1.
    out.clearRetainingCapacity();
    try radixString(&out, .{ .width = 128, .val = &ones, .unk = &zero, .signed = true }, vpiDecStrVal);
    try std.testing.expectEqualStrings("-1", out.items);
    // Bit 64 alone in 65 signed bits is the sign: -2^64.
    out.clearRetainingCapacity();
    try radixString(&out, .{ .width = 65, .val = &two64, .unk = &zero, .signed = true }, vpiDecStrVal);
    try std.testing.expectEqualStrings("-18446744073709551616", out.items);
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
        .{ vpiBinStrVal, "1x01zzzz" },
        .{ vpiHexStrVal, "Xz" },
        .{ vpiOctStrVal, "XZz" },
        .{ vpiDecStrVal, "X" },
    }) |case| {
        out.clearRetainingCapacity();
        try radixString(&out, b, case[0]);
        try std.testing.expectEqualStrings(case[1], out.items);
    }
    // All z, all x: lower case, in every radix.
    const zeros = [1]u64{0};
    const all = [1]u64{0xFF};
    for ([_]struct { []const u64, u8 }{ .{ &zeros, 'z' }, .{ &all, 'x' } }) |case| {
        for ([_]c_int{ vpiOctStrVal, vpiHexStrVal, vpiDecStrVal }) |format| {
            out.clearRetainingCapacity();
            try radixString(&out, .{ .width = 8, .val = case[0], .unk = &all, .signed = false }, format);
            for (out.items) |c| try std.testing.expectEqual(case[1], c);
        }
    }
}

test "Table 12-4 vpiStringVal: 8-bit groups MSB first, NUL groups dropped" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const unk = [1]u64{0};
    // 12 bits: the top group is 4 bits of zero, a NUL.
    const a = [1]u64{0x041};
    try radixString(&out, .{ .width = 12, .val = &a, .unk = &unk, .signed = false }, vpiStringVal);
    try std.testing.expectEqualStrings("A", out.items);
    // A NUL between two characters is dropped too.
    const ab = [1]u64{0x41_00_42};
    out.clearRetainingCapacity();
    try radixString(&out, .{ .width = 24, .val = &ab, .unk = &unk, .signed = false }, vpiStringVal);
    try std.testing.expectEqualStrings("AB", out.items);
}

test "Table 12-4 vpiIntVal: x/z read as 0, a signed value sign-extends from its width" {
    var st: Store = .{};
    defer st.clear();
    var v: Value = std.mem.zeroes(Value);
    v.format = vpiIntVal;
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
    v.format = vpiVectorVal;
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

test "Table 12-4 vpiRealVal: a signed value wider than 64 bits keeps its sign" {
    const zero = [2]u64{ 0, 0 };
    // -1 in 100 bits: every bit one.
    const ones = [2]u64{ std.math.maxInt(u64), (1 << 36) - 1 };
    try std.testing.expectEqual(@as(f64, -1), toReal(.{ .width = 100, .val = &ones, .unk = &zero, .signed = true }));
    // The same bits unsigned: 2^100 - 1, which rounds to 2^100 in an f64.
    try std.testing.expectEqual(std.math.pow(f64, 2, 100), toReal(.{ .width = 100, .val = &ones, .unk = &zero, .signed = false }));
    // -5 in 72 bits.
    const m5 = [2]u64{ std.math.maxInt(u64) - 4, 0xff };
    try std.testing.expectEqual(@as(f64, -5), toReal(.{ .width = 72, .val = &m5, .unk = &zero, .signed = true }));
    // Within 64 bits: 1010 is -6 signed.
    const v4 = [1]u64{0b1010};
    try std.testing.expectEqual(@as(f64, -6), toReal(.{ .width = 4, .val = &v4, .unk = zero[0..1], .signed = true }));
}

test "§4.2.1.1 roundAway: nearest, ties away from zero, non-finite is 0" {
    for ([_]struct { f64, i64 }{
        .{ 2.5, 3 },
        .{ -2.5, -3 },
        .{ 0.5, 1 },
        .{ -0.5, -1 },
        .{ 2.4999, 2 },
        .{ -0.0, 0 },
        .{ std.math.nan(f64), 0 },
        .{ std.math.inf(f64), 0 },
        .{ -std.math.inf(f64), 0 },
        .{ 1e300, std.math.maxInt(i64) },
        .{ -1e300, std.math.minInt(i64) },
    }) |case| try std.testing.expectEqual(case[1], roundAway(case[0]));
}

test "§12.30: a string a put writes reads back as the same string, every 8-bit value" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var text: [16:0]u8 = undefined;
    for (0..256) |x| {
        const want = [2]u64{ x, 0 };
        for ([_]c_int{ vpiBinStrVal, vpiOctStrVal, vpiHexStrVal, vpiDecStrVal }) |format| {
            // The spelling the get side writes for `x` is the put's input.
            out.clearRetainingCapacity();
            try radixString(&out, .{ .width = 8, .val = want[0..1], .unk = want[1..2], .signed = false }, format);
            @memcpy(text[0..out.items.len], out.items);
            text[out.items.len] = 0;
            var v: Value = std.mem.zeroes(Value);
            v.format = format;
            v.value.str = &text;
            var planes: [2]u64 = undefined;
            try toPlanes(&v, 8, &planes);
            try std.testing.expectEqual(want, planes);
        }
    }
}

test "§12.30 toPlanes: an int sign-extends across the object, a time does not" {
    var v: Value = std.mem.zeroes(Value);
    var planes: [4]u64 = undefined;
    v.format = vpiIntVal;
    v.value.integer = -2;
    try toPlanes(&v, 72, &planes);
    try std.testing.expectEqualSlices(u64, &.{ std.math.maxInt(u64) - 1, 0xff, 0, 0 }, &planes);
    var t: Time = .{ .type = callback.vpiSimTime, .high = 0xffff_ffff, .low = 0, .real = 0 };
    v.format = vpiTimeVal;
    v.value.time = &t;
    try toPlanes(&v, 72, &planes);
    try std.testing.expectEqualSlices(u64, &.{ 0xffff_ffff_0000_0000, 0, 0, 0 }, &planes);
    // A real rounds away from zero first: -2.5 is -3, 0xfd in 8 bits.
    v.format = vpiRealVal;
    v.value.real = -2.5;
    try toPlanes(&v, 8, planes[0..2]);
    try std.testing.expectEqualSlices(u64, &.{ 0xfd, 0 }, planes[0..2]);
}

test "§12.30 toPlanes: scalars, strings, and the values it refuses" {
    var v: Value = std.mem.zeroes(Value);
    var one_bit: [2]u64 = undefined;
    v.format = vpiScalarVal;
    // vpiH and vpiL are their strengthless 1 and 0.
    for ([_]struct { c_int, [2]u64 }{
        .{ vpi0, .{ 0, 0 } },
        .{ vpi1, .{ 1, 0 } },
        .{ vpiZ, .{ 0, 1 } },
        .{ vpiX, .{ 1, 1 } },
        .{ vpiH, .{ 1, 0 } },
        .{ vpiL, .{ 0, 0 } },
    }) |case| {
        v.value.scalar = case[0];
        try toPlanes(&v, 1, &one_bit);
        try std.testing.expectEqual(case[1], one_bit);
    }
    v.value.scalar = 9;
    try std.testing.expectError(error.BadValue, toPlanes(&v, 1, &one_bit));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));

    // vpiStringVal: the last character is the least significant byte, and
    // what does not fit the width is dropped.
    var planes: [2]u64 = undefined;
    v.format = vpiStringVal;
    v.value.str = @constCast("AB");
    try toPlanes(&v, 16, &planes);
    try std.testing.expectEqual([2]u64{ 0x4142, 0 }, planes);
    try toPlanes(&v, 8, &planes);
    try std.testing.expectEqual([2]u64{ 0x42, 0 }, planes);

    for ([_]struct { c_int, [:0]const u8 }{
        .{ vpiBinStrVal, "102" },
        .{ vpiOctStrVal, "8" },
        .{ vpiHexStrVal, "g" },
        .{ vpiDecStrVal, "12a" },
    }) |case| {
        v.format = case[0];
        v.value.str = @constCast(case[1].ptr);
        try std.testing.expectError(error.BadValue, toPlanes(&v, 8, &planes));
    }
    v.format = vpiHexStrVal;
    v.value.str = null;
    try std.testing.expectError(error.BadValue, toPlanes(&v, 8, &planes));
    v.format = 99;
    try std.testing.expectError(error.BadValue, toPlanes(&v, 8, &planes));
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

test "§12.30: put refusals that need no design" {
    root.close();
    defer root.close();
    var v: Value = std.mem.zeroes(Value);
    v.format = vpiIntVal;
    // Not a handle VerA issued: a cancel needs a vpiSchedEvent, any other put
    // an object.
    var junk: u32 = 0;
    try std.testing.expect(vpi_put_value(@ptrCast(&junk), null, null, vpiCancelEvent) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    try std.testing.expect(vpi_put_value(@ptrCast(&junk), &v, null, vpiNoDelay) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    // cbReadOnlySynch refuses every write before looking at the handle.
    run.read_only = true;
    defer run.read_only = false;
    try std.testing.expect(vpi_put_value(null, &v, null, vpiNoDelay) == null);
    var info: root.ErrorInfo = undefined;
    _ = root.vpi_chk_error(&info);
    try std.testing.expectEqualStrings("READONLY", std.mem.span(info.code));
    // §12.16: NULL value_p.
    vpi_get_value(null, null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    // A record with no run behind it is not scheduled, and its handle is not
    // live until a put returns it.
    const e: Event = .{ .handle = .{ .slot = .none, .generation = 0 }, .slot = 0, .time = 0 };
    try std.testing.expect(!scheduled(&e));
    try std.testing.expect(asEvent(@ptrCast(@constCast(&e))) == null);
    try std.testing.expect(asEvent(null) == null);
}

/// The bit-at-a-time spelling `radixString` replaced: the differential
/// tests' oracle.
fn radixOracle(out: *std.ArrayList(u8), b: Bits, format: c_int) !void {
    const g: u32 = switch (format) {
        vpiBinStrVal => 1,
        vpiOctStrVal => 3,
        vpiHexStrVal => 4,
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
            for ([_]c_int{ vpiBinStrVal, vpiOctStrVal, vpiHexStrVal, vpiStringVal }) |format| {
                got.clearRetainingCapacity();
                want.clearRetainingCapacity();
                try radixString(&got, b, format);
                try radixOracle(&want, b, format);
                try std.testing.expectEqualStrings(want.items, got.items);
            }
            // A binary string a get wrote, x and z included, puts back the
            // same planes, masked to the width.
            got.clearRetainingCapacity();
            try radixString(&got, b, vpiBinStrVal);
            try got.append(gpa, 0);
            var v: Value = std.mem.zeroes(Value);
            v.format = vpiBinStrVal;
            v.value.str = got.items.ptr;
            const n = @max(1, (width + 63) / 64);
            var back: [8]u64 = undefined;
            try toPlanes(&v, @intCast(width), back[0 .. 2 * n]);
            for (0..n) |w| {
                const m = lowMask(@intCast(@min(64, width - 64 * w)));
                try std.testing.expectEqual(b.val[w] & m, back[w]);
                try std.testing.expectEqual(b.unk[w] & m, back[n + w]);
            }
        }
    }
}

test "§12.30 toPlanes: a vector's words past the width are dropped; a decimal string of any width reads back" {
    var v: Value = std.mem.zeroes(Value);
    var planes: [2 * 18]u64 = undefined;
    // 40 bits: two vecvals, the second's bits past bit 7 cleared.
    var vec = [2]VecVal{ .{ .aval = -1, .bval = 0x0f }, .{ .aval = -1, .bval = -1 } };
    v.format = vpiVectorVal;
    v.value.vector = &vec;
    try toPlanes(&v, 40, planes[0..2]);
    try std.testing.expectEqualSlices(u64, &.{ 0xff_ffff_ffff, 0xff_0000_000f }, planes[0..2]);
    // Decimal through 1100 bits, past `decimal`'s stack words: the put's
    // planes print back as the same digits, a negative one with its sign.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for ([_][:0]const u8{ "0", "123456789012345678901234567890123456789", "-98765432109876543210" }) |text| {
        v.format = vpiDecStrVal;
        v.value.str = @constCast(text.ptr);
        try toPlanes(&v, 1100, &planes);
        out.clearRetainingCapacity();
        try radixString(&out, .{ .width = 1100, .val = planes[0..18], .unk = planes[18..], .signed = text[0] == '-' }, vpiDecStrVal);
        try std.testing.expectEqualStrings(text, out.items);
    }
    // An empty decimal string is 0; a lone sign is too.
    for ([_][:0]const u8{ "", "-" }) |text| {
        v.value.str = @constCast(text.ptr);
        try toPlanes(&v, 8, planes[0..2]);
        try std.testing.expectEqualSlices(u64, &.{ 0, 0 }, planes[0..2]);
    }
}
