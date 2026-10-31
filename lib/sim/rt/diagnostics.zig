//! A run-time refusal or warning in, one diagnostic line on stderr out,
//! after the transcript so far, in `vera --run`'s words (E1100, W11xx).
//! Cites: none (the house diagnostic format, lib/diag).
//!
//! Contents:
//! - `pub fn exit(self: *State, failed: ?Error) u8`
//! - `pub fn fail(self: *State, comptime message: []const u8, args: anytype) Error`
//! - `pub fn say(self: *State, comptime message: []const u8, args: anytype) void`
//! - `pub fn warn(self: *State, comptime code: []const u8, comptime message: []const u8, args: anytype) void`
//! - `pub fn diagnose(self: *State, comptime head: []const u8, comptime message: []const u8, args: anytype) void`

const std = @import("std");
const assert = std.debug.assert;
const digital = @import("../digital/root.zig");
const State = @import("State.zig");
const design = @import("design.zig");
const Error = design.Error;

/// Returns the exit status, after flushing the transcript: 0 when the run
/// ended without `failed` and the transcript reached its sink, else 1. A
/// failure other than a refusal already reported is reported here.
pub fn exit(self: *State, failed: ?Error) u8 {
    const flushed = if (self.out.flush()) true else |_| false;
    if (failed) |e| if (e != error.Failed) self.say("digital execution failed: {t}", .{e});
    const code: u8 = if (failed == null and flushed) 0 else 1;
    if (failed != null) assert(code == 1);
    return code;
}

/// A run-time refusal in `vera --run`'s words (E1100), on stderr.
pub fn fail(self: *State, comptime message: []const u8, args: anytype) Error {
    comptime assert(message.len != 0);
    self.say(message, args);
    return error.Failed;
}

/// `fail`'s line without the error: an E1100 refusal on stderr.
pub fn say(self: *State, comptime message: []const u8, args: anytype) void {
    self.diagnose("error[E1100]: ", message, args);
}

/// A run-time warning in `vera --run`'s words, on stderr.
pub fn warn(self: *State, comptime code: []const u8, comptime message: []const u8, args: anytype) void {
    comptime assert(code.len == 5); // `W` and four digits.
    self.diagnose("warning[" ++ code ++ "]: ", message, args);
}

/// One diagnostic line on stderr, `head` then the message, after the
/// transcript so far.
pub fn diagnose(self: *State, comptime head: []const u8, comptime message: []const u8, args: anytype) void {
    comptime assert(head.len != 0);
    if (self.quiet) return;
    // A transcript that cannot be flushed fails the run at `exit`; the
    // diagnostic still goes out.
    self.out.flush() catch {};
    var buf: [512]u8 = undefined;
    var e = std.Io.File.stderr().writerStreaming(self.io, &buf);
    // Nothing is left to tell when stderr itself fails.
    e.interface.print(head ++ message ++ "\n", args) catch return;
    e.interface.flush() catch return;
}
