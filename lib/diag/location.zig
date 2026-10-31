//! Locations: a span in the preprocessed text in, the file, line and column a
//! person reads out, through the preprocessor's segment map and the
//! comment-stripping marks.
//!
//! Cites: LRM §2.4 (comments), the stripping the marks undo.
//!
//! Contents:
//! - `pub const Span = struct { start: u32, end: u32 }`, `none`, `at`, `len`, `isNone`
//! - `pub const Loc = struct { line: u32, col: u32 }`
//! - `pub const FileId = enum(u16) { root = 0, none = maxInt(u16), _ }`
//! - `pub const files_max: u32`
//! - `pub const Segment = struct`, `no_parent`
//! - `pub const File = struct { name, text, raw: []const u8, to_src: []const StripMark }`
//! - `pub const StripMark = struct { out: u32, src: u32 }`
//! - `pub const SourceMap = struct`, `empty`, `pub fn resolve(map: SourceMap, off: u32) Resolved`
//! - `pub fn toSourceOffset(marks: []const StripMark, off: u32) u32`
//! - `pub const LineIndex = struct`, `build`, `loc`, `lineText`
//! - `pub const LineCache = struct`, `init`, `index`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// A byte range in the PREPROCESSED text, the one currency every stage
/// reports in. `SourceMap` turns it back into a file, line and column.
/// `end == start` is a legal zero-width span: one caret, or "insert here" in
/// a `Fix`. An inverted span (`end < start`) is tolerated, not asserted: spans
/// come from every stage and rendering must survive a bad one.
pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,

    /// "No location": the renderer prints no `-->` line and no snippet.
    pub const none: Span = .{ .start = 0, .end = 0 };

    /// Returns a zero-width span at `start`.
    pub fn at(start: u32) Span {
        return .{ .start = start, .end = start };
    }

    /// Returns the byte length; an inverted span saturates to 0.
    pub fn len(self: Span) u32 {
        return self.end -| self.start;
    }

    /// Returns true for `none`, and therefore also for `at(0)`: a zero-width
    /// span at the first byte is indistinguishable from no span.
    pub fn isNone(self: Span) bool {
        return self.start == 0 and self.end == 0;
    }

    comptime {
        assert(@sizeOf(Span) == 8); // Every row carries up to nine of these.
    }
};

/// A 1-based line and byte column, because humans and every editor count so.
pub const Loc = struct { line: u32 = 0, col: u32 = 0 };

/// Most files one compilation may register: every `FileId` but the sentinel.
pub const files_max: u32 = std.math.maxInt(u16);

/// Index into `Bag.files`, in the order the preprocessor opened them.
pub const FileId = enum(u16) {
    /// The top-level compilation unit.
    root = 0,
    /// No file: the span is in the preprocessed text and resolves through
    /// `Bag.map`. Only a preprocessor diagnostic names a file.
    none = std.math.maxInt(u16),
    _,
};

/// How a run of the preprocessed text came to exist. The preprocessor appends
/// one every time the ORIGIN of the output changes: entering an `include,
/// starting a macro expansion, or returning from either. Sorted by
/// `out_start` by construction (the preprocessor only appends), so lookup is
/// a binary search with no sort step.
pub const Segment = struct {
    /// First byte of the preprocessed text this segment explains.
    out_start: u32,
    /// The matching byte in `file`'s ORIGINAL text. Meaningless for `.macro`,
    /// whose bytes came from a macro body rather than from a file run.
    in_start: u32,
    file: FileId,
    kind: enum(u8) { verbatim, macro },
    /// Index of the enclosing segment, or `no_parent`. Always below this
    /// segment's own index: an enclosing segment is appended first.
    parent: u32 = no_parent,
    /// Macro name, for `.macro` segments. Borrowed from the preprocessor's
    /// arena until `Bag.detach` copies it.
    macro: []const u8 = "",

    /// `parent` of a top-level segment: no enclosing expansion or include.
    pub const no_parent: u32 = std.math.maxInt(u32);

    comptime {
        // One row per origin change (7,769 rows on hisimhv_va); half of it is
        // the `macro` slice, which the preprocessor owns.
        assert(@sizeOf(Segment) <= 32);
    }
};

/// One file of the compilation, as `Bag.files` stores it. Every slice is
/// borrowed from the compilation arena (or static) until `Bag.detach` copies
/// them into one gpa buffer. AoS: rendering reads every field of one file
/// together, and there are a handful of files.
pub const File = struct {
    name: []const u8,
    /// The text SPANS index: comment-stripped once the preprocessor has run
    /// (`Bag.setStrippedText`), the registered text until then. Its newline
    /// count matches the original (the preprocessor's line contract), so a
    /// LINE read off it is true of both.
    text: []const u8,
    /// The ORIGINAL text, before comment stripping; empty when `text` is the
    /// original. Snippets are cut from here, so the user sees what they wrote.
    raw: []const u8 = "",
    /// Stripped offset to original offset, one mark per collapsed comment.
    to_src: []const StripMark = &.{},
};

/// One point where comment stripping (§2.4) made the stripped text SHORTER
/// than the original: from `out` up to the next mark the two advance in
/// lockstep, so original = `src + (stripped - out)`. Before the first mark
/// the mapping is identity. Sorted by `out`: the stripper appends left to
/// right.
pub const StripMark = struct {
    out: u32,
    src: u32,

    comptime {
        assert(@sizeOf(StripMark) == 8); // One row per stripped comment (3,703 on hisimhv_va).
    }
};

/// Preprocessed offsets to file offsets. An EMPTY map is legal and means
/// "the preprocessed text is the source": every offset resolves to `root`
/// unchanged, so no stage needs a null check.
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
    /// offset inside a macro expansion resolves to the invocation site (the
    /// nearest enclosing verbatim segment); one before the first segment to
    /// that segment's start. O(log n) plus the macro's parent chain.
    /// Asserts that every `parent` is below its segment's index, which the
    /// preprocessor's appending guarantees.
    pub fn resolve(map: SourceMap, off: u32) Resolved {
        if (map.segs.len == 0) return .{ .file = .root, .offset = off, .seg = Segment.no_parent };
        assert(map.segs.len < Segment.no_parent);

        // The last segment with out_start <= off; the first one when none is.
        const lo = std.sort.partitionPoint(Segment, map.segs, off, startsAtOrBefore) -| 1;
        const s = map.segs[lo];
        const seg: u32 = @intCast(lo);
        if (s.kind == .verbatim) {
            // Saturating both ways: an `off` before the first segment lands on
            // its start, and one past `maxInt(u32)` stays there.
            return .{ .file = s.file, .offset = s.in_start +| (off -| s.out_start), .seg = seg };
        }
        // Inside an expansion the offset has no counterpart in any file: the
        // honest answer is the invocation site the nearest verbatim ancestor
        // records. Each step moves to a lower index, so the walk is bounded.
        var cur = seg;
        var p = s.parent;
        while (p != Segment.no_parent) {
            assert(p < cur);
            const q = map.segs[p];
            if (q.kind == .verbatim) return .{ .file = q.file, .offset = q.in_start, .seg = seg };
            cur = p;
            p = q.parent;
        }
        return .{ .file = s.file, .offset = s.in_start, .seg = seg };
    }
};

/// Byte offset to line and column, by binary search over the line starts.
/// Built once per rendered file, only when there is something to render.
pub const LineIndex = struct {
    /// Offset of each line's first byte; `starts[0]` is 0 and the list is
    /// strictly increasing.
    starts: []const u32,

    /// Returns the index of `text`, one exact allocation in `arena` (4 bytes
    /// per line plus one). O(n) in `text`: one count, one fill.
    /// Asserts that `text` is shorter than 4 GiB.
    pub fn build(arena: Allocator, text: []const u8) Allocator.Error!LineIndex {
        assert(text.len < std.math.maxInt(u32));
        // Counted first so the arena holds one exact slice, not the dead
        // prefixes of a list grown one line at a time.
        const starts = try arena.alloc(u32, std.mem.countScalar(u8, text, '\n') + 1);
        starts[0] = 0;
        var n: usize = 1;
        var pos: usize = 0;
        while (std.mem.findScalarPos(u8, text, pos, '\n')) |i| : (n += 1) {
            assert(n < starts.len); // One iteration per counted newline.
            pos = i + 1;
            starts[n] = @intCast(pos);
        }
        assert(n == starts.len);
        return .{ .starts = starts };
    }

    /// Returns the 1-based line and byte column of `off`. An `off` past the
    /// text lands on the last line, with a column past its end. O(log lines).
    pub fn loc(self: LineIndex, off: u32) Loc {
        assert(self.starts.len > 0);
        assert(self.starts[0] == 0);
        const lo = std.sort.partitionPoint(u32, self.starts, off, lineAtOrBefore) - 1;
        return .{ .line = @intCast(lo + 1), .col = off - self.starts[lo] + 1 };
    }

    /// Returns the text of `line` (1-based), without its `\n` or `\r\n`, as a
    /// slice of `text`, which must be the text the index was built from.
    /// Empty for line 0 or a line past the end.
    pub fn lineText(self: LineIndex, text: []const u8, line: u32) []const u8 {
        if (line == 0 or line > self.starts.len) return "";
        const start = self.starts[line - 1];
        const end: u32 = if (line < self.starts.len) self.starts[line] else @intCast(text.len);
        assert(start <= end);
        var slice = text[@min(start, text.len)..@min(end, text.len)];
        if (std.mem.endsWith(u8, slice, "\n")) slice = slice[0 .. slice.len - 1];
        if (std.mem.endsWith(u8, slice, "\r")) slice = slice[0 .. slice.len - 1];
        assert(std.mem.findScalar(u8, slice, '\n') == null);
        return slice;
    }
};

/// One `LineIndex` per file, built on first use: a 60-file include tree with
/// one error touches one index. Lives on a renderer's scratch arena.
pub const LineCache = struct {
    /// One slot per file plus one shared by every unknown `FileId` (whose
    /// text is always empty), so an unknown id never caches into a real
    /// file's slot.
    slots: []?LineIndex,

    /// Returns a cache for `file_count` files, its slots in `scratch`.
    pub fn init(scratch: Allocator, file_count: usize) Allocator.Error!LineCache {
        const slots = try scratch.alloc(?LineIndex, file_count + 1);
        @memset(slots, null);
        assert(slots.len == file_count + 1);
        return .{ .slots = slots };
    }

    /// Returns the index of `file`, whose text is `text`, building it in
    /// `scratch` the first time. `text` must be the same on every call for
    /// one file.
    pub fn index(cache: LineCache, scratch: Allocator, file: FileId, text: []const u8) Allocator.Error!LineIndex {
        assert(cache.slots.len > 0);
        const slot = &cache.slots[@min(@backingInt(file), cache.slots.len - 1)];
        if (slot.*) |built| return built;
        slot.* = try .build(scratch, text);
        return slot.*.?;
    }
};

/// Returns the offset in the ORIGINAL text of a stripped-text offset, through
/// `marks` (sorted by `out`). Identity before the first mark and for no
/// marks; saturates at `maxInt(u32)`, so an offset past the text maps past it
/// rather than overflowing. O(log marks).
pub fn toSourceOffset(marks: []const StripMark, off: u32) u32 {
    if (marks.len == 0 or off < marks[0].out) return off;
    const lo = std.sort.partitionPoint(StripMark, marks, off, markAtOrBefore) - 1;
    assert(marks[lo].out <= off);
    assert(marks[lo].src >= marks[lo].out); // Stripping only ever shortens the text.
    return marks[lo].src +| (off - marks[lo].out);
}

// ---- private ----

fn startsAtOrBefore(off: u32, s: Segment) bool {
    return s.out_start <= off;
}

fn markAtOrBefore(off: u32, m: StripMark) bool {
    return m.out <= off;
}

fn lineAtOrBefore(off: u32, start: u32) bool {
    return start <= off;
}
