//! Ports and declaration attributes in, one `Pin` kind per port out, plus the
//! `vera_delay` each declaration fixes. Cites Verilog-AMS §2.9 (attributes on a
//! declaration).
//!
//! A port is `--digital-pins`' if named there, else its `(* vera_pin *)`, else
//! a supply by its name (`guessSupply`), else analog. The last attribute of a
//! name wins, as a later declaration's would.
//!
//! Contents:
//! - `pub const Pin = enum(u8)`
//! - `pub const Delays = std.StringHashMapUnmanaged(f64)`
//! - `pub const Attrs = struct`
//! - `pub fn readAttrs(scratch: Allocator, lw: *const Lowered, refusal: *Refusal) Error!Attrs`
//! - `pub fn classify(scratch: Allocator, port_names: []const []const u8, attrs: *const Attrs, digital: []const []const u8, module: []const u8, refusal: *Refusal) Error![]Pin`
//! - `pub fn isSupply(pins: []const Pin, row: u32) bool`
//! - `pub const Error = error{ OutOfMemory, Refused }`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Lowered = @import("ir").Lowered;
const Refusal = @import("refusal.zig").Refusal;

/// What a port is to the digital side.
pub const Pin = enum(u8) {
    /// Logic: `input` if the model never drives it, else `output`.
    digital,
    /// An undriven `inout wire`, read as its logic level.
    analog,
    /// A supply at VDD.
    power,
    /// A supply at 0 V.
    ground,
};

/// `vera_delay` seconds by declared name: finite in ns, >= 0.
pub const Delays = std.StringHashMapUnmanaged(f64);

/// The two attributes `--emit-verilog` reads, by declared name. Borrows the
/// names from `Lowered.src`; lives in the caller's scratch allocator.
pub const Attrs = struct {
    /// `vera_pin` strings, not yet checked against `Pin`.
    pin: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// `vera_delay` values.
    delay: Delays = .empty,
};

/// Every way `readAttrs` and `classify` fail; `refusal` holds the reason of
/// `Refused`. Nothing is returned on either.
pub const Error = error{ OutOfMemory, Refused };

/// Reads `vera_pin` and `vera_delay` off every declaration attribute, in
/// source order. Refuses the first whose value is not a string (`vera_pin`)
/// or not a constant in [0, inf) s finite in ns (`vera_delay`).
pub fn readAttrs(scratch: Allocator, lw: *const Lowered, refusal: *Refusal) Error!Attrs {
    var attrs: Attrs = .{};
    for (lw.decl_attrs) |a| {
        const span = lw.tokenSpan(a.tok);
        assert(span.start <= span.end);
        const decl = lw.src[span.start..span.end];
        if (std.mem.eql(u8, a.name, "vera_pin")) {
            const v = a.value orelse return refusal.raise(.{ .bad_vera_pin = decl });
            if (v != .str) return refusal.raise(.{ .bad_vera_pin = decl });
            try attrs.pin.put(scratch, decl, v.str);
        } else if (std.mem.eql(u8, a.name, "vera_delay")) {
            const v = a.value orelse return refusal.raise(.{ .bad_vera_delay = decl });
            const seconds = v.asReal();
            // Finite in ns too: the module prints it in ns.
            if (v == .str or !(seconds >= 0) or !std.math.isFinite(seconds * 1e9)) return refusal.raise(.{ .bad_vera_delay = decl });
            try attrs.delay.put(scratch, decl, seconds);
        }
    }
    assert(attrs.pin.count() <= lw.decl_attrs.len);
    assert(attrs.delay.count() <= lw.decl_attrs.len);
    return attrs;
}

/// Returns one `Pin` per port, allocated in `scratch`. Refuses a
/// `--digital-pins` name that is no port, then a `vera_pin` that is no kind.
pub fn classify(scratch: Allocator, port_names: []const []const u8, attrs: *const Attrs, digital: []const []const u8, module: []const u8, refusal: *Refusal) Error![]Pin {
    // `emit` refused a module with no ports.
    assert(port_names.len > 0);
    for (digital) |d| {
        if (indexOf(port_names, d) == null) return refusal.raise(.{ .unknown_digital_pin = .{ .pin = d, .module = module } });
    }
    const pins = try scratch.alloc(Pin, port_names.len);
    for (pins, port_names) |*p, name| {
        p.* = if (indexOf(digital, name) != null)
            .digital
        else if (attrs.pin.get(name)) |kind|
            std.meta.stringToEnum(Pin, kind) orelse return refusal.raise(.{ .unknown_pin_kind = .{ .port = name, .kind = kind } })
        else
            guessSupply(name) orelse .analog;
    }
    assert(pins.len == port_names.len);
    for (digital) |d| assert(pins[indexOf(port_names, d).?] == .digital);
    return pins;
}

/// Whether `nodes` row `row` is a supply port (power or ground). A row past
/// the ports, or `Lowered.ground`, is not.
pub fn isSupply(pins: []const Pin, row: u32) bool {
    if (row >= pins.len) return false;
    return pins[row] == .power or pins[row] == .ground;
}

// ---- private ----

fn indexOf(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
        assert(i < names.len);
        return i;
    };
    return null;
}

/// The supply a port's name conventionally is, or null.
fn guessSupply(name: []const u8) ?Pin {
    for ([_][]const u8{ "vdd", "vcc", "vpwr", "vpb", "avdd", "dvdd" }) |p| if (std.ascii.startsWithIgnoreCase(name, p)) return .power;
    for ([_][]const u8{ "vss", "gnd", "vgnd", "vnb", "vee", "avss", "dvss" }) |p| if (std.ascii.startsWithIgnoreCase(name, p)) return .ground;
    return null;
}

test guessSupply {
    // Spec example: the header's name lists, either case, any suffix.
    for ([_][]const u8{ "vdd", "VDD", "vdda", "vcc", "vpwr", "vpb", "avdd", "dvdd" }) |n|
        try std.testing.expectEqual(@as(?Pin, .power), guessSupply(n));
    for ([_][]const u8{ "vss", "gnd", "GND", "vgnd", "vnb", "vee", "avss", "dvss" }) |n|
        try std.testing.expectEqual(@as(?Pin, .ground), guessSupply(n));
    for ([_][]const u8{ "", "a", "vd", "out_vdd" }) |n|
        try std.testing.expectEqual(@as(?Pin, null), guessSupply(n));
    // The header's rule is `vdd*`, whatever the length: 17 bytes is still a
    // supply.
    try std.testing.expectEqual(@as(?Pin, .power), guessSupply("vdd_core_supply_1"));
    try std.testing.expectEqual(@as(?Pin, .ground), guessSupply("gnd_of_the_analog_core"));
}

test isSupply {
    const pins = [_]Pin{ .digital, .analog, .power, .ground };
    try std.testing.expect(!isSupply(&pins, 0));
    try std.testing.expect(!isSupply(&pins, 1));
    try std.testing.expect(isSupply(&pins, 2));
    try std.testing.expect(isSupply(&pins, 3));
    // An internal net and ground are no port.
    try std.testing.expect(!isSupply(&pins, 4));
    try std.testing.expect(!isSupply(&pins, Lowered.ground));
}
