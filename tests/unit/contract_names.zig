const std = @import("std");
const vera = @import("vera");
const contract = @import("contract");

/// Enough Verilog-A to make codegen reach for the contract in several
/// directions at once: a state-carrying limiter, noise, a charge, an operating
/// point variable and a system task. Each one emits a different `contract.`
/// reference, and a device that only stamped a resistor would exercise three.
const wide_device =
    \\`include "disciplines.vams"
    \\module wide(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0.0:inf);
    \\  parameter real c = 1.0e-12 from [0.0:inf);
    \\  real vlim;
    \\  (* desc = "branch current" *) real i_op;
    \\  analog begin
    \\    vlim = $limit(V(p, n), "pnjlim", 0.025, 0.7);
    \\    i_op = vlim / r;
    \\    I(p, n) <+ i_op + ddt(c * V(p, n));
    \\    I(p, n) <+ white_noise(4.0 * `P_K * $temperature / r, "thermal");
    \\  end
    \\endmodule
;

/// Whether `contract` declares `name`, read from the module itself so there is
/// no third list to keep in step.
fn declares(name: []const u8) bool {
    inline for (@typeInfo(contract).@"struct".decl_names) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether `at` follows a `//` on its line. Enough because codegen emits no
/// string literal containing `//`.
fn inComment(text: []const u8, at: usize) bool {
    const line_start = if (std.mem.findScalarLast(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
    return std.mem.find(u8, text[line_start..at], "//") != null;
}

test "every `contract.<name>` the backend emits is a decl contract.zig has" {
    const gpa = std.testing.allocator;
    var res = try vera.analyze(gpa, wide_device, .{}, null);
    defer res.deinit(gpa);
    var dev = try res.generate(gpa, .{}, null);
    defer dev.deinit(gpa);
    const src = dev.output.text;

    var missing: usize = 0;
    var i: usize = 0;
    while (std.mem.findPos(u8, src, i, "contract.")) |hit| {
        i = hit + "contract.".len;
        // A comment naming `contract.zig` is prose, not a decl the device
        // resolves.
        if (inComment(src, hit)) continue;
        // `@import("contract")` and its binding line are followed by nothing
        // identifier-shaped, so the scan skips them.
        var end = i;
        while (end < src.len and isIdentChar(src[end])) end += 1;
        if (end == i) continue;
        const name = src[i..end];
        if (declares(name)) continue;
        std.debug.print(
            "the emitted device spells `contract.{s}`, which lib/contract.zig does not declare\n",
            .{name},
        );
        missing += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), missing);

    // The scan is evidence only if it found something: a device that stopped
    // emitting the prefix would otherwise pass by matching nothing.
    try std.testing.expect(std.mem.find(u8, src, "contract.validate(") != null);
}
