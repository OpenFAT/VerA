// §9.5 file descriptor I/O kernels — EMITTED VERBATIM into a device built with
// `--display=emit` that calls the §9.5 family (`kernel_text.file_txt` is
// `@embedFile` of this file) and `@import`ed by codegen.zig's tests. One source,
// so the descriptors the tests check are the descriptors the device opens.
//
// WHERE THIS SITS IN THE CONTRACT, AND WHY IT IS NOT EVERYWHERE. A residual has
// to be a pure function of x or the host's Newton iteration cannot converge —
// opening a file, advancing a read position or appending a line are none of
// those things. So the whole family is sequenced in the ONE per-point phase the
// contract already has for side effects: the optional `display` decl, which
// §9.5.2 makes the natural home ("$fdisplay ... the same as $display", with a
// descriptor prepended) and §9.5.9 makes the correct one ("if a file is being
// written to during an iterative solve, then the file write operations shall not
// be performed unless the iteration is accepted"). `codegen.emitSysCall` renders
// these calls ONLY while emitting that unit; in every other unit the family
// keeps the constant it always had.
//
// That is also what makes a host with no file table CONFORMANT rather than
// stubbed. A device compiled for a solver has no `display` decl, so it never
// reaches this table, so its `$fopen` answers 0 — and §9.5.1 reserves exactly
// that: "if a file cannot be opened ... a zero is returned for the mcd or fd".
// A device that genuinely has no file table genuinely cannot open a file.
//
// SCOPE. §9.5.1 $fopen/$fclose in both descriptor shapes, §9.5.2's five output
// tasks, §9.5.4.1 $fgets, §9.5.4.2 $fscanf, §9.5.5 $ftell/$fseek/$rewind,
// §9.5.6 $fflush, §9.5.7 $ferror, §9.5.8 $feof — and IEEE 1364-2005 §17.2.4.1
// $fgetc and §17.2.4.2 $ungetc, which §9.2 Table 9-2 marks analog-context "No"
// but which the DIGITAL context of a mixed simulation calls on this same table
// (§9.5.1.2, `contract.FileIo`). NOT here, because Table 9-2 marks them "No"
// and no context calls them through the table: the b/h/o radix spellings (a
// formatting question, answered before `zFPut`), $fread, $readmemb/$readmemh
// and $sdf_annotate.

// MEMORY. The table, the remembered write paths and each channel's line grow
// on demand, from `zf_gpa`: `std.heap.page_allocator`, which every target a
// device builds for has (the kernels already need an OS for every call here),
// behind geometric growth, so a run that opens n channels or reads an n-byte
// line asks the OS O(log n) times. Nothing else in a device allocates, and the
// contract has no allocator: these kernels run only in the per-point side
// effect phase of a `--display=emit` device (above), never in `eval`. An
// allocation that fails is §9.5.1's failed open (`$fopen` 0, `$ferror` 12) or,
// for a line or `$fscanf` window that cannot grow, E1011 (`zfOver`). What a
// channel reads stays allocated until the run ends (`zFFreeAll`), because a
// string variable may still view a line after the next read or a `$fclose`.

// `std` is spelled `zfstd` HERE for the reason `str_kernels.zig` spells it
// `zstd`: this text is embedded verbatim into device.zig, which already declares
// `const std` — and a DIFFERENT alias from the string kernels', because a device
// that scans a file carries both blocks in the same file scope.
const zfstd = @import("std");

/// Where the table, the write-path rows and the lines come from. A `var` so a
/// test can run the kernels over a checking or failing allocator.
pub var zf_gpa: zfstd.mem.Allocator = zfstd.heap.page_allocator;

/// One open channel. `pos` is §9.5.5's own quantity — "the offset from the
/// beginning of the file of the current byte of the file fd, which shall be read
/// or written by a subsequent operation" — and it is kept HERE rather than left
/// to the OS file position because every read below is POSITIONAL. That is what
/// makes `$ftell` exact after a `$fgets`: a buffered reader would have consumed
/// ahead of the newline and reported a position no clause allows.
const ZFSlot = struct {
    open: bool = false,
    f: zfstd.Io.File = undefined,
    pos: u64 = 0,
    /// §9.5.8 "EOF has previously been detected reading fd".
    eof: bool = false,
    /// §9.5.7's errno for the most recent operation on THIS descriptor.
    err: u8 = 0,
    can_read: bool = false,
    can_write: bool = false,
    /// Table 9-24 "a"/"a+": every write goes to the end of the file, wherever
    /// a `$fseek` left the position.
    append: bool = false,
    /// The most recent §9.5.4.1/§9.5.4.2 line. `$fgets` returns a COUNT and
    /// writes a string, and `$fscanf` returns a count and writes its items —
    /// neither is expressible as one value, so lowering splits each source call
    /// into the count plus one reader per destination, exactly as `lowerScan`
    /// splits `$sscanf`. The readers are pure over this latch, so the read
    /// happens once however many destinations there are.
    /// §9.5.4.1 puts no length limit on a line ("until a newline character is
    /// read and transferred to str, or an EOF condition is encountered") and
    /// §3.3's `string` is not a fixed-width type, so the line grows to hold
    /// the longest one read (`zfGrow`), and so does a `$fscanf` window that a
    /// scan reads to its end (`zFMore`). Only a line memory cannot hold ends
    /// the run (E1011, `zfOver`); a record is never split.
    line: []u8 = &.{},
    line_len: usize = 0,
    /// IEEE 1364-2005 §17.2.4.1 the characters `$ungetc` pushed back, the
    /// last pushed first. Every read (`zFGetc`, `zFGets`, `zFWindow`) takes
    /// them before the file, which then resumes at `pos + nback` (VD-084).
    // ponytail: a fixed stack; C promises one pushback and this holds 16.
    back: [16]u8 = undefined,
    nback: u8 = 0,

    // One cache line per channel where the OS handle is 8 bytes: `err` is a
    // u8 errno for that reason. The budget excludes the handle, whose size is
    // the OS's (Windows' `Io.File` is wider than a POSIX fd).
    comptime {
        zfstd.debug.assert(@sizeOf(ZFSlot) - @sizeOf(zfstd.Io.File) <= 56);
    }
};

/// §9.5.1: "limiting an implementation to at most 31 files opened for output via
/// multichannel descriptors" — bit 0 is standard output and bit 31 is reserved
/// clear, so 30 is the mcd shape's own ceiling. Rows 0..29 of `zf_slots` are
/// those channels (bit k+1 is row k); a file descriptor is not an mcd and has
/// no such limit, so fd channel c (c >= 3) is row `zf_max + c - 3`, as many as
/// memory holds, up to the 2^31 - 3 numbers bit 31 leaves an fd.
const zf_max = 30;

// ponytail: file scope, one table per device image, for the reason `zSBuf` is
// file scope — a descriptor outlives the expression that produced it. Two
// instances of the same module therefore SHARE the table; per-instance
// channels are the upgrade the day the harness runs more than one instance of
// a model that opens files.
var zf_slots: zfstd.ArrayList(ZFSlot) = .empty;

/// Line buffers a channel grew out of. A string variable may still view one,
/// so they are freed with everything else at the end of the run.
var zf_retired: zfstd.ArrayList([]u8) = .empty;

/// §9.5.1: "Applications can call $ferror to determine the cause of the most
/// recent error" — after a FAILED open there is no descriptor to hang that on,
/// since the fd is 0, so the cause lands here and `$ferror(0, str)` reports it.
var zf_last_err: u8 = 0;

/// §9.5.1.1: "If a file is opened in a write mode in the first analysis and
/// reopened in that write mode in following analysis, then content written from
/// the following analyses shall be appended to the content written during the
/// previous analyses." So a write-mode open truncates only what THIS analysis
/// wrote: each path opened "w"/"w+" remembers the analysis that last opened it
/// and the length the earlier analyses left (`base`). The runner advances
/// `zf_analysis` at the first point of every analysis after the first
/// (`zFNewAnalysis`); a host that never calls it runs one analysis, and then
/// `base` is 0 and "w" is C's truncate, exactly as before.
// ponytail: paths remembered by hash, one row each for the run. Forgetting one
// would truncate it on a later analysis, so a row that cannot be added fails
// the open instead (`zFOpen`: 0, `$ferror` 12).
const ZFWritten = struct { hash: u64, analysis: u32, base: u64 };
var zf_written: zfstd.ArrayList(ZFWritten) = .empty;
var zf_analysis: u32 = 0;

/// §9.5.1.1 a new analysis of the same simulation process begins.
pub fn zFNewAnalysis() void {
    zf_analysis += 1;
}

/// The length a write-mode open of `path` truncates to: 0 the first time, the
/// earlier analyses' content after that (§9.5.1.1). Null when the path is new
/// and no memory is left to remember it.
fn zfWriteBase(io: zfstd.Io, path: []const u8) ?u64 {
    const h = zfstd.hash.Wyhash.hash(0, path);
    for (zf_written.items) |*w| if (w.hash == h) {
        if (w.analysis != zf_analysis) {
            const st = zfstd.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
            w.* = .{ .hash = h, .analysis = zf_analysis, .base = st.size };
        }
        return w.base;
    };
    zf_written.append(zf_gpa, .{ .hash = h, .analysis = zf_analysis, .base = 0 }) catch return null;
    return 0;
}

/// E1011: a line or scan needs more memory than is left. Fatal: the clause
/// has no shorter answer to give.
fn zfOver() noreturn {
    zfstd.debug.print("error[E1011]: a line read from a file does not fit in the memory left; see `vera --explain E1011`\n", .{});
    zfstd.process.exit(1);
}

/// Grows `s.line` to hold at least `want` bytes, doubling, keeping its
/// content. The old buffer is retired, not freed (see MEMORY). E1011 when
/// memory runs out.
fn zfGrow(s: *ZFSlot, want: usize) void {
    if (s.line.len >= want) return;
    var cap: usize = @max(s.line.len, 4096);
    while (cap < want) cap = zfstd.math.mul(usize, cap, 2) catch zfOver();
    zf_retired.ensureUnusedCapacity(zf_gpa, 1) catch zfOver();
    const nb = zf_gpa.alloc(u8, cap) catch zfOver();
    @memcpy(nb[0..s.line_len], s.line[0..s.line_len]);
    if (s.line.len != 0) zf_retired.appendAssumeCapacity(s.line);
    s.line = nb;
}

/// Closes every channel and frees everything the table owns: the run is over.
/// A host that runs one simulation per process may skip it.
pub fn zFFreeAll() void {
    for (zf_slots.items) |*s| {
        if (s.open) s.f.close(zfIo());
        zf_gpa.free(s.line);
    }
    zf_slots.clearAndFree(zf_gpa);
    for (zf_retired.items) |b| zf_gpa.free(b);
    zf_retired.clearAndFree(zf_gpa);
    zf_written.clearAndFree(zf_gpa);
    zf_analysis = 0;
    zf_last_err = 0;
}

fn zfIo() zfstd.Io {
    return zfstd.Io.Threaded.global_single_threaded.io();
}

/// §9.5.1 `$fopen`. `mcd` selects Syntax 9-2's first line (one argument, a
/// multichannel descriptor) over its second (two arguments, a file descriptor).
///
/// The two encodings are the clause's, verbatim: an mcd is "a 32-bit integer in
/// which a single bit is set indicating which file is opened", bit 0 being
/// standard output and bit 31 "reserved and shall always be cleared"; an fd has
/// bit 31 "reserved and shall always be set" with "the remaining bits hold a
/// small number indicating what file is opened", and 0/1/2 are STDIN/STDOUT/
/// STDERR, so a fresh channel starts at 3.
pub fn zFOpen(path: []const u8, ty: []const u8, mcd: bool) i64 {
    // "The $fopen function shall reuse channels that have been closed" — a
    // linear scan for the first free slot is that rule. The mcd rows exist
    // from the first open; an fd row is added when every one is taken.
    if (zf_slots.items.len < zf_max) zf_slots.appendNTimes(zf_gpa, .{}, zf_max - zf_slots.items.len) catch {
        zf_last_err = 12; // ENOMEM
        return 0;
    };
    var k: usize = if (mcd) 0 else zf_max;
    const end = if (mcd) zf_max else zf_slots.items.len;
    while (k < end and zf_slots.items[k].open) k += 1;
    if (k == zf_max and mcd) {
        zf_last_err = 24; // EMFILE: §9.5.1's 30 mcd channels
        return 0;
    }
    if (!mcd and k - zf_max >= (1 << 31) - 3) {
        zf_last_err = 24; // EMFILE: bit 31 leaves an fd 31 bits
        return 0;
    }
    if (k == zf_slots.items.len) zf_slots.ensureUnusedCapacity(zf_gpa, 1) catch {
        zf_last_err = 12; // ENOMEM
        return 0;
    };
    const io = zfIo();
    // §9.5.1 Table 9-24: "b" only distinguishes hosts that translate line
    // endings; nothing here translates. Omitted type defaults to writing.
    const mode: u8 = if (zfstd.mem.findAny(u8, ty, "rwa")) |at| ty[at] else 'w';
    const plus = zfstd.mem.findScalar(u8, ty, '+') != null;
    const cwd: zfstd.Io.Dir = .cwd();
    const f: zfstd.Io.File = switch (mode) {
        // Table 9-24 "r"/"r+": open an EXISTING file. §9.5.1's failure case is
        // exactly this one — "the file does not exist and the type specified is
        // r, rb, r+, r+b, or rb+" — and 0 is what it asks for, not C's -1.
        'r' => cwd.openFile(io, path, .{ .mode = if (plus) .read_write else .read_only }) catch |e| {
            zf_last_err = zfErrno(e);
            return 0;
        },
        'w' => w: {
            // §9.5.1.1: truncate to what the earlier analyses wrote, not to 0.
            const base = zfWriteBase(io, path) orelse {
                zf_last_err = 12; // ENOMEM
                return 0;
            };
            const f = cwd.createFile(io, path, .{ .read = plus, .truncate = base == 0 }) catch |e| {
                zf_last_err = zfErrno(e);
                return 0;
            };
            if (base != 0) f.setLength(io, base) catch |e| {
                f.close(io);
                zf_last_err = zfErrno(e);
                return 0;
            };
            break :w f;
        },
        else => cwd.createFile(io, path, .{ .read = plus, .truncate = false }) catch |e| {
            zf_last_err = zfErrno(e);
            return 0;
        },
    };
    if (k == zf_slots.items.len) zf_slots.appendAssumeCapacity(.{});
    // A reused row keeps its line buffer: a string may still view it.
    const line = zf_slots.items[k].line;
    zf_slots.items[k] = .{
        .open = true,
        .f = f,
        .can_read = mode == 'r' or plus,
        .can_write = mode != 'r' or plus,
        .append = mode == 'a',
        .line = line,
    };
    // "at end of file" is a POSITION, and the position is ours to keep. A "w"
    // open's end is 0, or §9.5.1.1's earlier-analysis content (`zfWriteBase`).
    if (mode != 'r') zf_slots.items[k].pos = f.length(io) catch 0;
    zf_last_err = 0;
    return if (mcd)
        @as(i64, 1) << @intCast(k + 1) // bit 0 is standard output
    else
        (@as(i64, 1) << 31) | @as(i64, @intCast(k - zf_max + 3)); // 0..2 are the std streams
}

/// A nonzero errno for §9.5.7. The numeric value is deliberately the C one where
/// there is an obvious match and deliberately NOT asserted by any fixture:
/// §9.5.7 says only "an error code is returned" and fixes no value.
fn zfErrno(e: anyerror) u8 {
    return switch (e) {
        error.FileNotFound => 2, // ENOENT
        error.AccessDenied, error.PermissionDenied => 13, // EACCES
        error.IsDir => 21, // EISDIR
        error.NoSpaceLeft => 28, // ENOSPC
        else => 5, // EIO — "should any error be detected"
    };
}

/// The slot a descriptor names, or null when it names none — which is every
/// §9.5 call on the 0 a failed open returned, and on one of the three pre-opened
/// standard channels this table does not hold.
fn zfSlot(d: i64) ?usize {
    if (d == 0) return null;
    if (d & (@as(i64, 1) << 31) != 0) { // an fd: bit 31 set
        const ch = d & 0x7fff_ffff;
        if (ch < 3) return null; // STDIN/STDOUT/STDERR
        const k: usize = zf_max + @as(usize, @intCast(ch - 3));
        return if (k < zf_slots.items.len and zf_slots.items[k].open) k else null;
    }
    // An mcd: the LOWEST set bit above bit 0 names the channel a single-channel
    // operation acts on. §9.5.1 lets several bits be OR'd together, which is a
    // WRITE-side rule (`zFPut` honours it); everything else here is per-channel.
    const bits = d & 0x7fff_fffe; // bits 1..30: bit b is row b - 1
    if (bits == 0) return null;
    const k: usize = @ctz(bits) - 1;
    return if (k < zf_slots.items.len and zf_slots.items[k].open) k else null;
}

/// §9.5.2's five output tasks, after the §9.4.3 formatter has produced the text.
/// Returns the byte count, which nothing in §9.5 asks for — the tasks are void —
/// but which gives the call a value the emitter can sequence.
///
/// §9.5.1: "file descriptors cannot be combined via bitwise OR" but mcds can, so
/// an mcd write goes to EVERY channel its bits name, and bit 0 is the transcript.
pub fn zFPut(d: i64, text: []const u8) i64 {
    if (d == 0) {
        zf_last_err = 9; // EBADF
        return 0;
    }
    if (d & (@as(i64, 1) << 31) != 0) return zfPut1(zfSlot(d) orelse {
        // An fd naming no slot: bit 31 set with a small number of 1 or 2 is
        // §9.5.1's pre-opened STDOUT/STDERR, which is the transcript.
        if ((d & 0x7fff_ffff) == 1 or (d & 0x7fff_ffff) == 2) {
            zfstd.debug.print("{s}", .{text});
            return @intCast(text.len);
        }
        zf_last_err = 9;
        return 0;
    }, text);
    var n: i64 = 0;
    if (d & 1 != 0) { // bit 0 "always refers to the standard output"
        zfstd.debug.print("{s}", .{text});
        n = @intCast(text.len);
    }
    var b: u6 = 1;
    while (b <= zf_max) : (b += 1) {
        if (d & (@as(i64, 1) << b) == 0) continue;
        if (b > zf_slots.items.len or !zf_slots.items[b - 1].open) continue;
        n = zfPut1(b - 1, text);
    }
    return n;
}

fn zfPut1(k: usize, text: []const u8) i64 {
    const s = &zf_slots.items[k];
    if (!s.can_write) {
        s.err = 9; // EBADF — opened "r"
        zf_last_err = 9;
        return 0;
    }
    if (s.append) s.pos = s.f.length(zfIo()) catch s.pos;
    s.f.writePositionalAll(zfIo(), text, s.pos) catch |e| {
        s.err = zfErrno(e);
        zf_last_err = s.err;
        return 0;
    };
    s.pos += text.len;
    s.err = 0;
    zf_last_err = 0;
    return @intCast(text.len);
}

/// §9.5.4.1 `code = $fgets( str, fd )`: "reads characters from the file
/// specified by fd into the string variable, str until a newline character is
/// read AND TRANSFERRED to str, or an EOF condition is encountered. If an error
/// occurs reading from the file, then code is set to zero. Otherwise, the number
/// of characters read is returned in code."
///
/// So the newline is INCLUDED in both the string and the count — C's `fgets`
/// keeps it too, but a port that stops before the delimiter returns one less.
//
// ponytail: one positional read per byte, because the count and `$ftell`'s
// answer are both exact byte offsets and a chunked read would consume past the
// newline. A fixture line is four bytes; a model reading a large file wants a
// buffer that tracks `pos` itself, which is the upgrade.
pub fn zFGets(d: i64) i64 {
    const k = zfSlot(d) orelse {
        zf_last_err = 9;
        return 0;
    };
    const s = &zf_slots.items[k];
    if (!s.can_read) {
        s.err = 9;
        zf_last_err = 9;
        return 0;
    }
    const io = zfIo();
    var n: usize = 0;
    var b: [1]u8 = undefined;
    s.line_len = 0;
    while (true) {
        if (n == s.line.len) zfGrow(s, n + 1);
        // §17.2.4.1's pushback first; the file is read only once it is
        // empty, so `pos + n` is then the file's position.
        if (s.nback != 0) {
            s.nback -= 1;
            b[0] = s.back[s.nback];
        } else {
            const got = s.f.readPositionalAll(io, &b, s.pos + n) catch |e| {
                s.err = zfErrno(e);
                zf_last_err = s.err;
                s.line_len = n;
                s.pos += n;
                return 0;
            };
            if (got == 0) {
                s.eof = true;
                break;
            }
        }
        s.line[n] = b[0];
        n += 1;
        s.line_len = n;
        if (b[0] == '\n') break;
    }
    s.pos += n;
    s.line_len = n;
    s.err = 0;
    zf_last_err = 0;
    return @intCast(n);
}

/// The line `$fgets` or `$fscanf` last read from this descriptor.
///
/// `n` is the COUNT the call that performed the read returned. It is an operand
/// for one structural reason — passing it makes the reader data-dependent on the
/// read, so the emitter cannot order the pair the wrong way round — and it is
/// then READ, because §9.5.4.1 sets code to zero exactly when nothing was
/// transferred into the string.
pub fn zFLine(n: i64, d: i64) []const u8 {
    if (n <= 0) return "";
    const k = zfSlot(d) orelse return "";
    return zf_slots.items[k].line[0..zf_slots.items[k].line_len];
}

/// The bytes call site `site`'s `$fgets`/`$fscanf` read, as of its own
/// statement. A reader is a pure value that codegen may place at its first
/// use, which can come after a `$fclose` (no slot: `zFLine` reads "") or a
/// second read of the same descriptor (the channel's line moved on). So the
/// count copies the line here when it runs (`zFLatch`), and the readers take
/// this copy (`zFLineAt`).
fn ZfLatch(comptime site: usize) type {
    return struct {
        const n = site;
        var text: []u8 = &.{};
    };
}

/// Performs the count `n` of call site `site` on descriptor `d`: copies the
/// line it left on the channel into the site's latch and returns `n`. A string
/// variable may still view an earlier copy, so every copy is owned by
/// `zf_retired` from birth and freed with it (`zFFreeAll`). An allocation that
/// fails is E1011.
// ponytail: one copy per performed read, kept until the run ends; reuse the
// buffer once no string can still view it if a run reads millions of lines.
pub fn zFLatch(comptime site: usize, n: i64, d: i64) i64 {
    const L = ZfLatch(site);
    const k = zfSlot(d) orelse {
        L.text = &.{};
        return n;
    };
    const s = &zf_slots.items[k];
    zf_retired.ensureUnusedCapacity(zf_gpa, 1) catch zfOver();
    const copy = zf_gpa.dupe(u8, s.line[0..s.line_len]) catch zfOver();
    zf_retired.appendAssumeCapacity(copy);
    L.text = copy;
    return n;
}

/// `zFLine` over call site `site`'s latch: the line that site's read left,
/// whatever the descriptor has done since. Empty when the count `n` says
/// nothing was transferred (§9.5.4.1).
pub fn zFLineAt(comptime site: usize, n: i64) []const u8 {
    if (n <= 0) return "";
    return ZfLatch(site).text;
}

/// §9.5.4.2's INPUT: the unread remainder of the file, up to one buffer, read
/// WITHOUT moving the position. The scanner itself is not duplicated here —
/// `$fscanf` "reads from the file specified by fd" what `$sscanf` reads from a
/// string, so it is the same formatter and codegen composes the two kernels
/// rather than this file importing one into the other's embedded text: it
/// scans this window, then hands what matched to `zFTake`.
///
/// A WINDOW AND NOT A LINE. §9.5.4.2 never mentions lines. Its control-string
/// white space "causes input to be read up to the next nonwhite space
/// character" — newlines included — so one `$fscanf` may satisfy directives
/// from two lines, and two `$fscanf`s may take successive fields off one line
/// ("the offending input character is left unread in the input stream ...
/// trailing white space (including newline characters) is left unread unless
/// matched by a directive"). A reader that consumed a line per call could
/// express neither, and silently dropped every field after the first.
///
/// The empty slice is §9.5.4.2's EOF case by construction: `zScan` on no input
/// returns -1 when nothing was tried, which is "if the input ends before the
/// first matching failure or conversion, EOF is returned".
//
// The window is the channel's line buffer; a scan that reads to the end of a
// full one asks for a wider window (`zFMore`) and runs again.
pub fn zFWindow(d: i64) []const u8 {
    const k = zfSlot(d) orelse {
        zf_last_err = 9;
        return "";
    };
    const s = &zf_slots.items[k];
    if (!s.can_read) {
        s.err = 9;
        zf_last_err = 9;
        return "";
    }
    // §17.2.4.1's pushback leads the window, the last pushed first.
    s.line_len = 0;
    zfGrow(s, 4096);
    const m: usize = s.nback;
    for (0..m) |i| s.line[i] = s.back[m - 1 - i];
    s.line_len = m + (s.f.readPositionalAll(zfIo(), s.line[m..], s.pos + m) catch |e| {
        s.err = zfErrno(e);
        zf_last_err = s.err;
        s.line_len = 0;
        return "";
    });
    s.err = 0;
    zf_last_err = 0;
    return s.line[0..s.line_len];
}

/// §9.5.4.2's CONSUMPTION: advance the descriptor by exactly the bytes the
/// scan matched, and by nothing else. `used` is `ZScan.used`; `n` is the
/// scan's own return, passed through so the emitter can compose the two calls
/// into one expression.
///
/// §9.5.8's flag is set HERE and not in `zFWindow`, because "EOF has
/// previously been detected reading fd" is a property of the scan: a short
/// window means only that the file ends somewhere ahead, while a scan that
/// answers EOF is the detection itself. A scan that stopped on a newline, or
/// on a conflicting character, has reached the end of nothing.
pub fn zFTake(d: i64, n: i64, used: i64) i64 {
    const k = zfSlot(d) orelse return n;
    const s = &zf_slots.items[k];
    if (used > 0) {
        s.pos += @intCast(used);
        s.nback -= @intCast(@min(s.nback, used));
    }
    if (n < 0) s.eof = true;
    return n;
}

/// Whether the scan over `zFWindow`'s window must run again over a wider one:
/// it read `used` bytes, to the end of a FULL window, so it may have needed
/// the bytes after it and its answer is not yet the file's. The window is
/// doubled first (`zfGrow`; E1011 when memory runs out).
pub fn zFMore(d: i64, used: usize) bool {
    const k = zfSlot(d) orelse return false;
    const s = &zf_slots.items[k];
    if (s.line_len < s.line.len or used < s.line_len) return false;
    zfGrow(s, s.line.len + 1);
    return true;
}

/// §9.5.5 `pos = $ftell( fd )` — "the offset from the beginning of the file of
/// the current byte". "If an error occurs, EOF is returned"; EOF's value is
/// IEEE 1364's, i.e. -1.
pub fn zFTell(d: i64) i64 {
    const k = zfSlot(d) orelse return -1;
    return @intCast(zf_slots.items[k].pos);
}

/// §9.5.5 `code = $fseek( fd, offset, operation )` — "0 sets position equal to
/// offset bytes, 1 sets position to current location plus offset, 2 sets
/// position to EOF plus offset" — and the return is a STATUS, not a position:
/// "if an error occurs repositioning the file, then code is set to -1.
/// Otherwise, code is set to 0."
///
/// `$rewind` is the same kernel: "$rewind is equivalent to $fseek (fd,0,0)".
pub fn zFSeek(d: i64, off: i64, op: i64) i64 {
    const k = zfSlot(d) orelse return -1;
    const s = &zf_slots.items[k];
    const base: i64 = switch (op) {
        1 => @intCast(s.pos),
        2 => @intCast(s.f.length(zfIo()) catch |e| {
            s.err = zfErrno(e);
            zf_last_err = s.err;
            return -1;
        }),
        else => 0,
    };
    // An offset whose sum leaves i64 names no position either: EINVAL, like
    // one before the start, rather than a trap on the overflow.
    const np = zfstd.math.add(i64, base, off) catch -1;
    if (np < 0) {
        s.err = 22; // EINVAL
        zf_last_err = 22;
        return -1;
    }
    s.pos = @intCast(np);
    // §9.5.5: a reposition clears the end-of-file condition, which is why the
    // clause bothers to say $fseek and $rewind "undo the effect of any $ungetc".
    s.eof = false;
    s.nback = 0;
    s.err = 0;
    zf_last_err = 0;
    return 0;
}

/// IEEE 1364-2005 §17.2.4.1 `c = $fgetc( fd )`: one byte, or EOF (-1) when
/// none is left, which is also what sets §17.2.8's end-of-file indicator.
pub fn zFGetc(d: i64) i64 {
    const k = zfSlot(d) orelse return -1;
    const s = &zf_slots.items[k];
    if (s.nback != 0) {
        s.nback -= 1;
        s.pos += 1;
        return s.back[s.nback];
    }
    var b: [1]u8 = undefined;
    const got = if (s.can_read) s.f.readPositionalAll(zfIo(), &b, s.pos) catch 0 else 0;
    if (got == 0) {
        s.eof = true;
        return -1;
    }
    s.pos += 1;
    return b[0];
}

/// IEEE 1364-2005 §17.2.4.1 `code = $ungetc( c, fd )`: "inserts the character
/// specified by c into the buffer specified by file descriptor fd", so the
/// next `$fgetc` returns it, without changing the file; 0, or EOF when it
/// cannot. It moves the position back one, as C's does, and so needs one.
pub fn zFUngetc(c: i64, d: i64) i64 {
    const k = zfSlot(d) orelse return -1;
    const s = &zf_slots.items[k];
    if (s.pos == 0 or s.nback == s.back.len) return -1;
    s.back[s.nback] = @truncate(@as(u64, @bitCast(c)));
    s.nback += 1;
    s.pos -= 1;
    s.eof = false;
    return 0;
}

/// §9.5.8 `code = $feof( fd )` — "returns a nonzero value when EOF has
/// previously been detected reading fd; returns zero otherwise."
pub fn zFEof(d: i64) i64 {
    const k = zfSlot(d) orelse return 0;
    return @intFromBool(zf_slots.items[k].eof);
}

/// §9.5.7 `errno = $ferror( fd, str )` — "the integral value of the error code
/// is returned in errno. If the most recent operation did not result in an
/// error, then the value returned shall be zero."
///
/// A descriptor of 0 is the one §9.5.1 sends here: "if a file cannot be opened
/// ... a zero is returned for the mcd or fd. Applications can call $ferror to
/// determine the cause of the most recent error."
pub fn zFError(d: i64) i64 {
    const k = zfSlot(d) orelse return zf_last_err;
    return zf_slots.items[k].err;
}

/// The description half. "A string description of type of error encountered by
/// the most recent file I/O operation is written into str"; and, when there was
/// none, "the string variable str shall be EMPTY" — which is what `e == 0` is.
pub fn zFErrorStr(e: i64, _: i64) []const u8 {
    return switch (e) {
        0 => "",
        2 => "no such file or directory",
        9 => "bad file descriptor",
        12 => "out of memory",
        13 => "permission denied",
        21 => "is a directory",
        22 => "invalid argument",
        24 => "too many open files",
        28 => "no space left on device",
        else => "i/o error",
    };
}

/// §9.5.6 `$fflush( fd )` — "writes any buffered output to the file specified by
/// fd". Every write above is a positional write straight to the descriptor, so
/// there is never buffered output to flush and this is a no-op with nothing
/// hidden behind it. `$fflush` with no argument "writes any buffered output to
/// all open files", which is the same nothing.
pub fn zFFlush(_: i64) i64 {
    return 0;
}

/// §9.5.1 `$fclose( mcd )` / `$fclose( fd )`. Closing frees the channel for
/// reuse, which is the sentence `zFOpen`'s free-slot scan implements.
pub fn zFClose(d: i64) i64 {
    if (d == 0) return 0;
    if (d & (@as(i64, 1) << 31) != 0) {
        zfClose1(zfSlot(d) orelse return 0);
        return 0;
    }
    var b: u6 = 1;
    while (b <= zf_max) : (b += 1) {
        if (d & (@as(i64, 1) << b) == 0) continue;
        if (b <= zf_slots.items.len and zf_slots.items[b - 1].open) zfClose1(b - 1);
    }
    return 0;
}

fn zfClose1(k: usize) void {
    zf_slots.items[k].f.close(zfIo());
    zf_slots.items[k].open = false;
}

/// §9.5 one call site's RESULT, carried out of the display unit. The call is
/// performed only there (§9.5.9), so every other unit — the core the residual
/// and `updateState` read — answers with the value this site last produced:
/// `fd = $fopen(..)` under `@(initial_step)` holds the descriptor the open
/// returned, not a 0 that `$ftell(fd)` then reads as "no such file". Inside one
/// point the core sees the PREVIOUS point's result until the display unit runs;
/// `updateState` runs after it and sees this point's.
///
/// ponytail: one latch per call site, file scope, on `zSBuf`'s terms — per-
/// instance latches are the upgrade the day a host runs two instances of a
/// model that opens files. Integer results only (`callTy == .int`), which is
/// every descriptor, count, position and status §9.5 returns.
pub fn zFRes(comptime site: usize) *i64 {
    const ZfRes = struct {
        const n = site;
        var v: i64 = 0;
    };
    return &ZfRes.v;
}

/// The display unit's half of `zFRes`: perform, latch, answer.
pub fn zFKeep(comptime site: usize, v: i64) i64 {
    zFRes(site).* = v;
    return v;
}
