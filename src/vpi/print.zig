//! The output channels: §12.24-§12.28's multichannel descriptors (the
//! predefined three and the files an application opens) and the HDL's own
//! §17.2 file descriptors shared with the digital engine, with the printf
//! family's writes. The variadic entry points are C, in `varargs.c` (`va.zig`).
//! Cites: VAMS-2023 §12.24-§12.28; IEEE 1364-2005 §17.2.1, §27.22-§27.26.
//!
//! Contents:
//! - `pub fn setLogFile(path: []const u8) error`
//! - `pub fn vpi_mcd_open(file: [*c]const u8) c_uint`
//! - `pub fn bit(i: usize) c_uint`
//! - `pub fn vpi_mcd_close(mcd: c_uint) c_uint`
//! - `pub fn vpi_mcd_name(cd: c_uint) [*c]u8`
//! - `pub fn share(r: *digital.Run) void`
//! - `pub fn vpi_flush() c_int`
//! - `pub fn vpi_mcd_flush(mcd: c_uint) c_int`

const std = @import("std");
const digital = @import("sim").digital;
const sim = @import("sim");
const Io = std.Io;
const gpa = std.heap.smp_allocator;
const cformat = @import("cformat.zig");
const schema = @import("schema.zig");
const status = @import("status.zig");
const user = @import("vpi_user.zig");
const va = @import("va.zig");
const List = va.List;

const FileIo = @typeInfo(@FieldType(digital.system.TaskState, "file_io")).optional.child;

/// Channels 4..31: the 28 an mcd has room for above the three predefined ones
/// and below bit 31, which IEEE 1364-2005 §27.26 reserves to mark "a file
/// descriptor instead of an mcd".
const first_user = 3; // index of channel 4

const channel_count = 31;
const fd_bit = 1 << 31;

const Channel = struct {
    file: Io.File,
    /// NUL-terminated, owned by `gpa`.
    name: [:0]u8,
};

var channels: [channel_count]?Channel = @splat(null);

/// §12.26 "Descriptor 3 is the current log file": its name, owned by `gpa`,
/// and the file once the first write created it.
var log_name: ?[:0]u8 = null;

var log_file: ?Io.File = null;

/// §12.25's buffer: "This routine shall overwrite the returned value on
/// subsequent calls."
var name_buf: [schema.name_buf_len]u8 = undefined;

/// The table an fd opens in: the engine's own, or the one the run had.
var fds: FileIo = digital.own_files;

/// Each open fd's name, by its channel number (§27.24).
var fd_names: [64]?[:0]u8 = @splat(null);

/// Names the product log file channel 3 writes, in the working directory
/// unless `path` says otherwise. The LRM names no file; a host picks one
/// (src/vpi/host.zig: the application's name with `.log`).
pub fn setLogFile(path: []const u8) error{OutOfMemory}!void {
    // The copy first: on failure the old name stays named.
    const name = try gpa.dupeSentinel(u8, path, 0);
    if (log_file) |f| f.close(io());
    log_file = null;
    if (log_name) |n| gpa.free(n);
    log_name = name;
}

/// §12.26 "shall open a file for writing and return a corresponding
/// multichannel descriptor number ... shall return a zero (0) on error. If the
/// file is already opened, vpi_mcd_open() shall return the descriptor number."
pub export fn vpi_mcd_open(file: [*c]const u8) c_uint {
    if (status.refused("vpi_mcd_open")) return 0;
    if (file == null) {
        status.fail("BADNAME", "vpi_mcd_open: the file name is NULL", .{});
        return 0;
    }
    const want = std.mem.span(file);
    return openChannel(want) catch |e| {
        switch (e) {
            error.NoChannel => status.fail("NOCHANNEL", "vpi_mcd_open: all 28 user channels are open", .{}),
            error.OutOfMemory => status.fail("NOMEM", "vpi_mcd_open: out of memory", .{}),
            else => status.fail("NOOPEN", "vpi_mcd_open: cannot open `{s}`: {t}", .{ want, e }),
        }
        return 0;
    };
}

pub fn bit(i: usize) c_uint {
    return @as(c_uint, 1) << @intCast(i);
}

/// §12.24 "On success this routine returns a zero (0); on error it returns the
/// mcd value of the unclosed channels." The predefined three "can not be
/// closed", and a channel that is not open cannot be closed either — both come
/// back in the return value, and both are an error. IEEE 1364-2005 §27.22: it
/// "can also be used to close file descriptors that were opened using the
/// system function $fopen()".
pub export fn vpi_mcd_close(mcd: c_uint) c_uint {
    if (status.refused("vpi_mcd_close")) return mcd;
    if (mcd & fd_bit != 0) {
        if (fdName(mcd) == null) {
            status.fail("NOCLOSE", "vpi_mcd_close: 0x{x} is no file descriptor $fopen opened", .{mcd});
            return mcd;
        }
        _ = hdlClose(mcd);
        return 0;
    }
    const unclosed = closeChannels(mcd);
    if (unclosed != 0) status.fail("NOCLOSE", "vpi_mcd_close: channels 0x{x} are predefined or not open", .{unclosed});
    return unclosed;
}

/// §12.25 "the name of a file represented by a single-channel descriptor ...
/// On error, the routine shall return NULL." IEEE 1364-2005 §27.24: "The
/// channel descriptor cd could be an fd file descriptor returned from $fopen".
pub export fn vpi_mcd_name(cd: c_uint) [*c]u8 {
    if (status.refused("vpi_mcd_name")) return null;
    const s: []const u8 = if (cd & fd_bit != 0) fdName(cd) orelse {
        status.fail("BADMCD", "vpi_mcd_name: 0x{x} is no file descriptor $fopen opened", .{cd});
        return null;
    } else name: {
        if (cd == 0 or cd & (cd - 1) != 0) {
            status.fail("BADMCD", "vpi_mcd_name: 0x{x} is not a single-channel descriptor", .{cd});
            return null;
        }
        const i = @ctz(cd);
        break :name switch (i) {
            0 => "stdout",
            1 => "stderr",
            2 => log_name orelse {
                status.fail("NOLOG", "vpi_mcd_name: this host names no product log file", .{});
                return null;
            },
            else => if (i < channel_count and channels[i] != null) channels[i].?.name else {
                status.fail("BADMCD", "vpi_mcd_name: channel {d} is not open", .{i + 1});
                return null;
            },
        };
    };
    const n = @min(s.len, name_buf.len - 1);
    @memcpy(name_buf[0..n], s[0..n]);
    name_buf[n] = 0;
    return &name_buf;
}

/// Makes `r`'s §17.2 tasks open, write and close an mcd as one of these
/// channels: IEEE 1364-2005 §27.25 "The mcd descriptors returned from
/// vpi_mcd_open() and from $fopen may be shared between the HDL system tasks
/// that use mcd descriptors and the VPI routines that use mcd descriptors."
/// An fd stays in `r`'s table, its name kept for §27.24.
pub fn share(r: *digital.Run) void {
    if (r.tasks.file_io) |t| if (t.open == hdlOpen) return;
    fds = r.tasks.file_io orelse digital.own_files;
    r.tasks.file_io = .{ .open = hdlOpen, .close = hdlClose, .put = hdlPut, .getc = fdGetc, .ungetc = fdUngetc, .tell = fdTell, .seek = fdSeek, .eof = fdEof, .err = fdErr };
}

/// IEEE 1364-2005 §27.4: "0 if successful; nonzero if unsuccessful". Every
/// write here is unbuffered, so there is nothing to flush.
pub export fn vpi_flush() c_int {
    if (status.refused("vpi_flush")) return 1;
    return 0;
}

/// IEEE 1364-2005 §27.23: 0 when every channel `mcd` names is open (writes
/// are unbuffered, so an open channel is already flushed); nonzero and an
/// error when a user channel it names is not open.
pub export fn vpi_mcd_flush(mcd: c_uint) c_int {
    if (status.refused("vpi_mcd_flush")) return 1;
    if (mcd & fd_bit != 0) {
        status.fail("BADMCD", "vpi_mcd_flush: 0x{x} is a $fopen file descriptor, not an mcd", .{mcd});
        return 1;
    }
    for (first_user..channel_count) |i| {
        if (mcd & bit(i) != 0 and channels[i] == null) {
            status.fail("BADMCD", "vpi_mcd_flush: channel {d} is not open", .{i + 1});
            return 1;
        }
    }
    return 0;
}

// ---- private ----

fn io() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// The channel open onto `name`, or the lowest free one opened onto it.
fn openChannel(name: []const u8) !c_uint {
    for (channels[first_user..], first_user..) |c, i| {
        if (c) |ch| if (std.mem.eql(u8, ch.name, name)) return bit(i);
    }
    const free = for (channels[first_user..], first_user..) |c, i| {
        if (c == null) break i;
    } else return error.NoChannel;
    const f = try Io.Dir.cwd().createFile(io(), name, .{});
    errdefer f.close(io());
    channels[free] = .{ .file = f, .name = try gpa.dupeSentinel(u8, name, 0) };
    return bit(free);
}

/// Closes every channel `mcd` names; returns the ones it could not.
fn closeChannels(mcd: c_uint) c_uint {
    var unclosed: c_uint = 0;
    for (0..channel_count) |i| {
        if (mcd & bit(i) == 0) continue;
        if (i < first_user) {
            unclosed |= bit(i);
            continue;
        }
        const ch = channels[i] orelse {
            unclosed |= bit(i);
            continue;
        };
        ch.file.close(io());
        gpa.free(ch.name);
        channels[i] = null;
    }
    return unclosed;
}

/// An fd's channel number: `d` without `fd_bit`.
fn fdChannel(d: i64) usize {
    return @intCast(d & 0x7fff_ffff);
}

fn fdName(d: i64) ?[:0]const u8 {
    const ch = fdChannel(d);
    return if (ch < fd_names.len) fd_names[ch] else null;
}

fn hdlOpen(path: []const u8, ty: []const u8, mcd: bool) i64 {
    if (mcd) return openChannel(path) catch 0;
    const d = fds.open(path, ty, false);
    const ch = fdChannel(d);
    if (d != 0 and ch < fd_names.len) {
        if (fd_names[ch]) |old| gpa.free(old);
        fd_names[ch] = gpa.dupeSentinel(u8, path, 0) catch null;
    }
    return d;
}

fn hdlClose(d: i64) i64 {
    if (d & fd_bit == 0) {
        _ = closeChannels(@truncate(@as(u64, @bitCast(d))));
        return 0;
    }
    const ch = fdChannel(d);
    if (ch < fd_names.len) if (fd_names[ch]) |old| {
        gpa.free(old);
        fd_names[ch] = null;
    };
    return fds.close(d);
}

/// The characters written, or 0 when no channel `d` names took them. The
/// engine writes bit 0 (its transcript) itself.
fn hdlPut(d: i64, text: []const u8) i64 {
    if (d & fd_bit != 0) return fds.put(d, text);
    var took = false;
    for (1..channel_count) |i| {
        if (d & bit(i) == 0) continue;
        const file = (channelFile(i) catch continue) orelse {
            took = true;
            continue;
        };
        file.writeStreamingAll(io(), text) catch continue;
        took = true;
    }
    return if (took) @intCast(text.len) else 0;
}

// An mcd is write-only: the reads see it as no descriptor at all, which also
// keeps it off the fd slot the engine's table would read its bits as.
fn fdOnly(d: i64) i64 {
    return if (d & fd_bit != 0) d else 0;
}

fn fdGetc(d: i64) i64 {
    return fds.getc(fdOnly(d));
}

fn fdUngetc(c: i64, d: i64) i64 {
    return fds.ungetc(c, fdOnly(d));
}

fn fdTell(d: i64) i64 {
    return fds.tell(fdOnly(d));
}

fn fdSeek(d: i64, off: i64, op: i64) i64 {
    return fds.seek(fdOnly(d), off, op);
}

fn fdEof(d: i64) i64 {
    return fds.eof(fdOnly(d));
}

fn fdErr(d: i64) i64 {
    return if (fds.err) |e| e(fdOnly(d)) else 0;
}

/// Channel `i`'s file; null for a log the host named none for, which
/// discards.
fn channelFile(i: usize) error{NotOpen}!?Io.File {
    return switch (i) {
        0 => .stdout(),
        1 => .stderr(),
        2 => {
            const name = log_name orelse return null;
            if (log_file == null) log_file = Io.Dir.cwd().createFile(io(), name, .{}) catch return error.NotOpen;
            return log_file;
        },
        else => if (channels[i]) |ch| ch.file else error.NotOpen,
    };
}

/// Returns 1 when the startup gate refuses the variadic routine `which`, with
/// the error recorded, else 0 (VD-044). `varargs.c`'s wrappers cannot name a
/// routine to the comptime `root.refused`, so they pass its number: 0
/// vpi_printf, 1 vpi_mcd_printf, 2 vpi_vprintf, 3 vpi_mcd_vprintf, anything
/// else vpi_control (vpi_sim_control too).
export fn vera_vpi_refused(which: c_int) c_int {
    return @intFromBool(switch (which) {
        0 => status.refused("vpi_printf"),
        1 => status.refused("vpi_mcd_printf"),
        2 => status.refused("vpi_vprintf"),
        3 => status.refused("vpi_mcd_vprintf"),
        else => status.refused("vpi_control"),
    });
}

/// The body of `varargs.c`'s vpi_printf (mcd 1 | 4: stdout and the log),
/// vpi_mcd_printf and their IEEE 1364-2005 §27.37/§27.27 `v` forms, over a
/// `va_list` the C side started. Clears the §12.2 status first.
///
/// §12.28 "shall write to both stdout and the current product log file ...
/// shall return the number of characters printed or EOF if an error occurred."
/// §12.27: the return is the number of characters in ONE expansion, however
/// many channels receive it: "the number of characters printed" is a property
/// of the format and its arguments, and a count multiplied by the channel set
/// would change with a bit of the mcd that has nothing to do with the text.
export fn vera_vpi_emit(mcd: c_uint, format: [*c]const u8, ap: *List) c_int {
    status.clearError();
    return emit(mcd, format, ap);
}

fn emit(mcd: c_uint, format: [*c]const u8, ap: *List) c_int {
    // IEEE 1364-2005 §27.26: the most significant bit marks "a file descriptor
    // instead of an mcd", and vpi_mcd_printf "shall not write to" one.
    if (mcd & fd_bit != 0) {
        status.fail("BADMCD", "vpi_mcd_printf: 0x{x} is a $fopen file descriptor, not an mcd", .{mcd});
        return cformat.EOF;
    }
    if (format == null) {
        status.fail("BADFORMAT", "vpi_printf: the format is NULL", .{});
        return cformat.EOF;
    }
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    if (!cformat.cformat(&out.writer, format, ap)) {
        status.fail("NOMEM", "vpi_printf: out of memory", .{});
        return cformat.EOF;
    }
    const text = out.written();
    for (0..channel_count) |i| {
        if (mcd & bit(i) == 0) continue;
        const file = (channelFile(i) catch {
            status.fail("BADMCD", "vpi_mcd_printf: channel {d} is not open", .{i + 1});
            return cformat.EOF;
        }) orelse continue;
        file.writeStreamingAll(io(), text) catch {
            status.fail("NOWRITE", "vpi_mcd_printf: write to channel {d} failed", .{i + 1});
            return cformat.EOF;
        };
    }
    return std.math.cast(c_int, text.len) orelse std.math.maxInt(c_int);
}

test "§12.24–§12.26: channel numbering, reopen, and the three predefined channels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Channel files are created relative to the cwd, so the test names an
    // absolute path inside its own temporary directory.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io(), &path_buf)];
    const a_path = try std.testing.allocator.printSentinel("{s}/a.log", .{dir}, 0);
    defer std.testing.allocator.free(a_path);

    try std.testing.expectEqual(@as(c_uint, 0x7), vpi_mcd_close(0x7));
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));

    const a = vpi_mcd_open(a_path.ptr);
    try std.testing.expectEqual(@as(c_uint, 8), a);
    try std.testing.expectEqual(a, vpi_mcd_open(a_path.ptr));
    try std.testing.expectEqualStrings(a_path, std.mem.span(vpi_mcd_name(a)));
    try std.testing.expectEqualStrings("stdout", std.mem.span(vpi_mcd_name(1)));
    // Not a single channel.
    try std.testing.expect(vpi_mcd_name(a | 1) == null);

    try std.testing.expectEqual(@as(c_int, 6), cformat.vpi_mcd_printf(a | 4, "alpha\n"));
    try std.testing.expectEqual(@as(c_uint, 0), vpi_mcd_close(a));
    try std.testing.expectEqual(a, vpi_mcd_close(a));
    try std.testing.expect(vpi_mcd_name(a) == null);
    // Writing to a closed channel is an error, and so says EOF.
    try std.testing.expectEqual(cformat.EOF, cformat.vpi_mcd_printf(a, "x"));

    var got: [16]u8 = undefined;
    const text = try tmp.dir.readFile(io(), "a.log", &got);
    try std.testing.expectEqualStrings("alpha\n", text);
}

test "§12.25/IEEE 1364-2005 §27.23: names and flushes of descriptors that are not open" {
    try std.testing.expect(vpi_mcd_name(0) == null);
    try std.testing.expectEqualStrings("stderr", std.mem.span(vpi_mcd_name(2)));
    // Channel 21 is not open; fd 63 is no file $fopen opened.
    try std.testing.expect(vpi_mcd_name(1 << 20) == null);
    try std.testing.expect(vpi_mcd_name(fd_bit | 63) == null);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    // The predefined channels are always open, and unbuffered.
    try std.testing.expectEqual(@as(c_int, 0), vpi_mcd_flush(0x7));
    try std.testing.expectEqual(@as(c_int, 1), vpi_mcd_flush(1 << 20));
    try std.testing.expectEqual(@as(c_int, 1), vpi_mcd_flush(fd_bit));
    try std.testing.expectEqual(@as(c_int, 0), vpi_flush());
    // vpi_mcd_printf writes to no fd, and needs a format.
    try std.testing.expectEqual(cformat.EOF, cformat.vpi_mcd_printf(fd_bit, "x"));
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
}

test "setLogFile: renaming the log keeps one name, owned once" {
    try setLogFile("a.log");
    try setLogFile("b.log");
    try std.testing.expectEqualStrings("b.log", std.mem.span(vpi_mcd_name(4)));
    gpa.free(log_name.?);
    log_name = null;
}
