//! The bag: every diagnostic of one compilation. In: `Builder` commits from
//! every stage, and the files and segment map the preprocessor registers.
//! Out: a table of `Row`s with their children and one string pool, sorted
//! into source order, that `render`, `renderJson` and the LSP read.
//!
//! Cites no LRM clause: the stage that reports a diagnostic cites it.
//!
//! Contents:
//! - `pub const max_entries: u32`
//! - `pub const AddFileError = Allocator.Error || error{TooManyFiles}`
//! - `pub const Bag = struct`, with
//!   `init`, `build`, `add`, `intern`, `str`, `count`, `isEmpty`, `failed`,
//!   `enabled`, `at`, `labels`, `notes`, `addFile`, `setSingleFile`,
//!   `setStrippedText`, `fileName`, `fileText`, `sourceText`, `fileMarks`,
//!   `toSourceOffset`, `locate`, `sort`, `detach`, `deinit`
//! - private `SourceOrder` with `pub fn lessThan`, as `MultiArrayList.sort` needs

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Code = @import("code.zig").Code;
const Levels = @import("level.zig").Levels;
const entry = @import("entry.zig");
const location = @import("location.zig");
const Builder = @import("builder.zig").Builder;
const Span = location.Span;
const FileId = location.FileId;
const String = entry.String;

/// Most diagnostics one bag keeps. A single broken expression otherwise
/// reports a cascade that buries the first, real error; the rest are
/// counted in `Bag.suppressed`.
pub const max_entries: u32 = 64;

/// Every way `Bag.addFile` fails. On any error the bag is unchanged.
pub const AddFileError = Allocator.Error || error{
    /// The compilation already registered `location.files_max` files.
    TooManyFiles,
};

/// Every diagnostic of one compilation, appended to across the stages and
/// read once by a renderer. Fields a caller may read directly: the counters,
/// `files` and `map`; `levels` and `map` are set by the caller. Every other
/// field is written only through the methods.
pub const Bag = struct {
    /// What every table grows in: the compilation arena until `detach`, the
    /// caller's gpa after it.
    arena: Allocator,
    /// Every diagnostic string, NUL-terminated. Byte 0 is a sentinel NUL so
    /// that `String.none` names no string; written on the first `intern`.
    strings: std.ArrayList(u8) = .empty,
    /// One row per kept diagnostic, in emission order until `sort`.
    rows: std.MultiArrayList(entry.Row) = .empty,
    /// The labels of every row, each row's run contiguous (`Row.labels`).
    label_rows: std.ArrayList(entry.LabelRow) = .empty,
    /// The notes of every row, each row's run contiguous (`Row.notes`).
    note_rows: std.ArrayList(entry.NoteRow) = .empty,
    /// The lint levels; the caller copies its own in (`bag.levels = lint`).
    levels: Levels = .empty,
    /// Every file of the compilation, in the order the preprocessor opened
    /// them; `FileId` indexes it. Here and not in `map`, because a
    /// preprocessor span names its file directly while every other span
    /// reaches its file through `map`. The texts are borrowed, not pooled:
    /// a compilation that reports nothing must not copy its sources.
    files: std.ArrayList(location.File) = .empty,
    /// Preprocessed offset to file. Empty until the preprocessor splices
    /// something, which is exactly when offsets are source offsets.
    map: location.SourceMap = .empty,
    /// After `detach`: the one gpa buffer every file name, text, original
    /// and macro name points into. Empty before.
    detached_bytes: []u8 = &.{},
    /// After `detach`: the one gpa buffer every `File.to_src` points into.
    detached_marks: []location.StripMark = &.{},

    /// Dropped because the bag was full: reported as a trailer, so a
    /// truncated run never looks complete.
    suppressed: u32 = 0,
    /// Dropped because a row with the same code, file and start was present.
    deduped: u32 = 0,
    /// Diagnostics collected as errors, kept or dropped at the cap (not
    /// deduped or allowed ones); a `--deny`ed warning counts here.
    err_count: u32 = 0,
    /// Diagnostics collected as warnings, kept or dropped at the cap.
    warn_count: u32 = 0,
    /// The `.run` errors among `err_count`: raised after the design compiled,
    /// so `render`'s "could not compile" summary leaves them out.
    run_err_count: u32 = 0,

    /// Returns an empty bag. Allocates nothing: every table grows in `arena`
    /// on first use, so a compilation that reports nothing costs no memory.
    pub fn init(arena: Allocator) Bag {
        const bag: Bag = .{ .arena = arena };
        assert(bag.rows.len == 0);
        assert(bag.strings.items.len == 0);
        return bag;
    }

    /// Starts one diagnostic; nothing is kept until `Builder.emit`. A code at
    /// `allow`, or a full bag, gets a builder that formats nothing: `emit`
    /// would drop it anyway. The builder borrows the bag.
    pub fn build(self: *Bag, stage: entry.Stage, c: Code, span: Span) Builder {
        assert(self.rows.len <= max_entries);
        const dropped = self.levels.get(c) == .allow or self.rows.len == max_entries;
        return .{ .bag = self, .stage = stage, .code = c, .span = span, .state = if (dropped) .dropped else .open };
    }

    /// Reports one diagnostic with no labels and no notes in one call.
    /// Fails only when the pool or the rows cannot grow; nothing is kept then.
    pub fn add(
        self: *Bag,
        stage: entry.Stage,
        c: Code,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        var b = self.build(stage, c, span);
        b.msg(fmt, args);
        return b.emit();
    }

    /// Formats one string into the pool and returns its handle; the first
    /// string also writes the sentinel. `Builder` calls it for every part.
    /// Invalidates `str` slices of a detached bag if the pool must grow.
    pub fn intern(self: *Bag, comptime fmt: []const u8, args: anytype) Allocator.Error!String {
        if (self.strings.items.len == 0) try self.strings.append(self.arena, 0);
        const start = self.strings.items.len;
        assert(start < std.math.maxInt(u32));
        errdefer self.strings.shrinkRetainingCapacity(start);
        try self.strings.print(self.arena, fmt, args);
        try self.strings.append(self.arena, 0);
        assert(self.strings.items[start - 1] == 0);
        return @fromBackingInt(@as(u32, @intCast(start)));
    }

    /// Returns the bytes of `s`; `.none` decodes to the empty string, which
    /// is also what the renderer wants. The slice stops at the first NUL, so
    /// text formatted with an embedded NUL reads back truncated. It lives as
    /// long as the arena, or after `detach` until the pool next grows.
    pub fn str(self: *const Bag, s: String) []const u8 {
        if (s == .none) return "";
        const bytes = self.strings.items;
        const start: usize = @backingInt(s);
        assert(start < bytes.len);
        assert(bytes[start - 1] == 0);
        const end = std.mem.findScalarPos(u8, bytes, start, 0) orelse bytes.len;
        return bytes[start..end];
    }

    /// Returns the rows kept, at most `max_entries`; dropped diagnostics are
    /// in `suppressed`/`deduped`, not here.
    pub fn count(self: *const Bag) usize {
        assert(self.rows.len <= max_entries);
        return self.rows.len;
    }

    /// Returns true when no row is kept. An empty bag can still have
    /// `suppressed` or `deduped` counts, which `render` reports.
    pub fn isEmpty(self: *const Bag) bool {
        return self.count() == 0;
    }

    /// Returns true when anything at `deny`/`forbid` landed, even past the
    /// cap. This, not `count()`, decides whether the compilation failed: a
    /// bag of warnings is a successful compilation.
    pub fn failed(self: *const Bag) bool {
        assert(self.run_err_count <= self.err_count);
        return self.err_count != 0;
    }

    /// Returns true when a diagnostic with code `c` would be collected at
    /// all, so a stage can skip building an expensive message for an allowed
    /// lint.
    pub fn enabled(self: *const Bag, c: Code) bool {
        return self.levels.get(c) != .allow;
    }

    /// Returns the `i`'th diagnostic, in source order once `sort` has run.
    /// Its strings are `str` slices, with their lifetime.
    /// Asserts that `i < count()`.
    pub fn at(self: *const Bag, i: usize) entry.Entry {
        assert(i < self.rows.len);
        const row = self.rows.get(i);
        assert(row.labels.len <= entry.max_children);
        return .{
            .index = @intCast(i),
            .code = row.code,
            .severity = row.severity,
            .stage = row.stage,
            .span = row.span,
            .file = row.file,
            .message = self.str(row.message),
            .point = self.str(row.point),
            .label_count = row.labels.len,
            .note_count = row.notes.len,
        };
    }

    /// Returns `e`'s secondary labels, decoded into `buf`; the slice is valid
    /// while `buf` and the bag are. Asserts that `e` came from this bag's
    /// `at` since the last `sort`.
    pub fn labels(self: *const Bag, e: entry.Entry, buf: *[entry.max_children]entry.Label) []const entry.Label {
        const run = self.rows.items(.labels)[e.index];
        assert(run.len == e.label_count);
        const rows = self.label_rows.items[run.start..][0..run.len];
        for (rows, buf[0..run.len]) |r, *out| out.* = .{ .span = r.span, .text = self.str(r.text) };
        return buf[0..run.len];
    }

    /// Returns `e`'s notes and help lines, decoded into `buf` as `labels`
    /// does, with the same precondition.
    pub fn notes(self: *const Bag, e: entry.Entry, buf: *[entry.max_children]entry.Note) []const entry.Note {
        const run = self.rows.items(.notes)[e.index];
        assert(run.len == e.note_count);
        const rows = self.note_rows.items[run.start..][0..run.len];
        for (rows, buf[0..run.len]) |r, *out| out.* = .{
            .kind = r.kind,
            .text = self.str(r.text),
            .fix = if (r.fix_replacement == .none) null else .{
                .span = r.fix_span,
                .replacement = self.str(r.fix_replacement),
            },
        };
        return buf[0..run.len];
    }

    /// Registers a file and returns its id. `name` and `text` are borrowed:
    /// they must outlive the bag or its `detach`. The first file registered
    /// is `.root`, so the preprocessor opens the top-level unit first.
    pub fn addFile(self: *Bag, name: []const u8, text: []const u8) AddFileError!FileId {
        const n = self.files.items.len;
        if (n == location.files_max) return error.TooManyFiles;
        try self.files.append(self.arena, .{ .name = name, .text = text });
        const id: FileId = @fromBackingInt(@as(u16, @intCast(n)));
        assert(id != .none);
        assert(self.files.items.len == n + 1);
        return id;
    }

    /// Registers the one file of a compilation with no include and no macro:
    /// spans index straight into `text`. Fails as `addFile` does.
    pub fn setSingleFile(self: *Bag, name: []const u8, text: []const u8) AddFileError!void {
        _ = try self.addFile(name, text);
        self.map = .empty;
    }

    /// Points a registered file at its comment-stripped bytes, which every
    /// span from here on indexes; the original stays for rendering, and
    /// `marks` maps stripped offsets back into it. A second call for the
    /// same file keeps the first original. `stripped` and `marks` are
    /// borrowed, like `addFile`'s text. An unknown `id` is ignored.
    pub fn setStrippedText(self: *Bag, id: FileId, stripped: []const u8, marks: []const location.StripMark) void {
        const f = self.filePtr(id) orelse return;
        // Only the first strip sees the original; a later one must not
        // replace it with an already-stripped text.
        if (f.raw.len == 0) f.raw = f.text;
        f.text = stripped;
        f.to_src = marks;
    }

    /// Returns the name the file was registered under; `"<source>"` for an
    /// unknown `id`.
    pub fn fileName(self: *const Bag, id: FileId) []const u8 {
        const f = self.fileOf(id) orelse return "<source>";
        return f.name;
    }

    /// Returns the text spans index (comment-stripped once the preprocessor
    /// ran); empty for an unknown `id`.
    pub fn fileText(self: *const Bag, id: FileId) []const u8 {
        const f = self.fileOf(id) orelse return "";
        return f.text;
    }

    /// Returns the file as the user wrote it, comments and all, which is what
    /// rendering shows; `fileText` when nothing was stripped, empty for an
    /// unknown `id`.
    pub fn sourceText(self: *const Bag, id: FileId) []const u8 {
        const f = self.fileOf(id) orelse return "";
        return if (f.raw.len != 0) f.raw else f.text;
    }

    /// Returns the strip marks of `id`, sorted by `out`; empty when nothing
    /// was stripped or `id` is unknown.
    pub fn fileMarks(self: *const Bag, id: FileId) []const location.StripMark {
        const f = self.fileOf(id) orelse return &.{};
        return f.to_src;
    }

    /// Returns the offset in `sourceText(id)` of a span-currency offset in
    /// `fileText(id)`; see `location.toSourceOffset`.
    pub fn toSourceOffset(self: *const Bag, id: FileId, off: u32) u32 {
        return location.toSourceOffset(self.fileMarks(id), off);
    }

    /// Returns where a span really points. A `file` other than `.none` (a
    /// preprocessor diagnostic, whose offset is file-local already) skips the
    /// segment search.
    pub fn locate(self: *const Bag, span: Span, file: FileId) location.SourceMap.Resolved {
        if (file != .none) return .{ .file = file, .offset = span.start, .seg = location.Segment.no_parent };
        return self.map.resolve(span.start);
    }

    /// Sorts the rows into source order (start, then end, then code), so a
    /// run's output is stable whichever stage produced what; equal keys keep
    /// their emission order. Invalidates every `Entry.index` taken before.
    pub fn sort(self: *Bag) void {
        const before = self.rows.len;
        self.rows.sort(SourceOrder{ .spans = self.rows.items(.span), .codes = self.rows.items(.code) });
        assert(self.rows.len == before);
    }

    /// Deep-copies every arena-owned or borrowed byte (rows, children, the
    /// pool, file names and texts, strip marks, macro names) into `gpa`, so
    /// the bag outlives the compilation arena; it then grows in `gpa`, and
    /// the caller releases it with `deinit(gpa)`. On `OutOfMemory` nothing is
    /// allocated and the bag is unchanged, still on its arena. Call it at
    /// most once. Slices read before it still point into the arena. An empty
    /// bag is detached too: codegen may still report after it (E0515), and
    /// that snippet needs the file text.
    pub fn detach(self: *Bag, gpa: Allocator) Allocator.Error!void {
        assert(self.detached_bytes.len == 0);
        assert(self.detached_marks.len == 0);
        // Nine allocations whatever the file and macro count: every borrowed
        // byte goes into ONE buffer and every strip mark into another,
        // instead of one `dupe` per field (2,388 on hisimhv_va).
        var bytes_len: usize = 0;
        var marks_len: usize = 0;
        for (self.files.items) |f| {
            bytes_len += f.name.len + f.text.len + f.raw.len;
            marks_len += f.to_src.len;
        }
        for (self.map.segs) |sg| bytes_len += sg.macro.len;

        const strings = try gpa.dupe(u8, self.strings.items);
        errdefer gpa.free(strings);
        var rows = try self.rows.clone(gpa);
        errdefer rows.deinit(gpa);
        const label_rows = try gpa.dupe(entry.LabelRow, self.label_rows.items);
        errdefer gpa.free(label_rows);
        const note_rows = try gpa.dupe(entry.NoteRow, self.note_rows.items);
        errdefer gpa.free(note_rows);
        const files = try gpa.dupe(location.File, self.files.items);
        errdefer gpa.free(files);
        const segs = try gpa.dupe(location.Segment, self.map.segs);
        errdefer gpa.free(segs);
        const bytes = try gpa.alloc(u8, bytes_len);
        errdefer gpa.free(bytes);
        const marks = try gpa.alloc(location.StripMark, marks_len);

        // Infallible from here: re-point every slice into the two buffers.
        var cursor: usize = 0;
        var mark_cursor: usize = 0;
        for (files) |*f| {
            f.name = copyInto(bytes, &cursor, f.name);
            f.text = copyInto(bytes, &cursor, f.text);
            f.raw = copyInto(bytes, &cursor, f.raw);
            @memcpy(marks[mark_cursor..][0..f.to_src.len], f.to_src);
            f.to_src = marks[mark_cursor..][0..f.to_src.len];
            mark_cursor += f.to_src.len;
        }
        for (segs) |*sg| sg.macro = copyInto(bytes, &cursor, sg.macro);
        assert(cursor == bytes.len);
        assert(mark_cursor == marks.len);

        self.strings = .fromOwnedSlice(strings);
        self.rows = rows;
        self.label_rows = .fromOwnedSlice(label_rows);
        self.note_rows = .fromOwnedSlice(note_rows);
        self.files = .fromOwnedSlice(files);
        self.map = .{ .segs = segs };
        self.detached_bytes = bytes;
        self.detached_marks = marks;
        self.arena = gpa;
    }

    /// Releases a bag that has been through `detach`, with the same `gpa`.
    /// A bag still on its arena is freed with the arena instead. Never frees
    /// `levels`, which owns nothing.
    pub fn deinit(self: *Bag, gpa: Allocator) void {
        gpa.free(self.detached_bytes);
        gpa.free(self.detached_marks);
        gpa.free(self.map.segs);
        self.strings.deinit(gpa);
        self.rows.deinit(gpa);
        self.label_rows.deinit(gpa);
        self.note_rows.deinit(gpa);
        self.files.deinit(gpa);
        self.* = .init(gpa);
        assert(self.isEmpty());
    }

    // ---- private ----

    fn fileOf(self: *const Bag, id: FileId) ?location.File {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return null;
        assert(id != .none);
        return self.files.items[i];
    }

    fn filePtr(self: *Bag, id: FileId) ?*location.File {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return null;
        assert(id != .none);
        return &self.files.items[i];
    }
};

/// `Bag.sort`'s key: start, then end, then code.
const SourceOrder = struct {
    spans: []const Span,
    codes: []const Code,

    pub fn lessThan(ctx: SourceOrder, a: usize, b: usize) bool {
        const x = ctx.spans[a];
        const y = ctx.spans[b];
        if (x.start != y.start) return x.start < y.start;
        if (x.end != y.end) return x.end < y.end;
        return @backingInt(ctx.codes[a]) < @backingInt(ctx.codes[b]);
    }
};

// ---- private ----

fn copyInto(buf: []u8, cursor: *usize, s: []const u8) []const u8 {
    assert(cursor.* + s.len <= buf.len);
    const dst = buf[cursor.*..][0..s.len];
    @memcpy(dst, s);
    cursor.* += s.len;
    return dst;
}
