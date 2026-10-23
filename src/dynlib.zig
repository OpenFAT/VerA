//! Opening a dynamic library: a `--emit-so` artifact (path → `DynLib`), for
//! the tests and test hosts that load one. VerA itself never loads a library;
//! the host does (`zigbuild` only builds it).
//!
//! The one file in lib/ and src/ that calls an OS directly
//! (`tests/unit.zig` allowlists it): Zig 0.17's `std.DynLib` has no
//! Windows loader, so Windows goes through the ntdll loader that std itself
//! uses (`std.Io.Threaded`). Every other target is `std.DynLib`.
//!
//! Cites no LRM clause: loading a library is the host's business.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

/// A loaded dynamic library: `open(path)`, `lookup(T, name)`, `close()`.
/// `std.DynLib` on every target but Windows, `Windows` there; the error set of
/// `open` is the target's, and every target has `error.FileNotFound`.
/// `open` trusts the file: its initializers run in this process.
pub const DynLib = if (builtin.target.os.tag == .windows) Windows else std.DynLib;

const Windows = struct {
    handle: windows.PVOID,

    /// `open`'s failures; each is described on `open`.
    pub const Error = error{ BadPathName, FileNotFound };

    /// Loads the library at `path`. Trusts the file, as `std.DynLib.open`
    /// does. A relative `path` is taken against the cwd, as on POSIX, not
    /// against the DLL search order. Fails with `error.BadPathName` when
    /// `path` is not WTF-8, holds a NUL, or does not fit `PATH_MAX_WIDE` UTF-16
    /// code units before or after it is made absolute, and with
    /// `error.FileNotFound` on any loader failure (no such file, not an
    /// image, an initializer that failed).
    pub fn open(path: []const u8) Error!Windows {
        // Bounded before converting: `wtf8ToWtf16Le` writes into `rel`
        // unchecked. A NUL would end the name early for the loader.
        const units = std.unicode.calcWtf16LeLen(path) catch return error.BadPathName;
        if (units >= windows.PATH_MAX_WIDE or std.mem.findScalar(u8, path, 0) != null) return error.BadPathName;
        var rel: [windows.PATH_MAX_WIDE:0]u16 = undefined;
        const n = std.unicode.wtf8ToWtf16Le(&rel, path) catch return error.BadPathName;
        rel[n] = 0;
        var full: [windows.PATH_MAX_WIDE]u16 = undefined;
        const bytes = windows.ntdll.RtlGetFullPathName_U(&rel, @sizeOf(@TypeOf(full)), &full, null);
        if (bytes == 0 or bytes >= @sizeOf(@TypeOf(full))) return error.BadPathName;
        var handle: windows.PVOID = undefined;
        return switch (windows.ntdll.LdrLoadDll(null, null, &.init(full[0 .. bytes / 2]), &handle)) {
            .SUCCESS => .{ .handle = handle },
            else => error.FileNotFound,
        };
    }

    /// Unloads the library. Invalidates every pointer `lookup` returned and
    /// `self`.
    pub fn close(self: *Windows) void {
        _ = windows.ntdll.LdrUnloadDll(self.handle);
    }

    /// Returns the exported symbol `name` as `T` (a pointer type), or null
    /// when the library exports no such name. Valid until `close`.
    pub fn lookup(self: *Windows, comptime T: type, name: [:0]const u8) ?T {
        var p: windows.PVOID = undefined;
        return switch (windows.ntdll.LdrGetProcedureAddress(self.handle, &.init(name), 0, &p)) {
            .SUCCESS => @ptrCast(@alignCast(p)),
            else => null,
        };
    }
};

// The positive path on every target is `tests/conformance/vera/host/vdev_so_host.zig` and
// `tests/conformance/vera/host/vpi_host.zig`, which load a `.so` VerA built. These pin the
// refusals, which those hosts never reach.

test "a library that does not exist is FileNotFound on every target" {
    // No slash: POSIX searches the system directories, Windows the cwd;
    // neither holds this name.
    try std.testing.expectError(error.FileNotFound, DynLib.open("vera-no-such-library.so"));
}

test "a path past every target's limit is an error, not a crash" {
    // 40000 bytes, all ASCII, so 40000 UTF-16 code units: past Windows'
    // PATH_MAX_WIDE (32767) and POSIX's PATH_MAX (4096 on Linux, 1024 on
    // macOS). Windows converts into a PATH_MAX_WIDE buffer, so a missing
    // bound there is an out-of-bounds write.
    const long: [40000]u8 = @splat('a');
    if (DynLib.open(&long)) |opened| {
        var lib = opened;
        lib.close();
        return error.TestUnexpectedResult;
    } else |_| {}
    if (builtin.target.os.tag == .windows)
        try std.testing.expectError(error.BadPathName, DynLib.open(&long));
}

test "on Windows, a path holding a NUL is BadPathName, not the path before it" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;
    // Truncated at the NUL this would be a plain missing file
    // (`FileNotFound`); the name as given is no path at all.
    try std.testing.expectError(error.BadPathName, DynLib.open("vera-no-such\x00.dll"));
}

test "on Windows, a system DLL opens by absolute path and resolves its exports" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;
    var lib = try DynLib.open("C:\\Windows\\System32\\kernel32.dll");
    defer lib.close();
    try std.testing.expect(lib.lookup(*const fn () callconv(.winapi) u32, "GetCurrentProcessId") != null);
    try std.testing.expect(lib.lookup(*const anyopaque, "vera_no_such_export") == null);
}
