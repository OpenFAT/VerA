//! The bag: every diagnostic of one compilation, collected, deduplicated and
//! sorted. In: `Builder` commits from every stage. Out: an ordered table of
//! `Record` rows whose text lives in one string pool. Cites no LRM clause
//! (the stage that reports a diagnostic cites it).

const std = @import("std");
const diag = @import("root.zig");
const diag_entry = @import("entry.zig");
const diag_location = @import("location.zig");
const Allocator = std.mem.Allocator;
const Code = diag.Code;
const Severity = diag.Severity;
const severityOf = diag.severityOf;
const Levels = diag.Levels;

// ---------------------------------------------------------------------------
// The bag
// ---------------------------------------------------------------------------

/// Stop after this many entries in one run. A single broken expression
/// otherwise reports a cascade that buries the first, real error.
pub const max_entries: u32 = 64;

/// Every diagnostic of one compilation: one `Record` row each, their text in
/// one string pool. Appended to across stages 1–6, then read by the renderer.
pub const Bag = struct {
    /// What every table grows in: the compilation arena until `detach`, the
    /// caller's gpa after it.
    arena: Allocator,
    /// Every diagnostic string, NUL-terminated: headlines, caret text, label
    /// text, note bodies, fix replacements. Byte 0 is a sentinel NUL so that
    /// `String` 0 can mean "none".
    string_bytes: std.ArrayList(u8) = .empty,
    /// One row per diagnostic, in emission order until `sort` reorders it.
    records: std.ArrayList(diag_entry.Record) = .empty,
    /// Copied in by the caller (`bag.levels = opts.lint`), which still owns
    /// it: `deinit` never frees it.
    levels: Levels = .empty,
    /// Every file that took part in the compilation, in the order the
    /// preprocessor opened them. `FileId` indexes this.
    ///
    /// It lives on the Bag rather than inside `SourceMap` because BOTH
    /// provenance paths need it: a lower/parse/proof span is an offset in the
    /// preprocessed text and reaches a file through `map`, while a preprocess
    /// span is ALREADY a file-local offset (the preprocessor fails before an
    /// output text exists) and names its file directly via `Entry.file`.
    ///
    /// NOT IN THE POOL, deliberately. A `File.text` is the whole source —
    /// hundreds of kilobytes for a foundry model — BORROWED from the arena and
    /// re-pointed by `setStrippedText` once comments are stripped. Interning it
    /// into `string_bytes` would copy every byte of every file on the path
    /// where no diagnostic is ever produced, to save one copy in `detach`.
    files: std.ArrayList(diag_location.File) = .empty,
    /// Preprocessed offset → file. Empty until the preprocessor splices
    /// something, which is exactly when it means "offsets are source offsets".
    map: diag_location.SourceMap = .empty,
    /// After `detach`: the one gpa buffer every `files` name, text and
    /// original and every `map` macro name points into. Empty before.
    detached_bytes: []u8 = &.{},
    /// After `detach`: the one gpa buffer every `File.to_src` points into.
    detached_marks: []diag_location.StripMark = &.{},

    /// Dropped because the cap was reached — reported as a trailer so a
    /// truncated run never looks like a complete one.
    suppressed: u32 = 0,
    /// Dropped because an identical (code, file, span.start) was already present.
    deduped: u32 = 0,
    /// Collected diagnostics by rendered severity, kept or dropped at the cap
    /// (not deduped or allowed ones); a `--deny`ed warning counts as an error.
    err_count: u32 = 0,
    warn_count: u32 = 0,
    /// The `.run` errors among `err_count`: raised after the design compiled,
    /// so `render`'s "could not compile" summary leaves them out.
    run_err_count: u32 = 0,

    /// Allocates nothing; every table grows in `arena` on first use, so a
    /// compilation that reports nothing costs no memory here.
    pub fn init(arena: Allocator) Bag {
        return .{ .arena = arena };
    }

    // -- the string pool ----------------------------------------------------

    /// Formats straight into the pool. `Bag.init` is infallible and a
    /// compilation that reports nothing must not allocate, so the first string
    /// written pays for the sentinel NUL.
    fn printString(self: *Bag, comptime fmt: []const u8, args: anytype) Allocator.Error!diag_entry.String {
        if (self.string_bytes.items.len == 0)
            try self.string_bytes.append(self.arena, 0);
        const index: diag_entry.String = @intCast(self.string_bytes.items.len);
        try self.string_bytes.print(self.arena, fmt, args);
        try self.string_bytes.append(self.arena, 0);
        return index;
    }

    /// `String` → bytes. 0 is "none" and decodes to the empty string, which is
    /// also what the renderer wants: an absent `point` and an empty one print
    /// the same. The slice stops at the first NUL, so text formatted with an
    /// embedded NUL reads back truncated. Invalidated when the pool grows (any
    /// later `Builder` part or `add`) on a detached bag; on the arena the old
    /// bytes stay readable until the arena dies.
    pub fn str(self: *const Bag, index: diag_entry.String) []const u8 {
        if (index == 0) return "";
        const bytes = self.string_bytes.items;
        const end = std.mem.findScalarPos(u8, bytes, index, 0) orelse bytes.len;
        return bytes[index..end];
    }

    // -- reading ------------------------------------------------------------

    /// Rows kept, at most `max_entries`; dropped diagnostics are in
    /// `suppressed`/`deduped`, not here.
    pub fn count(self: *const Bag) usize {
        return self.records.items.len;
    }

    /// Returns the i'th diagnostic, in `sort` order once `sort` has run. Its
    /// strings are `str` slices, with their lifetime. Panics in safe builds
    /// when `i >= count()`.
    pub fn at(self: *const Bag, i: usize) diag_entry.Entry {
        const m = self.records.items[i];
        return .{
            .index = @intCast(i),
            .code = m.code,
            .severity = m.severity,
            .stage = m.stage,
            .span = m.span,
            .file = m.file,
            .message = self.str(m.message),
            .point = self.str(m.point),
            .n_labels = m.n_labels,
            .n_notes = m.n_notes,
        };
    }

    /// Returns `e`'s secondary labels, decoded into `buf`; the slice is valid
    /// while `buf` and the bag are. `buf` always fits: `Builder` caps labels at
    /// `max_children`.
    pub fn labels(self: *const Bag, e: diag_entry.Entry, buf: *[diag_entry.max_children]diag_entry.Label) []const diag_entry.Label {
        const m = &self.records.items[e.index];
        for (m.labels[0..m.n_labels], buf[0..m.n_labels]) |r, *out|
            out.* = .{ .span = r.span, .text = self.str(r.text) };
        return buf[0..m.n_labels];
    }

    /// Returns `e`'s notes and help lines, decoded into `buf` as `labels` does.
    pub fn notes(self: *const Bag, e: diag_entry.Entry, buf: *[diag_entry.max_children]diag_entry.Note) []const diag_entry.Note {
        const m = &self.records.items[e.index];
        for (m.notes[0..m.n_notes], buf[0..m.n_notes]) |r, *out| out.* = .{
            .kind = r.kind,
            .text = self.str(r.text),
            .fix = if (r.fix_repl == 0) null else .{ .span = r.fix_span, .replacement = self.str(r.fix_repl) },
        };
        return buf[0..m.n_notes];
    }

    /// Registers a file and returns its id. `name` and `text` are borrowed,
    /// not copied: they must outlive the bag or its `detach`. The first file
    /// registered is `.root`, so the preprocessor must open the top-level
    /// compilation unit before any `include. Panics past 65,536 files
    /// (`FileId` is a u16).
    pub fn addFile(self: *Bag, name: []const u8, text: []const u8) Allocator.Error!diag_location.FileId {
        const id: diag_location.FileId = @fromBackingInt(@as(u16, @intCast(self.files.items.len)));
        try self.files.append(self.arena, .{ .name = name, .text = text });
        return id;
    }

    /// Points a registered file at its comment-stripped bytes, which every span
    /// from here on indexes. The original stays for rendering and `marks` maps
    /// stripped offsets back into it; a second call for the same file keeps
    /// the first original. `stripped` and `marks` are borrowed, like
    /// `addFile`'s text. An unknown `id` is ignored.
    pub fn setStrippedText(self: *Bag, id: diag_location.FileId, stripped: []const u8, marks: []const diag_location.StripMark) void {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return;
        const f = &self.files.items[i];
        // Only the first strip sees the original; a later one must not
        // replace it with an already-stripped text.
        if (f.raw.len == 0) f.raw = f.text;
        f.text = stripped;
        f.to_src = marks;
    }

    /// The name the file was registered under; `"<source>"` for an unknown `id`.
    pub fn fileName(self: *const Bag, id: diag_location.FileId) []const u8 {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return "<source>";
        return self.files.items[i].name;
    }

    /// The text spans index (comment-stripped once the preprocessor ran; see
    /// `File.text`); empty for an unknown `id`.
    pub fn fileText(self: *const Bag, id: diag_location.FileId) []const u8 {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return "";
        return self.files.items[i].text;
    }

    /// What RENDERING shows: the file as the user wrote it, comments and all.
    /// Falls back to `text` for a file nothing was stripped from.
    pub fn sourceText(self: *const Bag, id: diag_location.FileId) []const u8 {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return "";
        const f = self.files.items[i];
        return if (f.raw.len != 0) f.raw else f.text;
    }

    /// The strip marks of `id`, sorted by `out`; empty when nothing was
    /// stripped or `id` is unknown.
    pub fn fileMarks(self: *const Bag, id: diag_location.FileId) []const diag_location.StripMark {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return &.{};
        return self.files.items[i].to_src;
    }

    /// Span-currency (stripped) offset → offset in `sourceText`. Identity when
    /// nothing was stripped from `id`; saturates at `maxInt(u32)`, so an
    /// offset past the text maps past it rather than overflowing.
    pub fn toSourceOffset(self: *const Bag, id: diag_location.FileId, off: u32) u32 {
        const marks = self.fileMarks(id);
        if (marks.len == 0 or off < marks[0].out) return off;
        // Last mark with out <= off; linear from there (see `StripMark`).
        const lo = std.sort.partitionPoint(diag_location.StripMark, marks, off, struct {
            fn f(o: u32, m: diag_location.StripMark) bool {
                return m.out <= o;
            }
        }.f) - 1;
        return marks[lo].src +| (off - marks[lo].out);
    }

    /// The no-include, no-macro case: spans index straight into `text`.
    pub fn setSingleFile(self: *Bag, name: []const u8, text: []const u8) Allocator.Error!void {
        _ = try self.addFile(name, text);
        self.map = .empty;
    }

    /// Where a span really points. `Entry.file` short-circuits the segment
    /// search for a preprocess diagnostic, whose offset is file-local already.
    pub fn locate(self: *const Bag, span: diag_location.Span, file: ?diag_location.FileId) diag_location.SourceMap.Resolved {
        if (file) |f| return .{ .file = f, .offset = span.start, .seg = diag_location.Segment.no_parent };
        return self.map.resolve(span.start);
    }

    /// Did anything at `deny`/`forbid` level land, even past the cap? This,
    /// not `count()`, is what decides whether the compilation failed — a bag
    /// holding only warnings is a successful compilation.
    pub fn failed(self: *const Bag) bool {
        return self.err_count != 0;
    }

    /// No row kept. A bag can be empty and still have `suppressed` or
    /// `deduped` counts, which `render` reports.
    pub fn isEmpty(self: *const Bag) bool {
        return self.records.items.len == 0;
    }

    /// Would a diagnostic with this code be collected at all? Stages call it
    /// to skip building an expensive message for an allowed lint.
    pub fn enabled(self: *const Bag, c: Code) bool {
        return self.levels.get(c) != .allow;
    }

    /// Starts one diagnostic; nothing is kept until `Builder.emit`. A code at
    /// `allow`, or a bag already at `max_entries`, gets a builder that formats
    /// nothing: `emit` would drop it anyway, and rows only ever grow.
    pub fn build(self: *Bag, stage: diag_entry.Stage, c: Code, span: diag_location.Span) Builder {
        const dropped = self.levels.get(c) == .allow or self.records.items.len >= max_entries;
        return .{ .bag = self, .stage = stage, .code = c, .span = span, .dropped = dropped };
    }

    /// The whole diagnostic in one call, for the common case with no labels
    /// and no notes.
    pub fn add(
        self: *Bag,
        stage: diag_entry.Stage,
        c: Code,
        span: diag_location.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        var b = self.build(stage, c, span);
        b.msg(fmt, args);
        return b.emit();
    }

    /// Deep-copies every arena-owned or borrowed byte (rows, string pool, file
    /// names and texts, macro names) into `gpa`, so the bag outlives the
    /// compilation arena. The caller then owns it and releases it with
    /// `deinit(gpa)`. On `OutOfMemory` nothing is allocated and the bag is
    /// unchanged, still on its arena. Call it at most once: a second call
    /// copies again and leaks the first copy. Slices read before it (`str`,
    /// `at`, `fileText`, ...) still point into the arena.
    ///
    /// An empty bag is detached too: codegen runs after this and may still
    /// report (E0515), and its snippet needs the file text.
    pub fn detach(self: *Bag, gpa: Allocator) Allocator.Error!void {
        // Six allocations whatever the file and macro count: every borrowed
        // byte (file names, texts, originals, macro names) goes into ONE
        // buffer and every strip mark into another, instead of one `dupe`
        // per file field and per macro segment (2,388 on hisimhv_va).
        var n_bytes: usize = 0;
        var n_marks: usize = 0;
        for (self.files.items) |f| {
            n_bytes += f.name.len + f.text.len + f.raw.len;
            n_marks += f.to_src.len;
        }
        for (self.map.segs) |sg| n_bytes += sg.macro.len;

        const string_bytes = try gpa.dupe(u8, self.string_bytes.items);
        errdefer gpa.free(string_bytes);
        const records = try gpa.dupe(diag_entry.Record, self.records.items);
        errdefer gpa.free(records);
        const files = try gpa.dupe(diag_location.File, self.files.items);
        errdefer gpa.free(files);
        const segs = try gpa.dupe(diag_location.Segment, self.map.segs);
        errdefer gpa.free(segs);
        const bytes = try gpa.alloc(u8, n_bytes);
        errdefer gpa.free(bytes);
        const marks = try gpa.alloc(diag_location.StripMark, n_marks);

        // Infallible from here: re-point every slice into the two buffers.
        var cursor: usize = 0;
        var at_mark: usize = 0;
        for (files) |*f| {
            f.name = copyInto(bytes, &cursor, f.name);
            f.text = copyInto(bytes, &cursor, f.text);
            f.raw = copyInto(bytes, &cursor, f.raw);
            @memcpy(marks[at_mark..][0..f.to_src.len], f.to_src);
            f.to_src = marks[at_mark..][0..f.to_src.len];
            at_mark += f.to_src.len;
        }
        for (segs) |*sg| sg.macro = copyInto(bytes, &cursor, sg.macro);
        std.debug.assert(cursor == bytes.len and at_mark == marks.len);

        self.string_bytes = .fromOwnedSlice(string_bytes);
        self.records = .fromOwnedSlice(records);
        self.files = .fromOwnedSlice(files);
        self.map = .{ .segs = segs };
        self.detached_bytes = bytes;
        self.detached_marks = marks;
        self.arena = gpa;
    }

    fn copyInto(buf: []u8, cursor: *usize, s: []const u8) []const u8 {
        const dst = buf[cursor.*..][0..s.len];
        @memcpy(dst, s);
        cursor.* += s.len;
        return dst;
    }

    /// Releases a bag that has been through `detach`. Precondition: detached;
    /// a bag still on its arena is freed with the arena instead.
    pub fn deinit(self: *Bag, gpa: Allocator) void {
        gpa.free(self.detached_bytes);
        gpa.free(self.detached_marks);
        gpa.free(self.map.segs);
        self.string_bytes.deinit(gpa);
        self.records.deinit(gpa);
        self.files.deinit(gpa);
        // NOT `levels`: it is CONFIGURATION the caller owns and copied in
        // (`bag.levels = opts.lint`). Freeing it here double-frees the
        // caller's list the moment it deinits its own.
        self.* = .{ .arena = gpa };
    }

    /// Source order, then code, so a run's output is stable and diffable no
    /// matter which stage produced what. Stages already run in order, but a
    /// proof error can precede a lower error in the text. Invalidates every
    /// `Entry.index` taken before it.
    pub fn sort(self: *Bag) void {
        std.mem.sort(diag_entry.Record, self.records.items, {}, lessThan);
    }

    fn lessThan(_: void, x: diag_entry.Record, y: diag_entry.Record) bool {
        if (x.span.start != y.span.start) return x.span.start < y.span.start;
        if (x.span.end != y.span.end) return x.span.end < y.span.end;
        return @backingInt(x.code) < @backingInt(y.code);
    }
};

/// Accumulates one diagnostic's parts, then commits with `emit`.
///
/// Methods return void: an allocation failure is latched in `oom` and reported
/// by `emit`, the only fallible call. Text is interned into the bag's pool as
/// it is built, so a builder borrows its bag and must not outlive it, and
/// every part invalidates `Bag.str` slices as the pool growing does. Labels
/// and notes beyond `max_children` are dropped.
pub const Builder = struct {
    // ponytail: no rollback index. A diagnostic `build` already knows is
    // dropped writes nothing; one `emit` dedupes, or that reaches the cap after
    // its `build`, leaves its strings in the pool. Add a mark-and-truncate in
    // `emit`, guarded against interleaved builders, if that waste shows up.
    bag: *Bag,
    stage: diag_entry.Stage,
    code: Code,
    span: diag_location.Span,
    file: ?diag_location.FileId = null,
    message: diag_entry.String = 0,
    point_text: diag_entry.String = 0,
    labels: [diag_entry.max_children]diag_entry.LabelRec = undefined,
    n_labels: u8 = 0,
    notes: [diag_entry.max_children]diag_entry.NoteRec = undefined,
    n_notes: u8 = 0,
    oom: bool = false,
    /// Set by `Bag.build` when `emit` is certain to drop this diagnostic; every
    /// part is then skipped unformatted.
    dropped: bool = false,

    /// Interns one formatted part, or returns null when the diagnostic is
    /// dropped or the pool cannot grow (latching `oom`).
    fn text(self: *Builder, comptime fmt: []const u8, args: anytype) ?diag_entry.String {
        if (self.dropped) return null;
        return self.bag.printString(fmt, args) catch {
            self.oom = true;
            return null;
        };
    }

    /// Sets the headline printed after `Info.title`.
    pub fn msg(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.message = self.text(fmt, args) orelse return;
    }

    /// Preprocessor only: this diagnostic's offsets are inside `id`'s own
    /// text, not inside the preprocessed output. See `Entry.file`.
    pub fn inFile(self: *Builder, id: diag_location.FileId) void {
        self.file = id;
    }

    /// Short text beside the PRIMARY caret. Use it when the caret needs to say
    /// something the headline does not — otherwise leave it unset.
    pub fn point(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.point_text = self.text(fmt, args) orelse return;
    }

    /// Adds a secondary span with its own text. Dropped past `max_children`.
    pub fn label(self: *Builder, span: diag_location.Span, comptime fmt: []const u8, args: anytype) void {
        if (self.n_labels == self.labels.len) return;
        const t = self.text(fmt, args) orelse return;
        self.labels[self.n_labels] = .{ .span = span, .text = t };
        self.n_labels += 1;
    }

    /// Adds a `= note:` line: context, not an instruction. Notes, helps and
    /// suggestions share `max_children` slots; later ones are dropped.
    pub fn note(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.note, null, fmt, args);
    }

    /// Adds a `= help:` line: what the user should change.
    pub fn help(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.help, null, fmt, args);
    }

    /// Adds a help line with a machine-applicable rewrite. The renderer shows the
    /// patched line under the help text.
    pub fn suggest(
        self: *Builder,
        fix: diag_entry.Fix,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.pushNote(.help, fix, fmt, args);
    }

    /// Adds a help line that rewrites the primary span, the did-you-mean shape
    /// of every "unknown name" diagnostic.
    pub fn suggestHere(self: *Builder, replacement: []const u8) void {
        self.suggest(
            .{ .span = self.span, .replacement = replacement },
            "did you mean `{s}`?",
            .{replacement},
        );
    }

    fn pushNote(
        self: *Builder,
        kind: diag_entry.Note.Kind,
        fix: ?diag_entry.Fix,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (self.n_notes == self.notes.len) return;
        const t = self.text(fmt, args) orelse return;
        // Interned, not 0, even for an empty replacement: 0 is what says
        // "no fix", and a fix that replaces a span with nothing is a deletion.
        const repl: diag_entry.String = if (fix) |f| self.text("{s}", .{f.replacement}) orelse return else 0;
        self.notes[self.n_notes] = .{
            .kind = kind,
            .text = t,
            .fix_repl = repl,
            .fix_span = if (fix) |f| f.span else .none,
        };
        self.n_notes += 1;
    }

    /// Commits the diagnostic. Honours the lint level, the dedupe set and the
    /// cap; a dropped diagnostic is counted, never silent. Returns
    /// `OutOfMemory` if any earlier builder call failed to allocate.
    pub fn emit(self: *Builder) Allocator.Error!void {
        if (self.oom) return error.OutOfMemory;
        const bag = self.bag;

        const severity: Severity = switch (bag.levels.get(self.code)) {
            .allow => return,
            .warn => severityOf(self.code),
            // `--deny=W0650` promotes the warning to a hard error.
            .deny, .forbid => .err,
        };

        // `file` is in the key because a preprocessor span is file-local.
        // ponytail: linear scan, bounded by `max_entries`.
        for (bag.records.items) |m| {
            if (m.code == self.code and m.span.start == self.span.start and m.file == self.file) {
                bag.deduped += 1;
                return;
            }
        }

        // Counted before the cap: an error the cap drops still fails the
        // compilation and still counts in the summary.
        switch (severity) {
            .err => {
                bag.err_count += 1;
                if (self.stage == .run) bag.run_err_count += 1;
            },
            .warning => bag.warn_count += 1,
        }
        if (bag.records.items.len >= max_entries) {
            bag.suppressed += 1;
            return;
        }

        // The cap above bounds the rows, so the first one reserves them all
        // at once instead of growing through copies the arena keeps. A no-op
        // after that; after `detach` (an exact-size slice) it regrows once.
        try bag.records.ensureTotalCapacityPrecise(bag.arena, max_entries);
        bag.records.appendAssumeCapacity(.{
            .code = self.code,
            .severity = severity,
            .stage = self.stage,
            .file = self.file,
            .span = self.span,
            .message = self.message,
            .point = self.point_text,
            .n_labels = self.n_labels,
            .n_notes = self.n_notes,
            .labels = self.labels,
            .notes = self.notes,
        });
    }
};
