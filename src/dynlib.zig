//! Library loading: a dynamic library's path in, a handle whose exported
//! symbols resolve by name out. For the tests and test hosts that load a
//! `--emit-so` artifact; VerA itself never loads a library, the host does
//! (`zigbuild` only builds it).
//!
//! The one file of lib/ and src/ that calls an OS directly (`tests/unit.zig`
//! allowlists it): Zig 0.18's `std.DynLib` has no Windows loader, so Windows
//! goes through the ntdll loader std itself uses (`std.Io.Threaded`). Every
//! other target is std's `dlopen` loader (`DlDynLib`, the `inner` of
//! `std.DynLib` there).
//!
//! Cites no LRM clause: loading a library is the host's business.
//!
//! Contents:
//! - `pub const DynLib = struct`
//! - `pub const DynLib.OpenError = error{ FileNotFound, NameTooLong, BadPathName }`
//! - `pub fn DynLib.open(path: []const u8) OpenError!DynLib`
//! - `pub fn DynLib.close(self: *DynLib) void`
//! - `pub fn DynLib.lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T`

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const windows = std.os.windows;

/// A loaded dynamic library: `open(path)`, then `lookup(T, name)` per
/// symbol, then `close()`. Every target fails `open` with the same
/// `OpenError`.
/// On Linux the program must link glibc (`link_libc`, a `-gnu` target):
/// without it, or on static musl, std's only loader is `ElfDynLib`, which
/// maps the segments and applies no relocation, so every pointer the
/// library stores is an unrelocated offset. The nix package built
/// `libvera-vpi.a` that way and each analog VPI application segfaulted in
/// `vera_vpi_open`; such a build is refused at compile time.
pub const DynLib = struct {
    handle: Handle,

    /// Every way `open` fails. No library is loaded after any of them.
    pub const OpenError = error{
        /// The loader refused `path`: no such file, not a library for this
        /// target, or an initializer of the library failed.
        FileNotFound,
        /// `path` does not fit the target's path limit: POSIX `PATH_MAX`
        /// bytes, or `PATH_MAX_WIDE` UTF-16 code units on Windows, before
        /// or after it is made absolute.
        NameTooLong,
        /// `path` holds a NUL byte, so it names no file (the loader would
        /// read only the bytes before it), or on Windows is not WTF-8 or
        /// cannot be made absolute.
        BadPathName,
    };

    /// Loads the library at `path`. A relative `path` is taken against the
    /// cwd on Windows, as on POSIX with a slash in it, not against the DLL
    /// search order. Trusts the file: its initializers run in this process.
    pub fn open(path: []const u8) OpenError!DynLib {
        if (std.mem.findScalar(u8, path, 0) != null) return error.BadPathName;
        const handle: Handle = if (is_windows) try openWindows(path) else try Dl.open(path);
        return .{ .handle = handle };
    }

    /// Unloads the library. Invalidates `self` and every pointer `lookup`
    /// returned. Asserts that the loader takes the library back, which a
    /// library opened once and closed once always is.
    pub fn close(self: *DynLib) void {
        if (is_windows) {
            const status = windows.ntdll.LdrUnloadDll(self.handle);
            assert(status == .SUCCESS); // A second close of one handle fails here.
        } else {
            self.handle.close();
        }
        self.* = undefined;
    }

    /// Returns the exported symbol `name` as `T`, a pointer type, or null
    /// when the library exports no such name. The pointer is valid until
    /// `close`. Asserts that `name` is not empty and holds no NUL before
    /// its end.
    pub fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        comptime assert(@typeInfo(T) == .pointer);
        assert(name.len > 0);
        assert(std.mem.findScalar(u8, name, 0) == null); // The loader would read a shorter name.
        if (!is_windows) return self.handle.lookup(T, name);
        var p: windows.PVOID = undefined;
        return switch (windows.ntdll.LdrGetProcedureAddress(self.handle, &.init(name), 0, &p)) {
            .SUCCESS => @ptrCast(@alignCast(p)),
            else => null, // else: every failure status is "no such export" to the caller
        };
    }
};

const is_windows = builtin.target.os.tag == .windows; // os: the one OS split, below

const Handle = if (is_windows)
    windows.PVOID
else if (builtin.target.os.tag == .linux and (!builtin.link_libc or builtin.target.abi.isMusl())) // os: refused, see DynLib
    @compileError("dynlib on Linux needs glibc (link_libc, a -gnu target): std's ElfDynLib applies no relocations")
else
    Dl;

/// std's `dlopen` loader, which std does not export by name: the `inner` of
/// `std.DynLib` on a target with libc. Its error set, `FileNotFound` and
/// `NameTooLong`, is a subset of `OpenError`, which the compiler checks.
const Dl = @FieldType(std.DynLib, "inner");

// ---- private ----

/// Windows' `open`: `path` (WTF-8, no NUL) made absolute in UTF-16, then
/// `LdrLoadDll`.
fn openWindows(path: []const u8) DynLib.OpenError!windows.PVOID {
    assert(std.mem.findScalar(u8, path, 0) == null); // `open` refused it.
    // Bounded before converting: `wtf8ToWtf16Le` writes into `rel` unchecked.
    const units = std.unicode.calcWtf16LeLen(path) catch return error.BadPathName;
    if (units >= windows.PATH_MAX_WIDE) return error.NameTooLong;
    var rel: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(&rel, path) catch return error.BadPathName;
    assert(n == units);
    rel[n] = 0;
    var full: [windows.PATH_MAX_WIDE]u16 = undefined;
    const bytes = windows.ntdll.RtlGetFullPathName_U(&rel, @sizeOf(@TypeOf(full)), &full, null);
    if (bytes == 0) return error.BadPathName;
    if (bytes >= @sizeOf(@TypeOf(full))) return error.NameTooLong;
    assert(bytes % 2 == 0); // A count of bytes of UTF-16 code units.
    var handle: windows.PVOID = undefined;
    return switch (windows.ntdll.LdrLoadDll(null, null, &.init(full[0 .. bytes / 2]), &handle)) {
        .SUCCESS => handle,
        else => error.FileNotFound, // else: every loader failure is "no library here" to the caller
    };
}

// The positive path through a VerA library is `tests/host/vdev_so_host.zig`
// and `src/vpi/host.zig`, which load a `.so` VerA built; these pin the
// refusals, which those hosts never reach, and a system library that every
// target ships.

test "a library that does not exist is FileNotFound on every target" {
    // No slash: POSIX searches the system directories, Windows the cwd;
    // neither holds this name.
    try std.testing.expectError(error.FileNotFound, DynLib.open("vera-no-such-library.so"));
}

test "a path past every target's limit is NameTooLong, not a crash" {
    // 40000 bytes, all ASCII, so 40000 UTF-16 code units: past Windows'
    // PATH_MAX_WIDE (32767) and POSIX's PATH_MAX (4096 on Linux, 1024 on
    // macOS). Windows converts into a PATH_MAX_WIDE buffer, so a missing
    // bound there is an out-of-bounds write.
    const long: [40000]u8 = @splat('a');
    try std.testing.expectError(error.NameTooLong, DynLib.open(&long));
    // The neighbour inside every limit is a plain missing file.
    try std.testing.expectError(error.FileNotFound, DynLib.open(long[0..200]));
}

test "a path holding a NUL is BadPathName on every target, not the path before it" {
    // Truncated at the NUL this would be a plain missing file; the name as
    // given is no path at all. std's POSIX path conversion asserts on a NUL,
    // so before this check the input crashed the process there.
    try std.testing.expectError(error.BadPathName, DynLib.open("vera-no-such\x00.so"));
    try std.testing.expectError(error.BadPathName, DynLib.open("\x00"));
}

test "a system library opens by path and resolves its exports" {
    const lib_path, const export_name = switch (builtin.target.os.tag) { // os: one system library per target
        .windows => .{ "C:\\Windows\\System32\\kernel32.dll", "GetCurrentProcessId" },
        .linux => .{ "libc.so.6", "getpid" },
        .macos => .{ "/usr/lib/libSystem.B.dylib", "getpid" },
        .freebsd => .{ "libc.so.7", "getpid" },
        else => return error.NoSystemLibraryNamedForThisTarget, // else: add the target's libc here
    };
    var lib = try DynLib.open(lib_path);
    defer lib.close();
    try std.testing.expect(lib.lookup(*const anyopaque, export_name) != null);
    try std.testing.expect(lib.lookup(*const anyopaque, "vera_no_such_export") == null);
}
