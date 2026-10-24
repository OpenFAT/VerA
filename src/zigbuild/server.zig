//! One `zig ... --listen=-` child and the compiler server protocol over its
//! stdin/stdout (`std.zig.Server`): spawn, request updates, read each
//! update's reply, reap. The protocol is the compiler's and is frozen; no
//! LRM clause.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = std.Build.Cache;
const ClientMsg = std.zig.Client.Message;
const ServerMsg = std.zig.Server.Message;
const assert = std.debug.assert;

// `wait` copies `bin_digest_len` bytes into a `BinDigest`.
comptime {
    assert(@sizeOf(Cache.BinDigest) == Cache.bin_digest_len);
}

/// One `zig ... --listen=-` child: the compiler server protocol over its
/// stdin/stdout. Must not move after `spawn`: `out.interface` is the reader.
pub const Server = struct {
    child: std.process.Child,
    out: Io.File.Reader,

    /// Starts `argv` with piped stdin and stdout and inherited stderr. The
    /// 64 KiB read buffer is allocated in `arena`, which must outlive `close`.
    /// Fails with `error.CompilerGone` when the child cannot be spawned.
    /// Asserts that `argv` names a program.
    pub fn spawn(s: *Server, io: Io, arena: Allocator, argv: []const []const u8) !void {
        assert(argv.len > 0);
        s.child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            // Compiler panics reach the terminal, and an unread stderr pipe
            // cannot fill and deadlock the update loop.
            .stderr = .inherit,
        }) catch return error.CompilerGone;
        // Steady-state buffer; larger message bodies go through `readAlloc`.
        s.out = s.child.stdout.?.readerStreaming(io, try arena.alloc(u8, 64 * 1024));
    }

    /// Asks for an exit and reaps the child.
    pub fn close(s: *Server, io: Io) void {
        if (s.child.stdin) |stdin| {
            send(io, &s.child, .exit) catch {};
            stdin.close(io);
            s.child.stdin = null;
        }
        _ = s.child.wait(io) catch s.child.kill(io);
    }

    /// One update's outcome: the output's cache digest, or the compiler's
    /// report.
    const Update = union(enum) {
        ok: Cache.BinDigest,
        failed: std.zig.ErrorBundle,
    };

    /// Reads one update's reply: an `error_bundle` message, possibly empty,
    /// ends it. A failed bundle is owned by `gpa`. Fails with
    /// `error.CompilerGone` when the stream ends or breaks,
    /// `error.ProtocolMismatch` on another compiler's messages, and
    /// `error.NoArtifact` when the update emitted nothing.
    pub fn wait(s: *Server, gpa: Allocator) !Update {
        const r = &s.out.interface;
        var digest: ?Cache.BinDigest = null;
        while (true) {
            const header = r.takeStruct(ServerMsg.Header, .little) catch return error.CompilerGone;
            const body = r.readAllocAll(gpa, header.bytes_len) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return error.CompilerGone,
            };
            defer gpa.free(body);

            switch (header.tag) {
                .zig_version => if (!std.mem.eql(u8, builtin.zig_version_string, body))
                    return error.ProtocolMismatch,
                .emit_digest => {
                    if (body.len < @sizeOf(ServerMsg.EmitDigest) + Cache.bin_digest_len)
                        return error.ProtocolMismatch;
                    digest = body[@sizeOf(ServerMsg.EmitDigest)..][0..Cache.bin_digest_len].*;
                },
                .error_bundle => {
                    var bundle = std.zig.Server.allocErrorBundle(gpa, body) catch |err| switch (err) {
                        error.OutOfMemory => |e| return e,
                        // A body shorter than the lengths it declares.
                        error.EndOfStream => return error.ProtocolMismatch,
                    };
                    if (bundle.errorMessageCount() > 0) return .{ .failed = bundle };
                    bundle.deinit(gpa);
                    break;
                },
                // file_system_inputs, time_report, test_*: nothing here uses them.
                else => {},
            }
        }
        return .{ .ok = digest orelse return error.NoArtifact };
    }
};

/// Sends one header-only message (`update` or `exit`). Fails with
/// `error.CompilerGone` once the child's stdin is closed or broken.
pub fn send(io: Io, child: *std.process.Child, tag: ClientMsg.Tag) !void {
    const stdin = child.stdin orelse return error.CompilerGone;
    var w = stdin.writer(io, &.{});
    w.interface.writeStruct(ClientMsg.Header{ .tag = tag, .bytes_len = 0 }, .little) catch
        return error.CompilerGone;
}

// ---- tests ------------------------------------------------------------------
// `wait` reads a recorded child stdout from a file: the message encoding is
// `std.zig.Server`'s (`serveEmitDigest`, `serveErrorBundle`), written out
// here field by field.

/// Appends one message, its header then `body`, as the compiler writes it.
fn putMsg(w: *Io.Writer, tag: ServerMsg.Tag, body: []const u8) !void {
    try w.writeStruct(ServerMsg.Header{ .tag = tag, .bytes_len = @intCast(body.len) }, .little);
    try w.writeAll(body);
}

/// An `error_bundle` body with no message: the end of a good update.
const empty_bundle: [@sizeOf(ServerMsg.ErrorBundle)]u8 = @splat(0);

/// Runs `Server.wait` over `stream` as the child's stdout.
fn waitOver(gpa: Allocator, stream: []const u8) !Server.Update {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "out", .data = stream });
    const file = try tmp.dir.openFile(io, "out", .{});
    defer file.close(io);
    // Smaller than some bodies: those go through `readAllocAll`.
    var buf: [16]u8 = undefined;
    var s: Server = undefined;
    s.out = file.readerStreaming(io, &buf);
    return s.wait(gpa);
}

test "Server.wait returns the digest an update emitted" {
    var bytes: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&bytes);
    const digest: Cache.BinDigest = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try putMsg(&w, .zig_version, builtin.zig_version_string);
    // A message nothing here reads is skipped whole.
    try putMsg(&w, .file_system_inputs, "\x01src/a.zig\x00");
    try putMsg(&w, .emit_digest, &([_]u8{1} ++ digest)); // flags, then the digest
    try putMsg(&w, .error_bundle, &empty_bundle);

    const u = try waitOver(std.testing.allocator, w.buffered());
    try std.testing.expect(u == .ok);
    try std.testing.expectEqualSlices(u8, &digest, &u.ok);
}

/// Writes into `w` one update that failed with a one-message report.
fn putFailed(w: *Io.Writer) !void {
    const gpa = std.testing.allocator;
    var wip: std.zig.ErrorBundle.Wip = try .init(gpa);
    errdefer wip.deinit();
    try wip.addRootErrorMessage(.{ .msg = try wip.addString("boom") });
    var sent = try wip.toOwnedBundle("");
    defer sent.deinit(gpa);
    try w.writeStruct(ServerMsg.Header{
        .tag = .error_bundle,
        .bytes_len = @intCast(@sizeOf(ServerMsg.ErrorBundle) + 4 * sent.extra.len + sent.string_bytes.len),
    }, .little);
    try w.writeStruct(ServerMsg.ErrorBundle{
        .extra_len = @intCast(sent.extra.len),
        .string_bytes_len = @intCast(sent.string_bytes.len),
    }, .little);
    try w.writeSliceEndian(u32, sent.extra, .little);
    try w.writeAll(sent.string_bytes);
}

test "Server.wait hands over a failed update's report" {
    const gpa = std.testing.allocator;
    var bytes: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&bytes);
    try putFailed(&w);

    var u = try waitOver(gpa, w.buffered());
    // `std.testing.allocator` fails the test if the caller-owned bundle leaks.
    switch (u) {
        .ok => return error.TestUnexpectedResult,
        .failed => |*b| {
            defer b.deinit(gpa);
            try std.testing.expectEqual(@as(u32, 1), b.errorMessageCount());
        },
    }
}

/// `waitOver`, then frees a failed update's report.
fn waitFreed(gpa: Allocator, stream: []const u8) !void {
    var u = try waitOver(gpa, stream);
    if (u == .failed) u.failed.deinit(gpa);
}

test "Server.wait frees every body and the report when an allocation fails" {
    var bytes: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&bytes);
    try putMsg(&w, .zig_version, builtin.zig_version_string);
    try putFailed(&w);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, waitFreed, .{w.buffered()});
}

test "Server.wait refuses a stream it cannot trust" {
    var bytes: [256]u8 = undefined;

    // Another compiler: the version string differs.
    var w: Io.Writer = .fixed(&bytes);
    try putMsg(&w, .zig_version, "0.0.0-other");
    try std.testing.expectError(error.ProtocolMismatch, waitOver(std.testing.allocator, w.buffered()));

    // A digest body one byte short of flags + `bin_digest_len`.
    const short: [Cache.bin_digest_len]u8 = @splat(0);
    w = .fixed(&bytes);
    try putMsg(&w, .emit_digest, &short);
    try std.testing.expectError(error.ProtocolMismatch, waitOver(std.testing.allocator, w.buffered()));

    // An error bundle shorter than its own header.
    w = .fixed(&bytes);
    try putMsg(&w, .error_bundle, &.{ 0, 0, 0, 0 });
    try std.testing.expectError(error.ProtocolMismatch, waitOver(std.testing.allocator, w.buffered()));

    // An update that ended without emitting anything.
    w = .fixed(&bytes);
    try putMsg(&w, .error_bundle, &empty_bundle);
    try std.testing.expectError(error.NoArtifact, waitOver(std.testing.allocator, w.buffered()));
}

test "Server.wait reports a child that went away" {
    var bytes: [64]u8 = undefined;
    // Nothing at all, then a header cut short, then a body cut short.
    try std.testing.expectError(error.CompilerGone, waitOver(std.testing.allocator, ""));
    try std.testing.expectError(error.CompilerGone, waitOver(std.testing.allocator, &.{ 1, 0, 0 }));
    var w: Io.Writer = .fixed(&bytes);
    try w.writeStruct(ServerMsg.Header{ .tag = .zig_version, .bytes_len = 10 }, .little);
    try w.writeAll("0.1");
    try std.testing.expectError(error.CompilerGone, waitOver(std.testing.allocator, w.buffered()));
}

test send {
    // A child whose stdin is already closed takes no message.
    var child: std.process.Child = undefined;
    child.stdin = null;
    try std.testing.expectError(error.CompilerGone, send(std.testing.io, &child, .update));
}
