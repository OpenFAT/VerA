//! §9.5 file descriptors: a descriptor and an operation's arguments in, the
//! operation's §9.5 result (a descriptor, a count, a position, a status) out,
//! with the file system changed as the clause says: the device ABI, one
//! process-global `ZfTable` (`file_table.zig`) behind `contract.FileIo`'s
//! context-free function pointers, over `std.heap.page_allocator` and the
//! process's single-threaded `Io`. Device text (`text.file`, after
//! `file_table.zig`) for a `--display=emit` device that calls the family, and
//! host Zig for the digital engine's own table (`sim/digital/system.zig`
//! `own`), so a mixed simulation's two contexts share one set of channels.
//! Cites: VAMS §9.2 (Table 9-2), §9.5.1 (Table 9-24), §9.5.1.1, §9.5.1.2,
//! §9.5.2, §9.5.4.1, §9.5.4.2, §9.5.5-§9.5.9; IEEE 1364-2005 §17.2.4.1,
//! §17.2.8; docs/specification/Vague_Decisions.md VD-084.
//!
//! A residual has to be a pure function of x or Newton cannot converge, so
//! the family runs only in the contract's per-point side-effect phase, the
//! `display` decl (§9.5.9: "the file write operations shall not be performed
//! unless the iteration is accepted"). A solver device has no `display`
//! decl and so no table, and its `$fopen` answers 0, which is §9.5.1's own
//! answer: "if a file cannot be opened ... a zero is returned for the mcd or
//! fd". Not here, because Table 9-2 marks them "No" and no context calls
//! them through the table: the b/h/o radix spellings (answered before
//! `zFPut`), $fread, $readmemb/$readmemh and $sdf_annotate.
//!
//! Contents:
//! - `pub var zf_gpa: std.mem.Allocator`
//! - `pub fn zFNewAnalysis() void`
//! - `pub fn zFFreeAll() void`
//! - `pub fn zFOpen(path: []const u8, ty: []const u8, mcd: bool) i64`
//! - `pub fn zFPut(d: i64, text: []const u8) i64`
//! - `pub fn zFGets(d: i64) i64`
//! - `pub fn zFLine(n: i64, d: i64) []const u8`
//! - `pub fn zFLatch(comptime site: usize, n: i64, d: i64) i64`
//! - `pub fn zFLineAt(comptime site: usize, n: i64) []const u8`
//! - `pub fn zFWindow(d: i64) []const u8`
//! - `pub fn zFTake(d: i64, n: i64, used: i64) i64`
//! - `pub fn zFMore(d: i64, used: usize) bool`
//! - `pub fn zFTell(d: i64) i64`
//! - `pub fn zFSeek(d: i64, off: i64, op: i64) i64`
//! - `pub fn zFGetc(d: i64) i64`
//! - `pub fn zFUngetc(c: i64, d: i64) i64`
//! - `pub fn zFEof(d: i64) i64`
//! - `pub fn zFError(d: i64) i64`
//! - `pub fn zFErrorStr(e: i64, _: i64) []const u8`
//! - `pub fn zFFlush(_: i64) i64`
//! - `pub fn zFClose(d: i64) i64`
//! - `pub fn zFRes(comptime site: usize) *i64`
//! - `pub fn zFKeep(comptime site: usize, v: i64) i64`

const zfstd = @import("std");
// The device has it at file scope; the host compile aliases it.
const ZfTable = @import("file_table.zig").ZfTable;

// ---- device text ----

/// The allocator behind the device's table: `std.heap.page_allocator`, which
/// every target a device builds for has. A `var` so a test can run the
/// device ABI over a checking or failing allocator; swap it only while the
/// table is empty.
pub var zf_gpa: zfstd.mem.Allocator = zfstd.heap.page_allocator;

// ponytail: one table per device image, file scope, for `zSBuf`'s reason: a
// descriptor outlives the expression that produced it, and the contract's
// `FileIo` has no context to carry a table. Two instances of one module
// share it; per-instance channels are the upgrade the day a harness runs
// two instances of a model that opens files.
var zf_table: ZfTable = .{};

/// §9.5.1.1 a new analysis of the same simulation process begins.
pub fn zFNewAnalysis() void {
    zf_table.newAnalysis();
}

/// Closes every channel and frees the device table: the run is over. A host
/// that runs one simulation per process may skip it.
pub fn zFFreeAll() void {
    zf_table.freeAll(zf_gpa, zfIo());
}

/// §9.5.1 `$fopen` on the device table (`ZfTable.open`).
pub fn zFOpen(path: []const u8, ty: []const u8, mcd: bool) i64 {
    return zf_table.open(zf_gpa, zfIo(), path, ty, mcd);
}

/// §9.5.2's output tasks on the device table (`ZfTable.put`).
pub fn zFPut(d: i64, text: []const u8) i64 {
    return zf_table.put(zfIo(), d, text);
}

/// §9.5.4.1 `$fgets` on the device table (`ZfTable.gets`).
pub fn zFGets(d: i64) i64 {
    return zf_table.gets(zf_gpa, zfIo(), d);
}

/// The line `$fgets` or `$fscanf` last read from `d` (`ZfTable.line`).
pub fn zFLine(n: i64, d: i64) []const u8 {
    return zf_table.line(n, d);
}

/// Performs the count `n` of call site `site` on descriptor `d`: latches a
/// copy of the line the read left (`ZfTable.latch`) and returns `n`. A
/// reader is a pure value codegen may place at its first use, which can
/// follow a `$fclose` or a second read of the same descriptor, so readers
/// take this copy (`zFLineAt`).
// ponytail: one copy per performed read, kept until the run ends; reuse the
// buffer once no string can still view it if a run reads millions of lines.
pub fn zFLatch(comptime site: usize, n: i64, d: i64) i64 {
    zfLatchOf(site).text = zf_table.latch(zf_gpa, d);
    return n;
}

/// Returns the line call site `site`'s read latched, whatever its descriptor
/// has done since; "" when the count `n` says nothing was transferred.
pub fn zFLineAt(comptime site: usize, n: i64) []const u8 {
    if (n <= 0) return "";
    return zfLatchOf(site).text;
}

/// §9.5.4.2's input window on the device table (`ZfTable.window`).
pub fn zFWindow(d: i64) []const u8 {
    return zf_table.window(zf_gpa, zfIo(), d);
}

/// §9.5.4.2's consumption on the device table (`ZfTable.take`).
pub fn zFTake(d: i64, n: i64, used: i64) i64 {
    return zf_table.take(d, n, used);
}

/// Whether a `$fscanf` scan must widen its window (`ZfTable.more`).
pub fn zFMore(d: i64, used: usize) bool {
    return zf_table.more(zf_gpa, d, used);
}

/// §9.5.5 `$ftell` on the device table (`ZfTable.tell`).
pub fn zFTell(d: i64) i64 {
    return zf_table.tell(d);
}

/// §9.5.5 `$fseek`/`$rewind` on the device table (`ZfTable.seek`).
pub fn zFSeek(d: i64, off: i64, op: i64) i64 {
    return zf_table.seek(zfIo(), d, off, op);
}

/// IEEE 1364-2005 §17.2.4.1 `$fgetc` on the device table (`ZfTable.getc`).
pub fn zFGetc(d: i64) i64 {
    return zf_table.getc(zfIo(), d);
}

/// IEEE 1364-2005 §17.2.4.1 `$ungetc` on the device table (`ZfTable.ungetc`).
pub fn zFUngetc(c: i64, d: i64) i64 {
    return zf_table.ungetc(c, d);
}

/// §9.5.8 `$feof` on the device table (`ZfTable.eof`).
pub fn zFEof(d: i64) i64 {
    return zf_table.eof(d);
}

/// §9.5.7 `$ferror`'s code on the device table (`ZfTable.err`).
pub fn zFError(d: i64) i64 {
    return zf_table.err(d);
}

/// Returns §9.5.7's description half for code `e`: "a string description of
/// type of error encountered by the most recent file I/O operation is
/// written into str", and with none "the string variable str shall be
/// empty". The numeric values are the C ones where one obviously matches and
/// no fixture pins them: §9.5.7 fixes none.
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

/// §9.5.6 `$fflush(fd)`: "writes any buffered output to the file specified
/// by fd". Every write is a positional write straight to the descriptor, so
/// there is never buffered output and this returns 0 with nothing behind it,
/// with or without an argument.
pub fn zFFlush(_: i64) i64 {
    return 0;
}

/// §9.5.1 `$fclose` on the device table (`ZfTable.close`).
pub fn zFClose(d: i64) i64 {
    return zf_table.close(zfIo(), d);
}

/// Returns call site `site`'s latched §9.5 result, carried out of the
/// display unit: the call is performed only there (§9.5.9), so every other
/// unit answers with the value this site last produced (`fd = $fopen(..)`
/// under `@(initial_step)` holds the descriptor, not a 0 that `$ftell(fd)`
/// reads as "no such file"). Within one point the core sees the previous
/// point's result until the display unit runs. Integer results only, which
/// is every descriptor, count, position and status §9.5 returns.
// ponytail: one latch per call site, file scope, on `zSBuf`'s terms; per-
// instance latches are the upgrade the day a host runs two instances of a
// model that opens files.
pub fn zFRes(comptime site: usize) *i64 {
    const ZfRes = struct {
        const n = site;
        var v: i64 = 0;
    };
    return &ZfRes.v;
}

/// The display unit's half of `zFRes`: performs, latches, answers `v`.
pub fn zFKeep(comptime site: usize, v: i64) i64 {
    zFRes(site).* = v;
    return v;
}

// ---- private ----

fn zfIo() zfstd.Io {
    return zfstd.Io.Threaded.global_single_threaded.io();
}

/// Call site `site`'s latched line (`zFLatch`).
fn zfLatchOf(comptime site: usize) type {
    return struct {
        const n = site;
        var text: []const u8 = &.{};
    };
}
