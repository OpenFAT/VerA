//! `vera`'s stderr report shared by `main.zig` and `cli/digital.zig`: a
//! diagnostic bag -> rendered text or JSON. A source that could not be read
//! is `vera.readFailed`'s. The messages are user-visible and frozen. No LRM
//! clause: the format is `diag`'s.

const std = @import("std");
const vera = @import("vera");
const diag = vera.diag;
const Io = std.Io;

/// Renders `bag` on `w`, as JSON or as text coloured when `color`, and flushes
/// `w`. An empty bag prints nothing.
pub fn report(bag: *diag.Bag, w: *Io.Writer, json: bool, color: bool) !void {
    if (bag.isEmpty()) return;
    if (json) {
        try diag.renderJson(bag, w);
    } else {
        try diag.render(bag, w, .{ .palette = if (color) .on else .off });
    }
    try w.flush();
}

test report {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var none: Io.Writer.Allocating = .init(gpa);
    defer none.deinit();
    try report(&bag, &none.writer, false, true);
    try std.testing.expectEqualStrings("", none.written());

    try bag.add(.parse, .E1104, .none, "`x.sv` is an IEEE 1800 source", .{});
    var json: Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try report(&bag, &json.writer, true, true);
    try std.testing.expect(std.mem.startsWith(u8, json.written(), "{\"code\":\"E1104\""));
    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try report(&bag, &text.writer, false, false);
    try std.testing.expect(std.mem.find(u8, text.written(), "error[E1104]") != null);
    // No colour asked for: no escape byte.
    try std.testing.expect(std.mem.findScalar(u8, text.written(), 0x1b) == null);
}
