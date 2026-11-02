//! `vera`'s stderr report, shared by the `.va` and `.v` halves: a diagnostic
//! bag in, rendered text or JSON out. A source that could not be read is
//! `vera.readFailed`'s. The messages are user-visible and frozen. No LRM
//! clause: the format is `diag`'s.
//!
//! Contents:
//! - `pub const Style = struct`
//! - `pub fn report(bag: *diag.Bag, w: *Io.Writer, style: Style) diag.RenderError!void`

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const diag = @import("diag");

/// How the diagnostics are written: `--diagnostics=` and the colour
/// `--color=` settled to (decided once, by `main`).
pub const Style = struct {
    json: bool = false,
    color: bool = false,
};

/// Renders `bag` on `w`, as JSON or as text coloured when `style.color`, and
/// flushes `w`. An empty bag prints nothing. Sorts the bag.
pub fn report(bag: *diag.Bag, w: *Io.Writer, style: Style) diag.RenderError!void {
    if (bag.isEmpty()) return;
    const rows = bag.count();
    if (style.json) {
        try diag.renderJson(bag, w);
    } else {
        try diag.render(bag, w, .{ .palette = if (style.color) .on else .off });
    }
    assert(bag.count() == rows); // Rendering reorders rows, never drops one.
    try w.flush();
}

test report {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var none: Io.Writer.Allocating = .init(gpa);
    defer none.deinit();
    try report(&bag, &none.writer, .{ .color = true });
    try std.testing.expectEqualStrings("", none.written());

    try bag.add(.parse, .E1104, .none, "`x.sv` is an IEEE 1800 source", .{});
    var json: Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try report(&bag, &json.writer, .{ .json = true, .color = true });
    try std.testing.expect(std.mem.startsWith(u8, json.written(), "{\"code\":\"E1104\""));
    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try report(&bag, &text.writer, .{});
    try std.testing.expect(std.mem.find(u8, text.written(), "error[E1104]") != null);
    // No colour asked for: no escape byte.
    try std.testing.expect(std.mem.findScalar(u8, text.written(), 0x1b) == null);
}
