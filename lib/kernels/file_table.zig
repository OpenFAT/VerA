//! The §9.5 descriptor table: a descriptor and an operation's arguments in,
//! the operation's §9.5 result (a descriptor, a count, a position, a status)
//! out, with the file system changed as the clause says. `ZfTable` holds the
//! channels and their read lines; every method that allocates takes the
//! caller's `gpa` and every one that touches a file the caller's `io`.
//! Device text (`text.file`, with `file_kernels.zig`, which holds the
//! device's one table and the `zF*` ABI over it).
//! Cites: VAMS §9.5.1 (Table 9-24), §9.5.1.1, §9.5.2, §9.5.4.1, §9.5.4.2,
//! §9.5.5-§9.5.8; IEEE 1364-2005 §17.2.4.1, §17.2.8;
//! docs/specification/Vague_Decisions.md VD-084.
//!
//! Memory: the rows, the remembered write paths and each channel's line
//! grow geometrically from `gpa`, so n channels or an n-byte line ask
//! O(log n) times. What a channel reads stays allocated until `freeAll`: a
//! string variable may still view a line after the next read or a `$fclose`.
//! A failed allocation is §9.5.1's failed open (`$fopen` 0, `$ferror` 12)
//! or, for a line that cannot grow, E1011.
//!
//! Contents:
//! - `pub const ZfTable = struct` (`mcd_max`, `open`, `put`, `gets`, `line`, `latch`, `window`, `take`, `more`, `tell`, `seek`, `getc`, `ungetc`, `eof`, `err`, `close`, `newAnalysis`, `freeAll`)

const zfstd = @import("std");

// ---- device text ----

/// The §9.5 descriptor table. Rows 0..29 are the multichannel descriptors
/// (bit k+1 of an mcd is row k: §9.5.1 limits mcds to "at most 31 files
/// opened for output", bit 0 being standard output and bit 31 reserved), and
/// fd channel c (c >= 3; 0..2 are the standard streams) is row `30 + c - 3`,
/// as many as memory holds, up to the 2^31 - 3 numbers bit 31 leaves an fd.
/// Each method that allocates takes `gpa` and frees nothing it returned
/// before `freeAll`; each that touches a file takes `io`. Every field is
/// the table's; callers use the methods.
pub const ZfTable = struct {
    /// One row per channel ever opened, reused after a close ("the $fopen
    /// function shall reuse channels that have been closed").
    slots: zfstd.ArrayList(ZfSlot) = .empty,
    /// Line buffers a channel grew out of, and every latched copy: a string
    /// variable may still view one, so they live until `freeAll`.
    retired: zfstd.ArrayList([]u8) = .empty,
    /// §9.5.1.1's write-mode paths, by hash, one row each for the run.
    written: zfstd.ArrayList(ZfWritten) = .empty,
    /// §9.5.1.1 the current analysis of the simulation process.
    analysis: u32 = 0,
    /// §9.5.1 the cause of the most recent error with no descriptor to hang
    /// it on (a failed open returns fd 0): `$ferror(0, str)` reports it.
    last_err: u8 = 0,

    /// The mcd channels' ceiling: §9.5.1's 31 output bits less standard
    /// output (bit 0); bit 31 is reserved clear.
    pub const mcd_max = 30;

    /// §9.5.1 `$fopen`: returns an mcd ("a 32-bit integer in which a single
    /// bit is set indicating which file is opened", bit 0 standard output)
    /// when `mcd`, else an fd (bit 31 "reserved and shall always be set",
    /// "the remaining bits hold a small number", 3 the first). 0 on failure,
    /// the cause in `err(0)`: a missing file under an `r` type ("the file
    /// does not exist and the type specified is r, rb, r+, r+b, or rb+"),
    /// every mcd channel taken (EMFILE), or no memory (ENOMEM). An omitted
    /// type writes; `b` changes nothing (nothing here translates line
    /// endings). A write-mode open truncates only what this analysis wrote
    /// (§9.5.1.1, `writeBase`). Invalidates every line view if the table
    /// grows.
    pub fn open(self: *ZfTable, gpa: zfstd.mem.Allocator, io: zfstd.Io, path: []const u8, ty: []const u8, mcd: bool) i64 {
        zfstd.debug.assert(self.slots.items.len == 0 or self.slots.items.len >= mcd_max);
        if (self.slots.items.len < mcd_max) self.slots.appendNTimes(gpa, .{}, mcd_max - self.slots.items.len) catch {
            self.last_err = 12; // ENOMEM
            return 0;
        };
        // The first free row of the descriptor's kind.
        var k: usize = if (mcd) 0 else mcd_max;
        const end = if (mcd) mcd_max else self.slots.items.len;
        while (k < end and self.slots.items[k].open) k += 1;
        if (k == mcd_max and mcd) {
            self.last_err = 24; // EMFILE: §9.5.1's 30 mcd channels
            return 0;
        }
        if (!mcd and k - mcd_max >= (1 << 31) - 3) {
            self.last_err = 24; // EMFILE: bit 31 leaves an fd 31 bits
            return 0;
        }
        if (k == self.slots.items.len) self.slots.ensureUnusedCapacity(gpa, 1) catch {
            self.last_err = 12;
            return 0;
        };
        const mode: u8 = if (zfstd.mem.findAny(u8, ty, "rwa")) |at| ty[at] else 'w';
        const plus = zfstd.mem.findScalar(u8, ty, '+') != null;
        const f = self.openFile(gpa, io, path, mode, plus) orelse return 0;
        if (k == self.slots.items.len) self.slots.appendAssumeCapacity(.{});
        // A reused row keeps its line buffer: a string may still view it.
        const line_buf = self.slots.items[k].line;
        self.slots.items[k] = .{
            .open = true,
            .f = f,
            .can_read = mode == 'r' or plus,
            .can_write = mode != 'r' or plus,
            .append = mode == 'a',
            .line = line_buf,
        };
        // "At end of file" is a position, and the position is ours: a "w"
        // open's end is 0 or §9.5.1.1's earlier-analysis content.
        if (mode != 'r') self.slots.items[k].pos = f.length(io) catch 0;
        self.last_err = 0;
        const d: i64 = if (mcd)
            @as(i64, 1) << @intCast(k + 1)
        else
            (@as(i64, 1) << 31) | @as(i64, @intCast(k - mcd_max + 3));
        zfstd.debug.assert(self.slot(d) == k); // pair of `slot`'s decode
        return d;
    }

    /// §9.5.2's five output tasks, after the §9.4.3 formatter produced
    /// `text`: returns the byte count (the tasks are void; the count gives the
    /// emitter a value to sequence). "File descriptors cannot be combined via
    /// bitwise OR" but mcds can, so an mcd write goes to every channel its
    /// bits name, and bit 0, like fd 1 or 2, is the transcript (stderr).
    pub fn put(self: *ZfTable, io: zfstd.Io, d: i64, text: []const u8) i64 {
        if (d == 0) {
            self.last_err = 9; // EBADF
            return 0;
        }
        if (d & zf_fd_bit != 0) {
            if (self.slot(d)) |k| return self.put1(io, k, text);
            // An fd naming no row: 1 or 2 is §9.5.1's pre-opened STDOUT/STDERR.
            if ((d & 0x7fff_ffff) == 1 or (d & 0x7fff_ffff) == 2) {
                zfstd.debug.print("{s}", .{text});
                return @intCast(text.len);
            }
            self.last_err = 9;
            return 0;
        }
        var n: i64 = 0;
        if (d & 1 != 0) { // bit 0 "always refers to the standard output"
            zfstd.debug.print("{s}", .{text});
            n = @intCast(text.len);
        }
        var b: u6 = 1;
        while (b <= mcd_max) : (b += 1) {
            if (d & (@as(i64, 1) << b) == 0) continue;
            if (b > self.slots.items.len or !self.slots.items[b - 1].open) continue;
            n = self.put1(io, b - 1, text);
        }
        return n;
    }

    /// §9.5.4.1 `code = $fgets(str, fd)`: "reads characters from the file
    /// specified by fd into the string variable, str until a newline
    /// character is read and transferred to str, or an EOF condition is
    /// encountered. If an error occurs reading from the file, then code is
    /// set to zero. Otherwise, the number of characters read is returned".
    /// The newline is included in both the line (`line`) and the count. A
    /// line memory cannot hold is E1011: a record is never split.
    /// Invalidates the descriptor's previous `line` view if the line grows.
    // ponytail: one positional read per byte, because the count and
    // `$ftell` are exact byte offsets and a chunked read would consume past
    // the newline; a model reading a large file wants a buffer that tracks
    // `pos` itself.
    pub fn gets(self: *ZfTable, gpa: zfstd.mem.Allocator, io: zfstd.Io, d: i64) i64 {
        const k = self.slot(d) orelse {
            self.last_err = 9;
            return 0;
        };
        const s = &self.slots.items[k];
        if (!s.can_read) {
            s.err = 9;
            self.last_err = 9;
            return 0;
        }
        var n: usize = 0;
        var b: [1]u8 = undefined;
        s.line_len = 0;
        while (true) {
            if (n == s.line.len) self.grow(gpa, k, n + 1);
            // §17.2.4.1's pushback first; the file is read only once it is
            // empty, so `pos + n` is then the file's position.
            if (s.nback != 0) {
                s.nback -= 1;
                b[0] = s.back[s.nback];
            } else {
                const got = s.f.readPositionalAll(io, &b, s.pos + n) catch |e| {
                    s.err = zfErrno(e);
                    self.last_err = s.err;
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
        s.err = 0;
        self.last_err = 0;
        zfstd.debug.assert(s.line_len == n);
        return @intCast(n);
    }

    /// Returns the line `gets` or `window` last left on descriptor `d`, or ""
    /// when `n`, the count the reading call returned, says nothing was
    /// transferred (§9.5.4.1 sets code to zero exactly then). `n` is an
    /// operand so the reader depends on the read and the emitter cannot
    /// order the pair the wrong way round. Valid until the next read of `d`.
    pub fn line(self: *const ZfTable, n: i64, d: i64) []const u8 {
        if (n <= 0) return "";
        const k = self.slot(d) orelse return "";
        const s = &self.slots.items[k];
        zfstd.debug.assert(s.line_len <= s.line.len);
        return s.line[0..s.line_len];
    }

    /// Returns a copy of the line descriptor `d` holds, owned by the table
    /// until `freeAll` (a string variable may still view an earlier copy),
    /// or "" when `d` names no channel. E1011 when memory runs out.
    pub fn latch(self: *ZfTable, gpa: zfstd.mem.Allocator, d: i64) []const u8 {
        const k = self.slot(d) orelse return &.{};
        const s = &self.slots.items[k];
        self.retired.ensureUnusedCapacity(gpa, 1) catch zfOver();
        const copy = gpa.dupe(u8, s.line[0..s.line_len]) catch zfOver();
        self.retired.appendAssumeCapacity(copy);
        zfstd.debug.assert(copy.len == s.line_len);
        return copy;
    }

    /// §9.5.4.2's input: the unread remainder of the file, up to one buffer,
    /// read without moving the position; §17.2.4.1's pushback leads it, the
    /// last pushed first. `$fscanf` "reads from the file specified by fd"
    /// what `$sscanf` reads from a string, so codegen scans this window with
    /// `zScan` and hands what matched to `take`. A window and not a line:
    /// control-string white space "causes input to be read up to the next
    /// nonwhite space character", newlines included, so one `$fscanf` may
    /// span two lines and two may share one. The empty window is §9.5.4.2's
    /// EOF case by construction. Invalidates the previous `line` view.
    pub fn window(self: *ZfTable, gpa: zfstd.mem.Allocator, io: zfstd.Io, d: i64) []const u8 {
        const k = self.slot(d) orelse {
            self.last_err = 9;
            return "";
        };
        const s = &self.slots.items[k];
        if (!s.can_read) {
            s.err = 9;
            self.last_err = 9;
            return "";
        }
        s.line_len = 0;
        self.grow(gpa, k, 4096);
        const m: usize = s.nback;
        for (0..m) |i| s.line[i] = s.back[m - 1 - i];
        s.line_len = m + (s.f.readPositionalAll(io, s.line[m..], s.pos + m) catch |e| {
            s.err = zfErrno(e);
            self.last_err = s.err;
            s.line_len = 0;
            return "";
        });
        s.err = 0;
        self.last_err = 0;
        zfstd.debug.assert(s.line_len <= s.line.len);
        return s.line[0..s.line_len];
    }

    /// §9.5.4.2's consumption: advances descriptor `d` by exactly the `used`
    /// bytes the scan matched (`ZScan.used`) and returns the scan's count
    /// `n`, passed through so the emitter composes the two calls. §9.5.8's
    /// flag is set here, not in `window`: "EOF has previously been detected
    /// reading fd" is a property of the scan, and a short window only means
    /// the file ends somewhere ahead.
    pub fn take(self: *ZfTable, d: i64, n: i64, used: i64) i64 {
        zfstd.debug.assert(n >= -1); // a scan's count, or EOF
        zfstd.debug.assert(used >= 0);
        const k = self.slot(d) orelse return n;
        const s = &self.slots.items[k];
        if (used > 0) {
            s.pos += @intCast(used);
            s.nback -= @intCast(@min(s.nback, used));
        }
        if (n < 0) s.eof = true;
        return n;
    }

    /// Returns whether a scan that read `used` bytes of `window`'s window
    /// must run again over a wider one: it read to the end of a full window,
    /// so it may have needed the bytes after it. Doubles the window first
    /// (E1011 when memory runs out).
    pub fn more(self: *ZfTable, gpa: zfstd.mem.Allocator, d: i64, used: usize) bool {
        const k = self.slot(d) orelse return false;
        const s = &self.slots.items[k];
        if (s.line_len < s.line.len or used < s.line_len) return false;
        self.grow(gpa, k, s.line.len + 1);
        zfstd.debug.assert(s.line.len > s.line_len);
        return true;
    }

    /// §9.5.5 `pos = $ftell(fd)`: "the offset from the beginning of the file
    /// of the current byte". "If an error occurs, EOF is returned": -1.
    pub fn tell(self: *const ZfTable, d: i64) i64 {
        const k = self.slot(d) orelse return -1;
        zfstd.debug.assert(self.slots.items[k].open);
        return @intCast(self.slots.items[k].pos);
    }

    /// §9.5.5 `code = $fseek(fd, offset, operation)`: "0 sets position equal
    /// to offset bytes, 1 sets position to current location plus offset, 2
    /// sets position to EOF plus offset", returning a status: "if an error
    /// occurs repositioning the file, then code is set to -1. Otherwise, code
    /// is set to 0". A position before the start, or past i64, is EINVAL.
    /// `$rewind` is `seek(fd, 0, 0)`. Clears the end-of-file condition and
    /// undoes every `$ungetc`.
    pub fn seek(self: *ZfTable, io: zfstd.Io, d: i64, off: i64, op: i64) i64 {
        const k = self.slot(d) orelse return -1;
        const s = &self.slots.items[k];
        const base: i64 = switch (op) {
            1 => @intCast(s.pos),
            2 => @intCast(s.f.length(io) catch |e| {
                s.err = zfErrno(e);
                self.last_err = s.err;
                return -1;
            }),
            else => 0,
        };
        const np = zfstd.math.add(i64, base, off) catch -1;
        if (np < 0) {
            s.err = 22; // EINVAL
            self.last_err = 22;
            return -1;
        }
        s.pos = @intCast(np);
        s.eof = false;
        s.nback = 0;
        s.err = 0;
        self.last_err = 0;
        return 0;
    }

    /// IEEE 1364-2005 §17.2.4.1 `c = $fgetc(fd)`: one byte, or EOF (-1) when
    /// none is left, which also sets §17.2.8's end-of-file indicator.
    pub fn getc(self: *ZfTable, io: zfstd.Io, d: i64) i64 {
        const k = self.slot(d) orelse return -1;
        const s = &self.slots.items[k];
        if (s.nback != 0) {
            s.nback -= 1;
            s.pos += 1;
            return s.back[s.nback];
        }
        var b: [1]u8 = undefined;
        const got = if (s.can_read) s.f.readPositionalAll(io, &b, s.pos) catch 0 else 0;
        if (got == 0) {
            s.eof = true;
            return -1;
        }
        s.pos += 1;
        zfstd.debug.assert(s.nback == 0);
        return b[0];
    }

    /// IEEE 1364-2005 §17.2.4.1 `code = $ungetc(c, fd)`: "inserts the
    /// character specified by c into the buffer specified by file descriptor
    /// fd", so the next read returns it, without changing the file. Moves the
    /// position back one, as C's does, so it needs one; 0, or EOF (-1) at
    /// position 0 or with the pushback full.
    // ponytail: a fixed 16-byte stack; C promises one pushback.
    pub fn ungetc(self: *ZfTable, c: i64, d: i64) i64 {
        const k = self.slot(d) orelse return -1;
        const s = &self.slots.items[k];
        if (s.pos == 0 or s.nback == s.back.len) return -1;
        s.back[s.nback] = @truncate(@as(u64, @bitCast(c)));
        s.nback += 1;
        s.pos -= 1;
        s.eof = false;
        zfstd.debug.assert(s.nback <= s.back.len);
        return 0;
    }

    /// §9.5.8 `code = $feof(fd)`: "returns a nonzero value when EOF has
    /// previously been detected reading fd; returns zero otherwise".
    pub fn eof(self: *const ZfTable, d: i64) i64 {
        const k = self.slot(d) orelse return 0;
        zfstd.debug.assert(self.slots.items[k].open);
        return @intFromBool(self.slots.items[k].eof);
    }

    /// §9.5.7 `errno = $ferror(fd, str)`'s code for the most recent operation
    /// on `d`, 0 for none. A descriptor of 0 is the one §9.5.1 sends here
    /// after a failed open: "Applications can call $ferror to determine the
    /// cause of the most recent error".
    pub fn err(self: *const ZfTable, d: i64) i64 {
        const k = self.slot(d) orelse return self.last_err;
        zfstd.debug.assert(self.slots.items[k].open);
        return self.slots.items[k].err;
    }

    /// §9.5.1 `$fclose(mcd)` / `$fclose(fd)`: closes every channel `d` names,
    /// freeing each for reuse. Returns 0.
    pub fn close(self: *ZfTable, io: zfstd.Io, d: i64) i64 {
        if (d == 0) return 0;
        if (d & zf_fd_bit != 0) {
            self.close1(io, self.slot(d) orelse return 0);
            return 0;
        }
        var b: u6 = 1;
        while (b <= mcd_max) : (b += 1) {
            if (d & (@as(i64, 1) << b) == 0) continue;
            if (b <= self.slots.items.len and self.slots.items[b - 1].open) self.close1(io, b - 1);
        }
        return 0;
    }

    /// §9.5.1.1: a new analysis of the same simulation process begins, so a
    /// write-mode open appends to what earlier analyses wrote.
    pub fn newAnalysis(self: *ZfTable) void {
        self.analysis += 1;
    }

    /// Closes every channel and frees everything the table owns, with the
    /// `gpa` every growing call was given: the run is over. Invalidates every
    /// view the table returned. Leaves the table empty, as `.{}`.
    pub fn freeAll(self: *ZfTable, gpa: zfstd.mem.Allocator, io: zfstd.Io) void {
        for (self.slots.items) |*s| {
            if (s.open) s.f.close(io);
            gpa.free(s.line);
        }
        self.slots.clearAndFree(gpa);
        for (self.retired.items) |b| gpa.free(b);
        self.retired.clearAndFree(gpa);
        self.written.clearAndFree(gpa);
        self.analysis = 0;
        self.last_err = 0;
        zfstd.debug.assert(self.slots.items.len == 0);
        zfstd.debug.assert(self.retired.items.len == 0);
    }

    // ---- private ----

    /// Opens `path` for `mode` (`r`, `w` or `a`, Table 9-24), or records the
    /// cause in `last_err` and returns null.
    fn openFile(self: *ZfTable, gpa: zfstd.mem.Allocator, io: zfstd.Io, path: []const u8, mode: u8, plus: bool) ?zfstd.Io.File {
        zfstd.debug.assert(mode == 'r' or mode == 'w' or mode == 'a');
        const cwd: zfstd.Io.Dir = .cwd();
        return switch (mode) {
            // Table 9-24 "r"/"r+": an existing file.
            'r' => cwd.openFile(io, path, .{ .mode = if (plus) .read_write else .read_only }) catch |e| {
                self.last_err = zfErrno(e);
                return null;
            },
            'w' => w: {
                const base = self.writeBase(gpa, io, path) orelse {
                    self.last_err = 12; // ENOMEM
                    return null;
                };
                const f = cwd.createFile(io, path, .{ .read = plus, .truncate = base == 0 }) catch |e| {
                    self.last_err = zfErrno(e);
                    return null;
                };
                if (base != 0) f.setLength(io, base) catch |e| {
                    f.close(io);
                    self.last_err = zfErrno(e);
                    return null;
                };
                break :w f;
            },
            else => cwd.createFile(io, path, .{ .read = plus, .truncate = false }) catch |e| {
                self.last_err = zfErrno(e);
                return null;
            },
        };
    }

    /// The length a write-mode open of `path` truncates to (§9.5.1.1: "if a
    /// file is opened in a write mode in the first analysis and reopened in
    /// that write mode in following analysis, then content written from the
    /// following analyses shall be appended"): 0 the first time, the earlier
    /// analyses' content after that. Null when the path is new and no memory
    /// is left to remember it: forgetting it would truncate it later.
    fn writeBase(self: *ZfTable, gpa: zfstd.mem.Allocator, io: zfstd.Io, path: []const u8) ?u64 {
        const h = zfstd.hash.Wyhash.hash(0, path);
        for (self.written.items) |*w| if (w.hash == h) {
            if (w.analysis != self.analysis) {
                const st = zfstd.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
                w.* = .{ .hash = h, .analysis = self.analysis, .base = st.size };
            }
            return w.base;
        };
        self.written.append(gpa, .{ .hash = h, .analysis = self.analysis, .base = 0 }) catch return null;
        return 0;
    }

    /// The row descriptor `d` names, or null: the 0 a failed open returned,
    /// one of the three standard fds, or a closed channel. An mcd's lowest
    /// set bit above bit 0 names the channel a single-channel operation acts
    /// on; OR-ing several is a write-side rule (`put`).
    fn slot(self: *const ZfTable, d: i64) ?usize {
        if (d == 0) return null;
        if (d & zf_fd_bit != 0) {
            const ch = d & 0x7fff_ffff;
            if (ch < 3) return null;
            const k: usize = mcd_max + @as(usize, @intCast(ch - 3));
            return if (k < self.slots.items.len and self.slots.items[k].open) k else null;
        }
        const bits = d & 0x7fff_fffe; // bits 1..30: bit b is row b - 1
        if (bits == 0) return null;
        const k: usize = @ctz(bits) - 1;
        zfstd.debug.assert(k < mcd_max);
        return if (k < self.slots.items.len and self.slots.items[k].open) k else null;
    }

    fn put1(self: *ZfTable, io: zfstd.Io, k: usize, text: []const u8) i64 {
        const s = &self.slots.items[k];
        zfstd.debug.assert(s.open);
        if (!s.can_write) {
            s.err = 9; // EBADF: opened "r"
            self.last_err = 9;
            return 0;
        }
        // Table 9-24 "a"/"a+": every write goes to the end, wherever a
        // `$fseek` left the position.
        if (s.append) s.pos = s.f.length(io) catch s.pos;
        s.f.writePositionalAll(io, text, s.pos) catch |e| {
            s.err = zfErrno(e);
            self.last_err = s.err;
            return 0;
        };
        s.pos += text.len;
        s.err = 0;
        self.last_err = 0;
        return @intCast(text.len);
    }

    /// Grows row `k`'s line to at least `want` bytes, doubling, keeping its
    /// content; the old buffer is retired, not freed. E1011 when memory runs
    /// out.
    fn grow(self: *ZfTable, gpa: zfstd.mem.Allocator, k: usize, want: usize) void {
        const s = &self.slots.items[k];
        if (s.line.len >= want) return;
        var cap: usize = @max(s.line.len, 4096);
        while (cap < want) cap = zfstd.math.mul(usize, cap, 2) catch zfOver();
        self.retired.ensureUnusedCapacity(gpa, 1) catch zfOver();
        const nb = gpa.alloc(u8, cap) catch zfOver();
        @memcpy(nb[0..s.line_len], s.line[0..s.line_len]);
        if (s.line.len != 0) self.retired.appendAssumeCapacity(s.line);
        s.line = nb;
        zfstd.debug.assert(s.line.len >= want);
    }

    fn close1(self: *ZfTable, io: zfstd.Io, k: usize) void {
        zfstd.debug.assert(self.slots.items[k].open);
        self.slots.items[k].f.close(io);
        self.slots.items[k].open = false;
    }
};

/// One channel. `pos` is §9.5.5's own quantity ("the offset from the
/// beginning of the file of the current byte of the file fd, which shall be
/// read or written by a subsequent operation"), kept here rather than left
/// to the OS because every read and write is positional: a buffered reader
/// would consume past a newline and `$ftell` after `$fgets` would report a
/// position no clause allows. Every field of a row is read by the operation
/// on it, so the table is rows, not columns.
const ZfSlot = struct {
    open: bool = false,
    f: zfstd.Io.File = undefined,
    pos: u64 = 0,
    /// §9.5.8 "EOF has previously been detected reading fd".
    eof: bool = false,
    /// §9.5.7's errno for the most recent operation on this descriptor.
    err: u8 = 0,
    can_read: bool = false,
    can_write: bool = false,
    /// Table 9-24 "a"/"a+": every write goes to the end of the file.
    append: bool = false,
    /// The most recent §9.5.4.1/§9.5.4.2 line or window. §9.5.4.1 puts no
    /// length limit on a line and §3.3's `string` has no fixed width, so it
    /// grows to the longest read (`grow`).
    line: []u8 = &.{},
    line_len: usize = 0,
    /// IEEE 1364-2005 §17.2.4.1 the characters `$ungetc` pushed back, the
    /// last pushed first. Every read takes them before the file, which then
    /// resumes at `pos + nback` (VD-084).
    back: [16]u8 = undefined,
    nback: u8 = 0,

    // One cache line per channel where the OS handle is 8 bytes; the budget
    // excludes the handle, whose size is the OS's.
    comptime {
        zfstd.debug.assert(@sizeOf(ZfSlot) - @sizeOf(zfstd.Io.File) <= 56);
    }
};

/// §9.5.1.1 one write-mode path: its hash, the analysis that last opened it,
/// and the length the earlier analyses left.
const ZfWritten = struct { hash: u64, analysis: u32, base: u64 };

/// Bit 31 of a descriptor: set on an fd, clear on an mcd (§9.5.1).
const zf_fd_bit: i64 = 1 << 31;

// ---- private ----

/// E1011: a line or scan needs more memory than is left. Fatal: the clause
/// has no shorter answer to give.
fn zfOver() noreturn {
    zfstd.debug.print("error[E1011]: a line read from a file does not fit in the memory left; see `vera --explain E1011`\n", .{});
    zfstd.process.exit(1);
}

/// A nonzero errno for §9.5.7 (`zFErrorStr`), the C value where one
/// obviously matches; §9.5.7 says only "an error code is returned".
fn zfErrno(e: anyerror) u8 {
    return switch (e) {
        error.FileNotFound => 2, // ENOENT
        error.AccessDenied, error.PermissionDenied => 13, // EACCES
        error.IsDir => 21, // EISDIR
        error.NoSpaceLeft => 28, // ENOSPC
        else => 5, // EIO, "should any error be detected"
    };
}
