//! A child process run to completion: argv -> everything it printed and its
//! exit code. The digital, `--native`, `--fuzz`, `vpi` and `spice` modes each
//! judge a `vera` (or `zig cc`) run by its two streams, so they share this.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Both streams, whole, and the exit code; a signal or stop is 255.
const Captured = struct { stdout: []const u8, stderr: []const u8, exit: u8 };

/// Runs a child and takes everything it said. Both streams are allocated in
/// `arena`; a spawn failure is the error.
pub fn capture(arena: Allocator, io: Io, argv: []const []const u8) !Captured {
    return captureIn(arena, io, argv, null);
}

/// `capture` with the child's working directory at `cwd` (null: this one).
pub fn captureIn(arena: Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8) !Captured {
    const r = try std.process.run(arena, io, .{ .argv = argv, .cwd = if (cwd) |p| .{ .path = p } else .inherit });
    return .{ .stdout = r.stdout, .stderr = r.stderr, .exit = switch (r.term) {
        .exited => |c| c,
        else => 255,
    } };
}
