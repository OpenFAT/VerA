//! Locations: preprocessed byte offsets -> file, line and column, through the
//! preprocessor's segment map and the comment-stripping marks.
//!
//! LRM clauses this file's code cites: §2.4 (comments).

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Locations
// ---------------------------------------------------------------------------

/// A byte range in the PREPROCESSED text — the one currency every stage
/// reports in. `SourceMap` turns it back into a file, line and column.
///
/// `end == start` is a legal zero-width span: the renderer draws a single caret
/// there, and a `Fix` uses it to mean "insert here, delete nothing".
pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,

    /// "No location": the renderer prints no `-->` line and no snippet.
    pub const none: Span = .{ .start = 0, .end = 0 };

    /// Returns a zero-width span at `start`.
    pub fn at(start: u32) Span {
        return .{ .start = start, .end = start };
    }

    /// Byte length; an inverted span (`end < start`) saturates to 0.
    pub fn len(self: Span) u32 {
        return self.end -| self.start;
    }

    /// True for `none`, and therefore also for `at(0)`: a zero-width span at
    /// the first byte is indistinguishable from no span.
    pub fn isNone(self: Span) bool {
        return self.start == 0 and self.end == 0;
    }

    // Budget: two u32 offsets. Every `Record` carries up to nine of these.
    comptime {
        std.debug.assert(@sizeOf(Span) == 8);
    }
};

/// 1-based, because humans and every editor count that way.
pub const Loc = struct { line: u32 = 0, col: u32 = 0 };

/// Index into `Bag.files`, in the order the preprocessor opened them.
pub const FileId = enum(u16) {
    /// The top-level compilation unit.
    root = 0,
    _,
};

/// How a run of the preprocessed text came to exist. The preprocessor appends
/// one of these every time the ORIGIN of the output changes — entering an
/// `include, starting a macro expansion, or returning from either.
///
/// DOD: sorted by `out_start` by construction (the preprocessor only ever
/// appends), so lookup is a binary search with no sort step.
pub const Segment = struct {
    /// First byte of the preprocessed text this segment explains.
    out_start: u32,
    /// Corresponding byte in `file`'s ORIGINAL text. Meaningless for `.macro`,
    /// where the bytes came from a macro body rather than from a file run.
    in_start: u32,
    file: FileId,
    kind: enum(u8) { verbatim, macro },
    /// Index of the enclosing segment, or `no_parent`. Walking this chain
    /// produces rustc's "in this expansion of `FOO`" note stack.
    parent: u32 = no_parent,
    /// Macro name, for `.macro` segments. Borrowed from the arena.
    macro: []const u8 = "",

    /// `parent` of a top-level segment: no enclosing expansion or include.
    pub const no_parent: u32 = std.math.maxInt(u32);

    // Budget: 32 B, one row per origin change (7,769 rows on hisimhv_va).
    // Half of it is the `macro` slice; see docs/seams/s1-diag.md (removed
    // from the tree; `git show 6e59b3d4^:docs/seams/s1-diag.md`).
    comptime {
        std.debug.assert(@sizeOf(Segment) <= 32);
    }
};

/// One file of the compilation, as `Bag.files` stores it. Every slice is
/// borrowed from the compilation arena (or static) until `Bag.detach` copies
/// them into one gpa buffer.
pub const File = struct {
    name: []const u8,
    /// The text SPANS INDEX: comment-STRIPPED once the preprocessor has run
    /// (`Bag.setStrippedText`), the registered text until then. Newline count
    /// matches the original — the preprocessor's line contract — so LINES read
    /// off this text are true of both.
    text: []const u8,
    /// ORIGINAL text, before comment stripping; empty when `text` IS the
    /// original. Snippets are cut from here, so what the user sees is what the
    /// user wrote — a span's COLUMN goes through `to_src` first, because the
    /// two texts drift apart wherever a comment preceded a token on its line.
    raw: []const u8 = "",
    /// Stripped offset → original offset, one mark per comment collapsed. See
    /// `StripMark`.
    to_src: []const StripMark = &.{},
};

/// One point where comment stripping (preprocessor §2.4) made the stripped
/// text SHORTER than the original: from `out` up to the next mark the two
/// advance in lockstep, so original offset = `src + (stripped offset − out)`.
/// Before the first mark the mapping is identity. Sorted by `out` by
/// construction — the stripper appends left to right — so lookup is the same
/// binary search `SourceMap.resolve` runs.
pub const StripMark = struct {
    out: u32,
    src: u32,

    // Budget: two u32s, one row per stripped comment (3,703 on hisimhv_va).
    comptime {
        std.debug.assert(@sizeOf(StripMark) == 8);
    }
};

/// An EMPTY map is legal and means "the preprocessed text is the source": every
/// offset resolves to `root` unchanged. That is exactly right for the unit
/// tests, and it means no stage needs a null check.
pub const SourceMap = struct {
    /// Borrowed: the preprocessor's arena, or `Bag.detach`'s gpa copy.
    segs: []const Segment = &.{},

    pub const empty: SourceMap = .{};

    /// Where a preprocessed offset came from.
    pub const Resolved = struct {
        file: FileId,
        offset: u32,
        /// Index into `segs`, or `Segment.no_parent` when the map is empty.
        seg: u32,
    };

    /// Returns the file and file offset a preprocessed offset came from. An
    /// offset inside a macro expansion resolves to the invocation site; one
    /// before the first segment resolves to that segment's start. `segs` must
    /// be sorted by `out_start`, which the preprocessor's appending guarantees.
    /// O(log n), plus the length of a macro segment's parent chain.
    pub fn resolve(self: *const SourceMap, off: u32) Resolved {
        if (self.segs.len == 0)
            return .{ .file = .root, .offset = off, .seg = Segment.no_parent };

        // Last segment with out_start <= off.
        const lo = std.sort.partitionPoint(Segment, self.segs, off, struct {
            fn f(o: u32, sg: Segment) bool {
                return sg.out_start <= o;
            }
        }.f) -| 1;
        const s = self.segs[lo];
        // Inside a macro expansion the output offset has no counterpart in any
        // file; the honest answer is the macro's INVOCATION site, which is what
        // the nearest enclosing verbatim segment records.
        if (s.kind == .macro) {
            var p = s.parent;
            while (p != Segment.no_parent) {
                const q = self.segs[p];
                if (q.kind == .verbatim)
                    return .{ .file = q.file, .offset = q.in_start, .seg = @intCast(lo) };
                p = q.parent;
            }
            return .{ .file = s.file, .offset = s.in_start, .seg = @intCast(lo) };
        }
        // Saturating both ways: an `off` before the first segment (lo clamped
        // to 0) lands on that segment's start, and one past `maxInt(u32)`
        // stays there.
        return .{
            .file = s.file,
            .offset = s.in_start +| (off -| s.out_start),
            .seg = @intCast(lo),
        };
    }
};

/// Byte offset -> line, by binary search over precomputed line starts. Built
/// once per rendered file, only when there is something to render.
pub const LineIndex = struct {
    starts: []const u32,

    /// Returns the index of `text`, one exact allocation in `arena` (4 bytes
    /// per line plus one). O(n) in `text`: two scans, count then fill.
    pub fn build(arena: Allocator, text: []const u8) Allocator.Error!LineIndex {
        // Counted first so the arena holds one exact slice, not the dead
        // prefixes of a list grown one line at a time.
        const starts = try arena.alloc(u32, std.mem.countScalar(u8, text, '\n') + 1);
        starts[0] = 0;
        var n: usize = 1;
        var pos: usize = 0;
        while (std.mem.findScalarPos(u8, text, pos, '\n')) |i| : (n += 1) {
            pos = i + 1;
            starts[n] = @intCast(pos);
        }
        std.debug.assert(n == starts.len);
        return .{ .starts = starts };
    }

    /// Returns the 1-based line and byte column of `off`. An `off` past the
    /// text lands on the last line, with a column past its end. O(log lines).
    pub fn loc(self: LineIndex, off: u32) Loc {
        // `starts[0]` is 0, so the count is at least 1.
        const lo = std.sort.partitionPoint(u32, self.starts, off, struct {
            fn f(o: u32, start: u32) bool {
                return start <= o;
            }
        }.f) - 1;
        return .{ .line = @intCast(lo + 1), .col = off - self.starts[lo] + 1 };
    }

    /// The text of `line` (1-based), without its `\n` or `\r\n`; a slice of
    /// `text`, which must be the text the index was built from. Empty for
    /// line 0 or a line past the end.
    pub fn lineText(self: LineIndex, text: []const u8, line: u32) []const u8 {
        if (line == 0 or line > self.starts.len) return "";
        const start = self.starts[line - 1];
        const end = if (line < self.starts.len) self.starts[line] else @as(u32, @intCast(text.len));
        var slice = text[@min(start, text.len)..@min(end, text.len)];
        if (slice.len > 0 and slice[slice.len - 1] == '\n') slice = slice[0 .. slice.len - 1];
        if (slice.len > 0 and slice[slice.len - 1] == '\r') slice = slice[0 .. slice.len - 1];
        return slice;
    }
};
