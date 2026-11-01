//! §9.5 file descriptors: a table, a descriptor and an operation's arguments
//! in, the operation's §9.5 result (a descriptor, a count, a position, a
//! status) out, with the file system changed as the clause says: the device
//! ABI behind `contract.FileIo`, whose `ctx` is the `ZfTable`
//! (`file_table.zig`) every function here acts on, over
//! `std.heap.page_allocator` and the process's single-threaded `Io`. The
//! table is the caller's: a device keeps one per instance (`Instance.zf__`,
//! `fileIo`, `deinitInstance`), the digital engine one per `Run`. Device
//! text (`text.file`, after `file_table.zig`) for a `--display=emit` device
//! that calls the family, and host Zig for the digital engine's table
//! (`sim/digital/files.zig` `own`), so a mixed simulation's two contexts can
//! share one instance's channels (§9.5.1.2).
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
//! - `pub fn zFCtx(t: *const ZfTable) *anyopaque`
//! - `pub fn zFNewAnalysis(ctx: *anyopaque) void`
//! - `pub fn zFFreeAll(ctx: *anyopaque) void`
//! - `pub fn zFOpen(ctx: *anyopaque, path: []const u8, ty: []const u8, mcd: bool) i64`
//! - `pub fn zFPut(ctx: *anyopaque, d: i64, text: []const u8) i64`
//! - `pub fn zFGets(ctx: *anyopaque, d: i64) i64`
//! - `pub fn zFLine(ctx: *anyopaque, n: i64, d: i64) []const u8`
//! - `pub fn zFLatch(ctx: *anyopaque, slot: *const []const u8, n: i64, d: i64) i64`
//! - `pub fn zFLineAt(line: []const u8, n: i64) []const u8`
//! - `pub fn zFWindow(ctx: *anyopaque, d: i64) []const u8`
//! - `pub fn zFTake(ctx: *anyopaque, d: i64, n: i64, used: i64) i64`
//! - `pub fn zFMore(ctx: *anyopaque, d: i64, used: usize) bool`
//! - `pub fn zFTell(ctx: *anyopaque, d: i64) i64`
//! - `pub fn zFSeek(ctx: *anyopaque, d: i64, off: i64, op: i64) i64`
//! - `pub fn zFGetc(ctx: *anyopaque, d: i64) i64`
//! - `pub fn zFUngetc(ctx: *anyopaque, c: i64, d: i64) i64`
//! - `pub fn zFEof(ctx: *anyopaque, d: i64) i64`
//! - `pub fn zFError(ctx: *anyopaque, d: i64) i64`
//! - `pub fn zFErrorStr(e: i64, _: i64) []const u8`
//! - `pub fn zFFlush(_: i64) i64`
//! - `pub fn zFClose(ctx: *anyopaque, d: i64) i64`
//! - `pub fn zFKeep(slot: *const i64, v: i64) i64`

const zfstd = @import("std");
// The device has it at file scope; the host compile aliases it.
const ZfTable = @import("file_table.zig").ZfTable;

// ---- device text ----

/// The allocator behind the device's table: `std.heap.page_allocator`, which
/// every target a device builds for has. A `var` so a test can run the
/// device ABI over a checking or failing allocator; swap it only while the
/// table is empty.
pub var zf_gpa: zfstd.mem.Allocator = zfstd.heap.page_allocator;

/// `t` as the `ctx` every function here takes. A device's display unit
/// writes its instance's table through the `*const Instance` the contract
/// hands `display` (`contract.InstancePtr`), so this drops the `const`: the
/// host's instance is writable memory (`setupInstance` takes `*Instance`)
/// that only the display phase writes, one call per instance at a time.
pub fn zFCtx(t: *const ZfTable) *anyopaque {
    return @constCast(t);
}

/// §9.5.1.1 a new analysis of the same simulation process begins.
pub fn zFNewAnalysis(ctx: *anyopaque) void {
    zfT(ctx).newAnalysis();
}

/// Closes every channel and frees the table: its instance or run is over.
/// A host that runs one simulation per process may skip it.
pub fn zFFreeAll(ctx: *anyopaque) void {
    zfT(ctx).freeAll(zf_gpa, zfIo());
}

/// §9.5.1 `$fopen` on the table (`ZfTable.open`).
pub fn zFOpen(ctx: *anyopaque, path: []const u8, ty: []const u8, mcd: bool) i64 {
    return zfT(ctx).open(zf_gpa, zfIo(), path, ty, mcd);
}

/// §9.5.2's output tasks on the table (`ZfTable.put`).
pub fn zFPut(ctx: *anyopaque, d: i64, text: []const u8) i64 {
    return zfT(ctx).put(zfIo(), d, text);
}

/// §9.5.4.1 `$fgets` on the table (`ZfTable.gets`).
pub fn zFGets(ctx: *anyopaque, d: i64) i64 {
    return zfT(ctx).gets(zf_gpa, zfIo(), d);
}

/// The line `$fgets` or `$fscanf` last read from `d` (`ZfTable.line`).
pub fn zFLine(ctx: *anyopaque, n: i64, d: i64) []const u8 {
    return zfT(ctx).line(n, d);
}

/// Performs the count `n` of a call site on descriptor `d`: latches a copy
/// of the line the read left (`ZfTable.latch`) into the site's `slot`, an
/// `Instance` field the display unit writes as `zFCtx` says, and returns
/// `n`. A reader is a pure value codegen may place at its first use, which
/// can follow a `$fclose` or a second read of the same descriptor, so
/// readers take this copy (`zFLineAt`).
// ponytail: one copy per performed read, kept until the table is freed;
// reuse the buffer once no string can still view it if a run reads
// millions of lines.
pub fn zFLatch(ctx: *anyopaque, slot: *const []const u8, n: i64, d: i64) i64 {
    @constCast(slot).* = zfT(ctx).latch(zf_gpa, d);
    return n;
}

/// Returns the `line` a call site's read latched (`zFLatch`), whatever its
/// descriptor has done since; "" when the count `n` says nothing was
/// transferred.
pub fn zFLineAt(line: []const u8, n: i64) []const u8 {
    if (n <= 0) return "";
    return line;
}

/// §9.5.4.2's input window on the table (`ZfTable.window`).
pub fn zFWindow(ctx: *anyopaque, d: i64) []const u8 {
    return zfT(ctx).window(zf_gpa, zfIo(), d);
}

/// §9.5.4.2's consumption on the table (`ZfTable.take`).
pub fn zFTake(ctx: *anyopaque, d: i64, n: i64, used: i64) i64 {
    return zfT(ctx).take(d, n, used);
}

/// Whether a `$fscanf` scan must widen its window (`ZfTable.more`).
pub fn zFMore(ctx: *anyopaque, d: i64, used: usize) bool {
    return zfT(ctx).more(zf_gpa, d, used);
}

/// §9.5.5 `$ftell` on the table (`ZfTable.tell`).
pub fn zFTell(ctx: *anyopaque, d: i64) i64 {
    return zfT(ctx).tell(d);
}

/// §9.5.5 `$fseek`/`$rewind` on the table (`ZfTable.seek`).
pub fn zFSeek(ctx: *anyopaque, d: i64, off: i64, op: i64) i64 {
    return zfT(ctx).seek(zfIo(), d, off, op);
}

/// IEEE 1364-2005 §17.2.4.1 `$fgetc` on the table (`ZfTable.getc`).
pub fn zFGetc(ctx: *anyopaque, d: i64) i64 {
    return zfT(ctx).getc(zfIo(), d);
}

/// IEEE 1364-2005 §17.2.4.1 `$ungetc` on the table (`ZfTable.ungetc`).
pub fn zFUngetc(ctx: *anyopaque, c: i64, d: i64) i64 {
    return zfT(ctx).ungetc(c, d);
}

/// §9.5.8 `$feof` on the table (`ZfTable.eof`).
pub fn zFEof(ctx: *anyopaque, d: i64) i64 {
    return zfT(ctx).eof(d);
}

/// §9.5.7 `$ferror`'s code on the table (`ZfTable.err`).
pub fn zFError(ctx: *anyopaque, d: i64) i64 {
    return zfT(ctx).err(d);
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

/// §9.5.1 `$fclose` on the table (`ZfTable.close`).
pub fn zFClose(ctx: *anyopaque, d: i64) i64 {
    return zfT(ctx).close(zfIo(), d);
}

/// The display unit's half of a call site's latched §9.5 result: performs,
/// stores `v` into the site's `slot` (an `Instance` field, written as
/// `zFCtx` says), answers `v`. The call is performed only there (§9.5.9),
/// so every other unit reads the slot, the value this site last produced
/// (`fd = $fopen(..)` under `@(initial_step)` holds the descriptor, not a 0
/// that `$ftell(fd)` reads as "no such file"). Within one point the core
/// sees the previous point's result until the display unit runs. Integer
/// results only, which is every descriptor, count, position and status
/// §9.5 returns.
pub fn zFKeep(slot: *const i64, v: i64) i64 {
    @constCast(slot).* = v;
    return v;
}

// ---- private ----

fn zfT(ctx: *anyopaque) *ZfTable {
    return @ptrCast(@alignCast(ctx));
}

fn zfIo() zfstd.Io {
    return zfstd.Io.Threaded.global_single_threaded.io();
}
