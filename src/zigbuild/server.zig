//! One `zig ... --listen=-` child and the compiler server protocol over its
//! stdin and stdout (`std.zig.Server`): an argv in, the child spawned, update
//! requests out, each update's reply (an output digest or an error bundle)
//! back. Cites no LRM clause: the protocol is the compiler's and is frozen.
//!
//! Contents:
//! - `pub const Error = Allocator.Error || error{ CompilerGone, ProtocolMismatch, NoArtifact }`
//! - `pub const Update = union(enum) { ok: Cache.BinDigest, failed: std.zig.ErrorBundle }`
//! - `pub const Server = struct`
//! - `Server.spawn(s: *Server, io: Io, arena: Allocator, argv: []const []const u8) Error!void`
//! - `Server.update(s: *Server, io: Io) Error!void`
//! - `Server.wait(s: *Server, gpa: Allocator) Error!Update`
//! - `Server.close(s: *Server, io: Io) void`

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = std.Build.Cache;
const ClientMsg = std.zig.Client.Message;
const ServerMsg = std.zig.Server.Message;
const assert = std.debug.assert;

/// Every way a child build fails to answer. After any error the child may
/// still be running; `Server.close` reaps it.
pub const Error = Allocator.Error || error{
    /// The child could not be spawned, or its stdin or stdout closed or broke
    /// before the update ended.
    CompilerGone,
    /// The child speaks another compiler's protocol: a version string that is
    /// not the one VerA was built with, or a message shorter than its kind.
    ProtocolMismatch,
    /// The update ended with no error and no output digest.
    NoArtifact,
};

/// One update's outcome: the output's cache digest, or the compiler's report.
/// A `failed` bundle is owned by the `gpa` given to `Server.wait`.
pub const Update = union(enum) {
    ok: Cache.BinDigest,
    failed: std.zig.ErrorBundle,
};

/// One `zig ... --listen=-` child. Not thread-safe; one thread drives it.
/// Must not move after `spawn`: `out.interface` is the reader of the child's
/// stdout and refers back to `out`.
pub const Server = struct {
    child: std.process.Child,
    out: Io.File.Reader,

    /// Starts `argv` with piped stdin and stdout and an inherited stderr, so a
    /// compiler panic reaches the terminal and an unread stderr pipe cannot
    /// fill and deadlock the update loop. The read buffer is allocated in
    /// `arena`, which must outlive `close`. Fails with `error.CompilerGone`
    /// when the child cannot be spawned. Asserts that `argv` names a program.
    pub fn spawn(s: *Server, io: Io, arena: Allocator, argv: []const []const u8) Error!void {
        assert(argv.len > 0);
        assert(argv[0].len > 0);
        const buffer = try arena.alloc(u8, read_buffer_bytes);
        s.child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        }) catch return error.CompilerGone;
        s.out = s.child.stdout.?.readerStreaming(io, buffer);
        assert(s.child.stdin != null);
    }

    /// Asks the child for one update. Fails with `error.CompilerGone` once
    /// its stdin is closed or broken.
    pub fn update(s: *Server, io: Io) Error!void {
        return send(io, &s.child, .update);
    }

    /// Reads one update's reply, up to the `error_bundle` message that ends
    /// it. Fails as `Error` says; every message body read is freed on every
    /// path, and a failed bundle is the caller's to free with `gpa`.
    pub fn wait(s: *Server, gpa: Allocator) Error!Update {
        const r = &s.out.interface;
        var digest: ?Cache.BinDigest = null;
        for (0..update_messages_max) |_| {
            const header = r.takeStruct(ServerMsg.Header, .little) catch return error.CompilerGone;
            const body = r.readAllocAll(gpa, header.bytes_len) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return error.CompilerGone,
            };
            defer gpa.free(body);
            assert(body.len == header.bytes_len);

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
                    return .{ .ok = digest orelse return error.NoArtifact };
                },
                // file_system_inputs, time_report, test_*: nothing here reads them.
                else => {},
            }
        }
        return error.ProtocolMismatch;
    }

    /// Asks the child to exit and reaps it, killing it when the wait fails.
    /// Invalidates `s`.
    pub fn close(s: *Server, io: Io) void {
        if (s.child.stdin) |stdin| {
            // The only failure is a child already gone, which the wait reaps.
            send(io, &s.child, .exit) catch |err| assert(err == error.CompilerGone);
            stdin.close(io);
            s.child.stdin = null;
        }
        assert(s.child.stdin == null);
        _ = s.child.wait(io) catch s.child.kill(io);
        s.* = undefined;
    }
};

/// Most messages one update may send before its closing `error_bundle`. The
/// compiler sends a handful (version, inputs, time report, digest); a stream
/// past this is not the compiler's.
const update_messages_max = 1 << 16;

/// Bytes of steady-state read buffer per child; a larger body is read whole
/// into `gpa` (`readAllocAll`).
const read_buffer_bytes = 64 * 1024;

/// An `error_bundle` body with no message: the end of a good update (tests).
const empty_bundle: [@sizeOf(ServerMsg.ErrorBundle)]u8 = @splat(0);

comptime {
    // `wait` copies `bin_digest_len` bytes into a `BinDigest`.
    assert(@sizeOf(Cache.BinDigest) == Cache.bin_digest_len);
    assert(read_buffer_bytes >= @sizeOf(ServerMsg.Header));
}

// ---- private ----

/// Sends one header-only message (`update` or `exit`). Fails with
/// `error.CompilerGone` once the child's stdin is closed or broken.
fn send(io: Io, child: *std.process.Child, tag: ClientMsg.Tag) error{CompilerGone}!void {
    assert(tag == .update or tag == .exit);
    const stdin = child.stdin orelse return error.CompilerGone;
    var w = stdin.writer(io, &.{});
    w.interface.writeStruct(ClientMsg.Header{ .tag = tag, .bytes_len = 0 }, .little) catch
        return error.CompilerGone;
}

/// Appends one message, its header then `body`, as the compiler writes it.
fn putMsg(w: *Io.Writer, tag: ServerMsg.Tag, body: []const u8) !void {
    try w.writeStruct(ServerMsg.Header{ .tag = tag, .bytes_len = @intCast(body.len) }, .little);
    try w.writeAll(body);
}

/// Runs `Server.wait` over `stream` as the child's stdout.
fn waitOver(gpa: Allocator, stream: []const u8) !Update {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "out", .data = stream });
    const file = try tmp.dir.openFile(io, "out", .{});
    defer file.close(io);
    // Smaller than some bodies: those go through `readAllocAll`.
    var buf: [16]u8 = undefined;
    // SAFETY: `wait` reads only `out`; `child` is never touched.
    var s: Server = undefined;
    s.out = file.readerStreaming(io, &buf);
    return s.wait(gpa);
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

/// `waitOver`, then frees a failed update's report.
fn waitFreed(gpa: Allocator, stream: []const u8) !void {
    var u = try waitOver(gpa, stream);
    if (u == .failed) u.failed.deinit(gpa);
}

// The oracle for `wait` is `std.zig.Server`'s message encoding
// (`serveEmitDigest`, `serveErrorBundle`), written out field by field above.

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
