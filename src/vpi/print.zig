//! §12.24-§12.28: `vpi_printf` and the multichannel descriptor family.
//! Channels 1-3 are stdout, stderr and the log (§12.27), predefined and
//! unclosable; `vpi_mcd_open` hands out the lowest free channel from 4.
//! Channel 3 is the product log file the host names (`setLogFile`), created
//! on its first write; with none named it discards. `vpi_printf` writes
//! channels 1 and 3.
//! While a digital design runs, the HDL's §17.2 tasks share these channels
//! (`share`, IEEE 1364-2005 §27.25). Formatting is C's printf done here over
//! `va.arg`, since the `vpi` module is linked into binaries without libc; the
//! variadic entry points themselves are C, in `varargs.c` (see `va.zig`).

const std = @import("std");
const root = @import("root.zig");
const digital = @import("sim").digital;
const va = @import("va.zig");

const Io = std.Io;
const FileIo = @typeInfo(@FieldType(digital.Run, "file_io")).optional.child;

fn io() Io {
    return Io.Threaded.global_single_threaded.io();
}

// ---------------------------------------------------------------------------
// The channels
// ---------------------------------------------------------------------------

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
const gpa = std.heap.smp_allocator;

/// §12.26 "Descriptor 3 is the current log file": its name, owned by `gpa`,
/// and the file once the first write created it.
var log_name: ?[:0]u8 = null;
var log_file: ?Io.File = null;

/// Names the product log file channel 3 writes, in the working directory
/// unless `path` says otherwise. The LRM names no file; a host picks one
/// (tests/conformance/vera/host/vpi_host.zig: the application's name with `.log`).
pub fn setLogFile(path: []const u8) error{OutOfMemory}!void {
    // The copy first: on failure the old name stays named.
    const name = try gpa.dupeSentinel(u8, path, 0);
    if (log_file) |f| f.close(io());
    log_file = null;
    if (log_name) |n| gpa.free(n);
    log_name = name;
}

/// §12.25's buffer: "This routine shall overwrite the returned value on
/// subsequent calls."
var name_buf: [root.name_buf_len]u8 = undefined;

/// §12.26 "shall open a file for writing and return a corresponding
/// multichannel descriptor number ... shall return a zero (0) on error. If the
/// file is already opened, vpi_mcd_open() shall return the descriptor number."
pub export fn vpi_mcd_open(file: [*c]const u8) c_uint {
    if (root.refused("vpi_mcd_open")) return 0;
    if (file == null) {
        root.fail("BADNAME", "vpi_mcd_open: the file name is NULL", .{});
        return 0;
    }
    const want = std.mem.span(file);
    return openChannel(want) catch |e| {
        switch (e) {
            error.NoChannel => root.fail("NOCHANNEL", "vpi_mcd_open: all 28 user channels are open", .{}),
            error.OutOfMemory => root.fail("NOMEM", "vpi_mcd_open: out of memory", .{}),
            else => root.fail("NOOPEN", "vpi_mcd_open: cannot open `{s}`: {t}", .{ want, e }),
        }
        return 0;
    };
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

fn bit(i: usize) c_uint {
    return @as(c_uint, 1) << @intCast(i);
}

/// §12.24 "On success this routine returns a zero (0); on error it returns the
/// mcd value of the unclosed channels." The predefined three "can not be
/// closed", and a channel that is not open cannot be closed either — both come
/// back in the return value, and both are an error. IEEE 1364-2005 §27.22: it
/// "can also be used to close file descriptors that were opened using the
/// system function $fopen()".
pub export fn vpi_mcd_close(mcd: c_uint) c_uint {
    if (root.refused("vpi_mcd_close")) return mcd;
    if (mcd & fd_bit != 0) {
        if (fdName(mcd) == null) {
            root.fail("NOCLOSE", "vpi_mcd_close: 0x{x} is no file descriptor $fopen opened", .{mcd});
            return mcd;
        }
        _ = hdlClose(mcd);
        return 0;
    }
    const unclosed = closeChannels(mcd);
    if (unclosed != 0) root.fail("NOCLOSE", "vpi_mcd_close: channels 0x{x} are predefined or not open", .{unclosed});
    return unclosed;
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

/// §12.25 "the name of a file represented by a single-channel descriptor ...
/// On error, the routine shall return NULL." IEEE 1364-2005 §27.24: "The
/// channel descriptor cd could be an fd file descriptor returned from $fopen".
pub export fn vpi_mcd_name(cd: c_uint) [*c]u8 {
    if (root.refused("vpi_mcd_name")) return null;
    const s: []const u8 = if (cd & fd_bit != 0) fdName(cd) orelse {
        root.fail("BADMCD", "vpi_mcd_name: 0x{x} is no file descriptor $fopen opened", .{cd});
        return null;
    } else name: {
        if (cd == 0 or cd & (cd - 1) != 0) {
            root.fail("BADMCD", "vpi_mcd_name: 0x{x} is not a single-channel descriptor", .{cd});
            return null;
        }
        const i = @ctz(cd);
        break :name switch (i) {
            0 => "stdout",
            1 => "stderr",
            2 => log_name orelse {
                root.fail("NOLOG", "vpi_mcd_name: this host names no product log file", .{});
                return null;
            },
            else => if (i < channel_count and channels[i] != null) channels[i].?.name else {
                root.fail("BADMCD", "vpi_mcd_name: channel {d} is not open", .{i + 1});
                return null;
            },
        };
    };
    const n = @min(s.len, name_buf.len - 1);
    @memcpy(name_buf[0..n], s[0..n]);
    name_buf[n] = 0;
    return &name_buf;
}

// ---------------------------------------------------------------------------
// The HDL's descriptors (IEEE 1364-2005 §27.22-§27.26)
// ---------------------------------------------------------------------------

/// The table an fd opens in: the engine's own, or the one the run had.
var fds: FileIo = digital.own_files;
/// Each open fd's name, by its channel number (§27.24).
var fd_names: [64]?[:0]u8 = @splat(null);

fn fdName(d: i64) ?[:0]const u8 {
    const ch: usize = @intCast(d & 0x7fff_ffff);
    return if (ch < fd_names.len) fd_names[ch] else null;
}

/// Makes `r`'s §17.2 tasks open, write and close an mcd as one of these
/// channels: IEEE 1364-2005 §27.25 "The mcd descriptors returned from
/// vpi_mcd_open() and from $fopen may be shared between the HDL system tasks
/// that use mcd descriptors and the VPI routines that use mcd descriptors."
/// An fd stays in `r`'s table, its name kept for §27.24.
pub fn share(r: *digital.Run) void {
    if (r.file_io) |t| if (t.open == hdlOpen) return;
    fds = r.file_io orelse digital.own_files;
    r.file_io = .{ .open = hdlOpen, .close = hdlClose, .put = hdlPut, .getc = fdGetc, .ungetc = fdUngetc, .tell = fdTell, .seek = fdSeek, .eof = fdEof, .err = fdErr };
}

fn hdlOpen(path: []const u8, ty: []const u8, mcd: bool) i64 {
    if (mcd) return openChannel(path) catch 0;
    const d = fds.open(path, ty, false);
    const ch: usize = @intCast(d & 0x7fff_ffff);
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
    const ch: usize = @intCast(d & 0x7fff_ffff);
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
        0 => root.refused("vpi_printf"),
        1 => root.refused("vpi_mcd_printf"),
        2 => root.refused("vpi_vprintf"),
        3 => root.refused("vpi_mcd_vprintf"),
        else => root.refused("vpi_control"),
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
export fn vera_vpi_emit(mcd: c_uint, format: [*c]const u8, ap: *va.List) c_int {
    root.clearError();
    return emit(mcd, format, ap);
}

/// IEEE 1364-2005 §27.4: "0 if successful; nonzero if unsuccessful". Every
/// write here is unbuffered, so there is nothing to flush.
pub export fn vpi_flush() c_int {
    if (root.refused("vpi_flush")) return 1;
    return 0;
}

/// IEEE 1364-2005 §27.23: 0 when every channel `mcd` names is open (writes
/// are unbuffered, so an open channel is already flushed); nonzero and an
/// error when a user channel it names is not open.
pub export fn vpi_mcd_flush(mcd: c_uint) c_int {
    if (root.refused("vpi_mcd_flush")) return 1;
    if (mcd & fd_bit != 0) {
        root.fail("BADMCD", "vpi_mcd_flush: 0x{x} is a $fopen file descriptor, not an mcd", .{mcd});
        return 1;
    }
    for (first_user..channel_count) |i| {
        if (mcd & bit(i) != 0 and channels[i] == null) {
            root.fail("BADMCD", "vpi_mcd_flush: channel {d} is not open", .{i + 1});
            return 1;
        }
    }
    return 0;
}

const EOF: c_int = -1;

fn emit(mcd: c_uint, format: [*c]const u8, ap: *va.List) c_int {
    // IEEE 1364-2005 §27.26: the most significant bit marks "a file descriptor
    // instead of an mcd", and vpi_mcd_printf "shall not write to" one.
    if (mcd & fd_bit != 0) {
        root.fail("BADMCD", "vpi_mcd_printf: 0x{x} is a $fopen file descriptor, not an mcd", .{mcd});
        return EOF;
    }
    if (format == null) {
        root.fail("BADFORMAT", "vpi_printf: the format is NULL", .{});
        return EOF;
    }
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    if (!cformat(&out.writer, format, ap)) {
        root.fail("NOMEM", "vpi_printf: out of memory", .{});
        return EOF;
    }
    const text = out.written();
    for (0..channel_count) |i| {
        if (mcd & bit(i) == 0) continue;
        const file = (channelFile(i) catch {
            root.fail("BADMCD", "vpi_mcd_printf: channel {d} is not open", .{i + 1});
            return EOF;
        }) orelse continue;
        file.writeStreamingAll(io(), text) catch {
            root.fail("NOWRITE", "vpi_mcd_printf: write to channel {d} failed", .{i + 1});
            return EOF;
        };
    }
    return std.math.cast(c_int, text.len) orelse std.math.maxInt(c_int);
}

// ---------------------------------------------------------------------------
// C11 7.21.6.1, over a va_list
// ---------------------------------------------------------------------------

const Spec = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    zero: bool = false,
    width: usize = 0,
    prec: ?usize = null,
};

const Length = enum { none, hh, h, l, ll, j, z, t, L };

/// Expand `fmt` against `ap`. A conversion C leaves undefined (an unknown
/// letter, a truncated spec) is copied through as written and consumes no
/// argument — the least wrong thing to do with a format nobody can read.
/// `%n` is not supported: it writes through an application pointer, and a
/// logging routine that stores into memory is a hazard this one does not take.
///
/// False when the writer failed (out of memory).
fn cformat(w: *Io.Writer, format: [*:0]const u8, ap: *va.List) bool {
    expand(w, std.mem.span(format), ap) catch return false;
    return true;
}

fn expand(w: *Io.Writer, fmt: []const u8, ap: *va.List) Io.Writer.Error!void {
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            const end = std.mem.findScalarPos(u8, fmt, i, '%') orelse fmt.len;
            try w.writeAll(fmt[i..end]);
            i = end;
            continue;
        }
        const start = i;
        i += 1;
        var s: Spec = .{};
        while (i < fmt.len) : (i += 1) switch (fmt[i]) {
            '-' => s.left = true,
            '+' => s.plus = true,
            ' ' => s.space = true,
            '#' => s.alt = true,
            '0' => s.zero = true,
            else => break,
        };
        if (i < fmt.len and fmt[i] == '*') {
            i += 1;
            const v = va.arg(ap, c_int);
            if (v < 0) s.left = true;
            s.width = @abs(v);
        } else while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
            s.width = s.width *| 10 +| (fmt[i] - '0');
        }
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            if (i < fmt.len and fmt[i] == '*') {
                i += 1;
                const v = va.arg(ap, c_int);
                s.prec = if (v < 0) null else @intCast(v);
            } else {
                var p: usize = 0;
                while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) p = p *| 10 +| (fmt[i] - '0');
                // C's precision is an `int`; past INT_MAX is undefined, and
                // clamped here so the arithmetic on it stays in range.
                s.prec = @min(p, std.math.maxInt(c_int));
            }
        }
        var len: Length = .none;
        if (i < fmt.len) switch (fmt[i]) {
            'h' => {
                i += 1;
                len = .h;
                if (i < fmt.len and fmt[i] == 'h') {
                    i += 1;
                    len = .hh;
                }
            },
            'l' => {
                i += 1;
                len = .l;
                if (i < fmt.len and fmt[i] == 'l') {
                    i += 1;
                    len = .ll;
                }
            },
            'j' => {
                i += 1;
                len = .j;
            },
            'z' => {
                i += 1;
                len = .z;
            },
            't' => {
                i += 1;
                len = .t;
            },
            'L' => {
                i += 1;
                len = .L;
            },
            else => {},
        };
        if (i >= fmt.len) {
            try w.writeAll(fmt[start..]);
            break;
        }
        const conv = fmt[i];
        i += 1;
        switch (conv) {
            '%' => try w.writeByte('%'),
            'd', 'i' => {
                const v: i128 = switch (len) {
                    .none, .h, .hh => blk: {
                        const x = va.arg(ap, c_int);
                        break :blk switch (len) {
                            .h => @as(i16, @truncate(x)),
                            .hh => @as(i8, @truncate(x)),
                            else => x,
                        };
                    },
                    .l => va.arg(ap, c_long),
                    .ll, .L => va.arg(ap, c_longlong),
                    .j => va.arg(ap, i64),
                    .z, .t => va.arg(ap, isize),
                };
                try integer(w, s, @intCast(@abs(v)), v < 0, 10, false);
            },
            'u', 'x', 'X', 'o' => {
                const v: u64 = switch (len) {
                    .none, .h, .hh => blk: {
                        const x: c_uint = @bitCast(va.arg(ap, c_int));
                        break :blk switch (len) {
                            .h => @as(u16, @truncate(x)),
                            .hh => @as(u8, @truncate(x)),
                            else => x,
                        };
                    },
                    .l => va.arg(ap, c_ulong),
                    .ll, .L => va.arg(ap, c_ulonglong),
                    .j => va.arg(ap, u64),
                    .z, .t => va.arg(ap, usize),
                };
                const base: u8 = switch (conv) {
                    'o' => 8,
                    'u' => 10,
                    else => 16,
                };
                try integer(w, s, v, false, base, conv == 'X');
            },
            'c' => {
                const b: u8 = @truncate(@as(c_uint, @bitCast(va.arg(ap, c_int))));
                try padded(w, s, &.{b});
            },
            's' => {
                const p = va.arg(ap, ?[*:0]const u8);
                var text: []const u8 = if (p) |q| std.mem.span(q) else "(null)";
                if (s.prec) |pr| text = text[0..@min(pr, text.len)];
                try padded(w, s, text);
            },
            'p' => {
                const p = va.arg(ap, usize);
                var buf: [2 + 16]u8 = undefined;
                const text = std.mem.print(&buf, "0x{x}", .{p}) catch unreachable;
                try padded(w, s, text);
            },
            'f', 'F', 'e', 'E', 'g', 'G' => {
                // ponytail: `long double` cannot be read from a va_list by this
                // compiler on SysV. Its size is not an f64's, so every later
                // argument would be misread: the rest of the format goes out
                // verbatim instead. `%L` in a VPI log line is the ceiling.
                if (len == .L) return w.writeAll(fmt[start..]);
                try real(w, s, va.arg(ap, f64), conv);
            },
            'n' => _ = va.arg(ap, ?*anyopaque),
            else => try w.writeAll(fmt[start..i]),
        }
    }
}

/// `text` in a field of `s.width`, space-padded on the side `-` selects.
fn padded(w: *Io.Writer, s: Spec, text: []const u8) Io.Writer.Error!void {
    const pad = s.width -| text.len;
    if (!s.left) try w.splatByteAll(' ', pad);
    try w.writeAll(text);
    if (s.left) try w.splatByteAll(' ', pad);
}

/// A sign or prefix, zeros, then digits, laid into the field. C's '0' flag
/// puts its padding BETWEEN the prefix and the digits, and is ignored when a
/// precision is given or the field is left-justified.
fn field(w: *Io.Writer, s: Spec, prefix: []const u8, zeros: usize, digits: []const u8, zero_ok: bool) Io.Writer.Error!void {
    const body = prefix.len + zeros + digits.len;
    const pad = s.width -| body;
    const zero_fill = s.zero and !s.left and zero_ok;
    if (!s.left and !zero_fill) try w.splatByteAll(' ', pad);
    try w.writeAll(prefix);
    if (zero_fill) try w.splatByteAll('0', pad);
    try w.splatByteAll('0', zeros);
    try w.writeAll(digits);
    if (s.left) try w.splatByteAll(' ', pad);
}

fn integer(w: *Io.Writer, s: Spec, mag: u64, neg: bool, base: u8, upper: bool) Io.Writer.Error!void {
    var buf: [64]u8 = undefined;
    var digits: []const u8 = buf[0..std.fmt.printInt(&buf, mag, base, if (upper) .upper else .lower, .{})];
    // "The result of converting a zero value with a precision of zero is no
    // characters."
    if (mag == 0 and s.prec != null and s.prec.? == 0) digits = "";
    var zeros: usize = if (s.prec) |p| p -| digits.len else 0;
    var prefix_buf: [2]u8 = undefined;
    var prefix: []const u8 = "";
    if (neg) prefix = "-" else if (base == 10 and s.plus) prefix = "+" else if (base == 10 and s.space) prefix = " ";
    if (s.alt and base == 8 and zeros == 0 and (digits.len == 0 or digits[0] != '0')) zeros = 1;
    if (s.alt and base == 16 and mag != 0) {
        prefix_buf = .{ '0', if (upper) 'X' else 'x' };
        prefix = &prefix_buf;
    }
    try field(w, s, prefix, zeros, digits, s.prec == null);
}

/// %e %f %g, C11 7.21.6.1 semantics over Zig's shortest-round-trip digits.
///
/// ponytail: rounding is of the SHORTEST decimal that round-trips, not of the
/// exact binary value, so a tie like `%.2f` of 0.125 (exactly representable)
/// can land on the other side of glibc's answer. That costs a last digit on a
/// logging routine; exact binary-to-decimal is the upgrade if an application
/// ever depends on it.
fn real(w: *Io.Writer, s: Spec, v: f64, conv: u8) Io.Writer.Error!void {
    const upper = std.ascii.isUpper(conv);
    const neg = std.math.signbit(v);
    const sign: []const u8 = if (neg) "-" else if (s.plus) "+" else if (s.space) " " else "";
    if (std.math.isNan(v) or std.math.isInf(v)) {
        const word = if (std.math.isNan(v)) (if (upper) "NAN" else "nan") else (if (upper) "INF" else "inf");
        return field(w, s, sign, 0, word, false);
    }
    const a = @abs(v);
    const p: usize = s.prec orelse 6;
    var buf: [512]u8 = undefined;
    const body: Body = switch (conv | 0x20) {
        'f' => fixed(&buf, a, p, s.alt),
        'e' => sci(&buf, a, p, upper, s.alt),
        else => blk: {
            // C: P = p, or 1 if p is 0. X = the exponent %e would print. Style
            // f with precision P-1-X if P > X >= -4, else style e with P-1;
            // then trailing zeros go unless '#'.
            const pg: usize = if (p == 0) 1 else p;
            const x = exponentAfterRounding(a, pg - 1);
            const out = if (x >= -4 and x < std.math.cast(i32, pg) orelse std.math.maxInt(i32))
                fixed(&buf, a, @intCast(@as(i64, @intCast(pg)) - 1 - x), s.alt)
            else
                sci(&buf, a, pg - 1, upper, s.alt);
            // The padding zeros are all fractional, so stripping takes them.
            break :blk if (s.alt) out else .{ .head = stripZeros(out.head), .tail = out.tail };
        },
    };
    const len = sign.len + body.head.len + body.zeros + body.tail.len;
    const pad = s.width -| len;
    const zero_fill = s.zero and !s.left;
    if (!s.left and !zero_fill) try w.splatByteAll(' ', pad);
    try w.writeAll(sign);
    if (zero_fill) try w.splatByteAll('0', pad);
    try w.writeAll(body.head);
    try w.splatByteAll('0', body.zeros);
    try w.writeAll(body.tail);
    if (s.left) try w.splatByteAll(' ', pad);
}

/// A real conversion's digits: `head`, then `zeros` more zeros, then `tail`
/// (an exponent). Zig renders the shortest round-trip digits and pads the rest
/// with zeros, so past `max_digits` a precision only adds zeros, and those are
/// written rather than rendered: no precision is clamped.
const Body = struct { head: []const u8, zeros: usize = 0, tail: []const u8 = "" };

/// Fraction digits past which %f's rendering is only zeros: the shortest
/// digits of an f64 end within 17 significant places of 4.9e-324.
const max_fixed = 341;
/// Mantissa digits past which %e's rendering is only zeros.
const max_sci = 17;

/// The decimal exponent of `a` printed as %e with `p` fraction digits — which
/// can be one more than `a`'s own when rounding carries (9.99 at p=1 is 1.0e1).
fn exponentAfterRounding(a: f64, p: usize) i32 {
    var buf: [64]u8 = undefined;
    const r = std.fmt.float.render(&buf, a, .{ .mode = .scientific, .precision = @min(p, max_sci) }) catch return 0;
    const e = std.mem.findScalar(u8, r, 'e') orelse return 0;
    return std.fmt.parseInt(i32, r[e + 1 ..], 10) catch 0;
}

fn fixed(buf: []u8, a: f64, p: usize, alt: bool) Body {
    const r = std.fmt.float.render(buf, a, .{ .mode = .decimal, .precision = @min(p, max_fixed) }) catch return .{ .head = "?" };
    if (p == 0 and alt) {
        buf[r.len] = '.';
        return .{ .head = buf[0 .. r.len + 1] };
    }
    return .{ .head = r, .zeros = p -| max_fixed };
}

/// Zig renders `1.5e3`; C wants `1.500000e+03` — at least two exponent digits
/// and an explicit sign.
fn sci(buf: []u8, a: f64, p: usize, upper: bool, alt: bool) Body {
    var tmp: [64]u8 = undefined;
    const r = std.fmt.float.render(&tmp, a, .{ .mode = .scientific, .precision = @min(p, max_sci) }) catch return .{ .head = "?" };
    const e = std.mem.findScalar(u8, r, 'e') orelse return .{ .head = "?" };
    const x = std.fmt.parseInt(i32, r[e + 1 ..], 10) catch 0;
    const mant = r[0..e];
    const dot = if (p == 0 and alt) "." else "";
    const head = std.mem.print(buf, "{s}{s}", .{ mant, dot }) catch return .{ .head = "?" };
    const tail = std.mem.print(buf[head.len..], "{c}{c}{d:0>2}", .{
        @as(u8, if (upper) 'E' else 'e'), @as(u8, if (x < 0) '-' else '+'), @abs(x),
    }) catch return .{ .head = "?" };
    return .{ .head = head, .zeros = p -| max_sci, .tail = tail };
}

/// %g's "trailing zeros are removed from the fractional portion of the result
/// and the decimal-point character is removed if there is no fractional
/// portion remaining", on a fixed result or an e-style mantissa.
fn stripZeros(s: []const u8) []const u8 {
    if (std.mem.findScalar(u8, s, '.') == null) return s;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

// ---------------------------------------------------------------------------
// Tests. The C-side check — that the header's prototypes and these exports
// agree, and that the channels hit the disk — is tests/fixtures/ch11_vpi/
// printf_mcd.c, run by `zig build test-vpi`.
// ---------------------------------------------------------------------------

/// `cformat` into `buf`, for `varargs.c`'s `vera_vpi_format`: 0 when it fails.
export fn vera_vpi_cformat(buf: [*]u8, len: usize, format: [*:0]const u8, ap: *va.List) usize {
    var w: Io.Writer = .fixed(buf[0..len]);
    if (!cformat(&w, format, ap)) return 0;
    return w.end;
}

/// `varargs.c`'s vpi_mcd_printf, for the tests below.
extern fn vpi_mcd_printf(mcd: c_uint, format: [*:0]const u8, ...) c_int;

/// Calls `cformat` the way a C caller would: through a variadic, into a
/// 512-byte buffer (`varargs.c`'s `vera_vpi_format`). Returns the length
/// written, 0 on failure.
const formatted = @extern(*const fn (buf: [*]u8, format: [*:0]const u8, ...) callconv(.c) usize, .{ .name = "vera_vpi_format" });

fn expectFormat(want: []const u8, got_len: usize, buf: []const u8) !void {
    try std.testing.expectEqualStrings(want, buf[0..got_len]);
}

test "C conversions: integers, flags, widths and precisions" {
    var b: [512]u8 = undefined;
    try expectFormat("p02 printf 7 ok\n", formatted(&b, "p02 printf %d %s\n", @as(c_int, 7), @as([*:0]const u8, "ok")), &b);
    try expectFormat("[   -42][-42   ][-0042][+42]", formatted(&b, "[%6d][%-6d][%05d][%+d]", @as(c_int, -42), @as(c_int, -42), @as(c_int, -42), @as(c_int, 42)), &b);
    try expectFormat("ff 0XFF 017 0x1f", formatted(&b, "%x %#X %#o %#x", @as(c_uint, 255), @as(c_uint, 255), @as(c_uint, 15), @as(c_uint, 31)), &b);
    try expectFormat("4294967295 18446744073709551615", formatted(&b, "%u %llu", @as(c_uint, 0xffffffff), @as(c_ulonglong, std.math.maxInt(u64))), &b);
    try expectFormat("[ab][   xyz][c]%", formatted(&b, "[%.2s][%*s][%c]%%", @as([*:0]const u8, "abc"), @as(c_int, 6), @as([*:0]const u8, "xyz"), @as(c_int, 'c')), &b);
    try expectFormat("[00007][]", formatted(&b, "[%.5d][%.0d]", @as(c_int, 7), @as(c_int, 0)), &b);
}

test "C conversions: reals" {
    var b: [512]u8 = undefined;
    try expectFormat("3.500000 1.500000e+03 2.5E-07", formatted(&b, "%f %e %.1E", @as(f64, 3.5), @as(f64, 1500.0), @as(f64, 2.5e-7)), &b);
    // %g: style f inside [1e-4, 1e6), style e outside, trailing zeros stripped.
    try expectFormat("0.0001 100000 1e+06 1e-05 0.5", formatted(&b, "%g %g %g %g %g", @as(f64, 1e-4), @as(f64, 1e5), @as(f64, 1e6), @as(f64, 1e-5), @as(f64, 0.5)), &b);
    try expectFormat("[  -1.25][-001.25][inf]", formatted(&b, "[%7.2f][%07.2f][%f]", @as(f64, -1.25), @as(f64, -1.25), std.math.inf(f64)), &b);
    try expectFormat("3.14159", formatted(&b, "%g", @as(f64, 3.14159265)), &b);
}

test "C conversions: a real's precision is never clamped" {
    var b: [512]u8 = undefined;
    // 0.5 exactly, 100 fraction digits: "0.5" then 99 zeros.
    try expectFormat("0.5" ++ @as([99]u8, @splat('0')), formatted(&b, "%.100f", @as(f64, 0.5)), &b);
    // 60 mantissa digits: "1." and 60 zeros, then the exponent.
    try expectFormat("1." ++ @as([60]u8, @splat('0')) ++ "e+00", formatted(&b, "%.60e", @as(f64, 1.0)), &b);
    // The smallest subnormal's one shortest digit (see `real`) sits at the
    // 324th place, past where the old 300-digit clamp cut it off.
    try expectFormat("0." ++ @as([323]u8, @splat('0')) ++ "5000000", formatted(&b, "%.330f", @as(f64, 5e-324)), &b);
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
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));

    const a = vpi_mcd_open(a_path.ptr);
    try std.testing.expectEqual(@as(c_uint, 8), a);
    try std.testing.expectEqual(a, vpi_mcd_open(a_path.ptr));
    try std.testing.expectEqualStrings(a_path, std.mem.span(vpi_mcd_name(a)));
    try std.testing.expectEqualStrings("stdout", std.mem.span(vpi_mcd_name(1)));
    // Not a single channel.
    try std.testing.expect(vpi_mcd_name(a | 1) == null);

    try std.testing.expectEqual(@as(c_int, 6), vpi_mcd_printf(a | 4, "alpha\n"));
    try std.testing.expectEqual(@as(c_uint, 0), vpi_mcd_close(a));
    try std.testing.expectEqual(a, vpi_mcd_close(a));
    try std.testing.expect(vpi_mcd_name(a) == null);
    // Writing to a closed channel is an error, and so says EOF.
    try std.testing.expectEqual(EOF, vpi_mcd_printf(a, "x"));

    var got: [16]u8 = undefined;
    const text = try tmp.dir.readFile(io(), "a.log", &got);
    try std.testing.expectEqualStrings("alpha\n", text);
}

test "C conversions: flags, lengths, and the conversions C leaves undefined" {
    var b: [512]u8 = undefined;
    // C11 7.21.6.1: '+' and ' ' on a signed conversion; '0' is ignored when a
    // precision is given.
    try expectFormat("+0| 42|  007|7    ", formatted(&b, "%+d|% d|%05.3d|%-5d", @as(c_int, 0), @as(c_int, 42), @as(c_int, 7), @as(c_int, 7)), &b);
    // A zero at precision 0 is no digits, but keeps its sign; '#' with 'o'
    // still prints the one 0.
    try expectFormat("[][+][0]", formatted(&b, "[%.0d][%+.0d][%#.0o]", @as(c_int, 0), @as(c_int, 0), @as(c_uint, 0)), &b);
    // hh and h convert to char and short first: 300 is 44, 70000 is 4464,
    // 255 as a signed char is -1.
    try expectFormat("44 4464 -1", formatted(&b, "%hhd %hd %hhd", @as(c_int, 300), @as(c_int, 70000), @as(c_int, 255)), &b);
    // A negative '*' width is the '-' flag; a negative '*' precision is none.
    try expectFormat("[ab   ][abc]", formatted(&b, "[%*s][%.*s]", @as(c_int, -5), @as([*:0]const u8, "ab"), @as(c_int, -1), @as([*:0]const u8, "abc")), &b);
    // An unknown conversion goes out as written and takes no argument; so
    // does a spec the format ends inside.
    try expectFormat("%q 5 %", formatted(&b, "%q %d %", @as(c_int, 5)), &b);
    try expectFormat("[  x][y  ]", formatted(&b, "[%3c][%-3c]", @as(c_int, 'x'), @as(c_int, 'y')), &b);
    try expectFormat("-9223372036854775808 8000000000000000", formatted(&b, "%lld %llx", @as(c_longlong, std.math.minInt(i64)), @as(c_ulonglong, 1 << 63)), &b);
}

test "C conversions: reals at the edges" {
    var b: [512]u8 = undefined;
    // Zero in each style; %g strips "0.00000" to "0".
    try expectFormat("0.000000 0.000000e+00 0", formatted(&b, "%f %e %g", @as(f64, 0), @as(f64, 0), @as(f64, 0)), &b);
    // A negative zero keeps its sign; '+' and ' ' on a positive value.
    try expectFormat("-0.0 +1.5 [ 1.5]", formatted(&b, "%.1f %+.1f [% .1f]", @as(f64, -0.0), @as(f64, 1.5), @as(f64, 1.5)), &b);
    // %E and %G upper-case the exponent; '#' keeps %g's trailing zeros.
    try expectFormat("1.000000E-10 1E-10 1.00000", formatted(&b, "%E %G %#g", @as(f64, 1e-10), @as(f64, 1e-10), @as(f64, 1.0)), &b);
    // Precision 0: no point unless '#'.
    try expectFormat("3 3. 1e+04 1.e+04", formatted(&b, "%.0f %#.0f %.0e %#.0e", @as(f64, 2.6), @as(f64, 2.6), @as(f64, 12345), @as(f64, 12345)), &b);
    // '0' pads between the sign and the digits; '-' pads on the right.
    try expectFormat("-00003.142|1.23e+03  |", formatted(&b, "%010.3f|%-10.2e|", @as(f64, -3.14159), @as(f64, 1234.5)), &b);
    // Infinities and NaN: no zero padding, case from the conversion.
    try expectFormat("nan|  INF|-inf  |  inf", formatted(&b, "%f|%5F|%-6f|%05f", std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), std.math.inf(f64)), &b);
}

test "§12.25/IEEE 1364-2005 §27.23: names and flushes of descriptors that are not open" {
    try std.testing.expect(vpi_mcd_name(0) == null);
    try std.testing.expectEqualStrings("stderr", std.mem.span(vpi_mcd_name(2)));
    // Channel 21 is not open; fd 63 is no file $fopen opened.
    try std.testing.expect(vpi_mcd_name(1 << 20) == null);
    try std.testing.expect(vpi_mcd_name(fd_bit | 63) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    // The predefined channels are always open, and unbuffered.
    try std.testing.expectEqual(@as(c_int, 0), vpi_mcd_flush(0x7));
    try std.testing.expectEqual(@as(c_int, 1), vpi_mcd_flush(1 << 20));
    try std.testing.expectEqual(@as(c_int, 1), vpi_mcd_flush(fd_bit));
    try std.testing.expectEqual(@as(c_int, 0), vpi_flush());
    // vpi_mcd_printf writes to no fd, and needs a format.
    try std.testing.expectEqual(EOF, vpi_mcd_printf(fd_bit, "x"));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}

test "C conversions: a precision past INT_MAX is clamped, not trapped" {
    var b: [512]u8 = undefined;
    // %g strips the zeros a huge precision asks for; %f cannot fit them in
    // the buffer, which fails the format (0) rather than the process.
    try expectFormat("1|", formatted(&b, "%.99999999999999999999g|", @as(f64, 1.0)), &b);
    try std.testing.expectEqual(@as(usize, 0), formatted(&b, "%.99999999999999999999f", @as(f64, 1.0)));
    try std.testing.expectEqual(@as(usize, 0), formatted(&b, "%99999999999999999999d", @as(c_int, 1)));
}

test "setLogFile: renaming the log keeps one name, owned once" {
    try setLogFile("a.log");
    try setLogFile("b.log");
    try std.testing.expectEqualStrings("b.log", std.mem.span(vpi_mcd_name(4)));
    gpa.free(log_name.?);
    log_name = null;
}
