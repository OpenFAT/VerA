//! The seam between a contract device (`device.zig`) and the prebuilt
//! engine: the design-independent half of `rt` (the event loop with its
//! scheduler, nets and nonblocking rows, and the tick-boundary snapshot)
//! compiled once into an object (`exportAll`, under a root `vera` writes) and
//! linked under every device built with the same sources, compiler, target
//! and flags. A device's root declares `vera_prebuilt_engine` to reach it
//! through `@extern` here instead of compiling it.
//!
//! Both sides compile the same `State`, so its layout is shared by
//! construction; every symbol name carries `tag`, a hash of that layout and
//! of the root options, so an object built under any other one fails to link
//! instead of running.
//!
//! Zig numbers error values per compilation, so no error may cross the
//! seam except as `code`, and no vtable whose functions return errors may
//! be called from the side that did not build it. Hence only `quiet` engines
//! cross (`cLoop` refuses any other): a quiet run opens, reads and writes no
//! file and prints nothing, so the engine never calls the device's `std.Io`
//! nor inspects an error of its `Writer`. The device's allocator crosses: its
//! vtable returns no errors. Each process body is reached through `wrap`.
//! Clauses: none of its own; the engine's are `main.zig`'s.
//!
//! Contents:
//! - `pub const DispatchC`
//! - `pub const tag`
//! - `pub fn code(e: ?Error) u16`
//! - `pub fn decode(c: u16) ?Error`
//! - `pub inline fn call(f: DispatchC, s: *State, pc: u32) Error!void`
//! - `pub fn exportAll() void`
//! - `pub fn loop(s: *State, comptime four: design.Dispatch, comptime two: ?design.Dispatch, limit: u64) ?Error`
//! - `pub fn saveTo(s: *const State, buf: []u8) std.Io.Writer.Error!usize`
//! - `pub fn restore(s: *State, b: []const u8) Error!void`

const std = @import("std");
const design = @import("design.zig");
const entry = @import("main.zig");
const logic = @import("logic/root.zig");
const snapshot = @import("snapshot.zig");
const State = @import("State.zig");
const Error = design.Error;

/// A device's dispatch as the engine calls it: `code` of its error.
pub const DispatchC = *const fn (*State, u32) callconv(.c) u16;

/// `State`'s layout (sizes, alignments and offsets, three levels down; no
/// type names, which number anonymous types per compilation) and the root
/// options the engine's code reads, as 16 hex digits.
pub const tag = blk: {
    @setEvalBranchQuota(1 << 20);
    var h: std.hash.Wyhash = .init(0x7e9_e1e);
    layout(&h, State, 3);
    layout(&h, design.Design, 2);
    h.update(&.{ @intFromBool(logic.two), @intFromBool(design.overrides), @intFromBool(design.activations) });
    h.update(std.mem.asBytes(&design.budget));
    break :blk std.fmt.comptimePrint("{x:0>16}", .{h.final()});
};

/// 0 for none, else the error.
pub fn code(e: ?Error) u16 {
    const x = e orelse return 0;
    return switch (x) {
        error.Failed => 1,
        error.Rerun => 2,
        error.OutOfMemory => 3,
        error.WriteFailed => 4,
    };
}

/// `code`'s inverse.
pub fn decode(c: u16) ?Error {
    return switch (c) {
        0 => null,
        1 => error.Failed,
        2 => error.Rerun,
        3 => error.OutOfMemory,
        else => error.WriteFailed,
    };
}

/// `f(s, pc)` for the engine's own `loop`.
pub inline fn call(f: DispatchC, s: *State, pc: u32) Error!void {
    if (decode(f(s, pc))) |e| return e;
}

/// Exports the entry points, hidden: they bind inside the one library.
pub fn exportAll() void {
    @export(&cLoop, .{ .name = sym("loop"), .visibility = .hidden });
    @export(&cSaveTo, .{ .name = sym("saveTo"), .visibility = .hidden });
    @export(&cRestore, .{ .name = sym("restore"), .visibility = .hidden });
}

// ---- the device's side ----

/// `main.loop` through the prebuilt object. 4-state only: asserts at comptime
/// that `two` is null. A state that is not `quiet` is `error.Failed`.
pub fn loop(s: *State, comptime four: design.Dispatch, comptime two: ?design.Dispatch, limit: u64) ?Error {
    comptime std.debug.assert(two == null);
    return decode(ext(cLoop, "loop")(s, wrap(four), limit));
}

/// `snapshot.save` of `s` into `buf` through the prebuilt object; the bytes
/// written, or `WriteFailed` when `buf` is too short.
pub fn saveTo(s: *const State, buf: []u8) std.Io.Writer.Error!usize {
    var n: usize = undefined;
    if (ext(cSaveTo, "saveTo")(s, buf.ptr, buf.len, &n) != 0) return error.WriteFailed;
    return n;
}

/// `snapshot.restore` of `s` from bytes `saveTo` wrote, through the
/// prebuilt object. A state that is not `quiet` is `error.Failed`.
pub fn restore(s: *State, b: []const u8) Error!void {
    if (decode(ext(cRestore, "restore")(s, b.ptr, b.len))) |e| return e;
}

// ---- private ----

fn layout(h: *std.hash.Wyhash, comptime T: type, comptime depth: u32) void {
    h.update(std.mem.asBytes(&[2]u64{ @alignOf(T), @sizeOf(T) }));
    if (depth == 0 or @typeInfo(T) != .@"struct") return;
    const s = @typeInfo(T).@"struct";
    inline for (s.field_names, s.field_types) |name, F| {
        h.update(name);
        h.update(std.mem.asBytes(&@as(u64, @offsetOf(T, name))));
        layout(h, F, depth - 1);
    }
}

fn sym(comptime name: []const u8) []const u8 {
    return "vera_rt_" ++ tag ++ "_" ++ name;
}

// ---- the engine's side ----

fn cLoop(s: *State, four: DispatchC, limit: u64) callconv(.c) u16 {
    if (!s.quiet) return code(error.Failed);
    return code(entry.loop(s, four, null, limit));
}

fn cSaveTo(s: *const State, buf: [*]u8, len: usize, n: *usize) callconv(.c) u16 {
    n.* = snapshot.saveTo(s, buf[0..len]) catch |e| return code(e);
    return 0;
}

fn cRestore(s: *State, b: [*]const u8, len: usize) callconv(.c) u16 {
    if (!s.quiet) return code(error.Failed);
    snapshot.restore(s, b[0..len]) catch |e| return code(e);
    return 0;
}

fn ext(comptime f: anytype, comptime name: []const u8) *const @TypeOf(f) {
    return @extern(*const @TypeOf(f), .{ .name = sym(name), .visibility = .hidden });
}

/// `f`, a `design.Dispatch`, as the engine calls it.
fn wrap(comptime f: design.Dispatch) DispatchC {
    return struct {
        fn c(s: *State, pc: u32) callconv(.c) u16 {
            f(s, pc) catch |e| return code(e);
            return 0;
        }
    }.c;
}

test "code and decode are inverse over no error and every error" {
    try std.testing.expectEqual(@as(u16, 0), code(null));
    try std.testing.expectEqual(@as(?Error, null), decode(0));
    const all = [_]Error{ error.Failed, error.Rerun, error.OutOfMemory, error.WriteFailed };
    for (all, 1..) |e, c| {
        try std.testing.expectEqual(@as(u16, @intCast(c)), code(e));
        try std.testing.expectEqual(@as(?Error, e), decode(@intCast(c)));
    }
}
