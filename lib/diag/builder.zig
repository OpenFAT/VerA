//! The builder: one diagnostic's parts in (headline, caret text, labels,
//! notes, fixes), one committed `Row` and its children out, after the lint
//! level, the dedupe key and the cap have had their say.
//!
//! Cites no LRM clause: the stage that reports a diagnostic cites it.
//!
//! Contents:
//! - `pub const Builder = struct`, `State`, with `msg`, `inFile`, `point`, `label`,
//!   `note`, `help`, `suggest`, `suggestHere`, `emit`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Code = @import("code.zig").Code;
const level = @import("level.zig");
const entry = @import("entry.zig");
const location = @import("location.zig");
const bag_file = @import("bag.zig");
const Bag = bag_file.Bag;
const Span = location.Span;
const String = entry.String;

/// Accumulates one diagnostic's parts, then commits them with `emit`, the
/// only fallible call: an allocation failure in a part is latched and
/// reported there. Text is interned into the bag's pool as it is built, so a
/// builder borrows its bag, must not outlive it, and every part invalidates
/// `Bag.str` slices as the pool growing does. Labels past `max_children` are
/// dropped, and so are notes, helps and suggestions, which share their slots.
pub const Builder = struct {
    // ponytail: no rollback. A builder `Bag.build` knows is dropped interns
    // nothing; one that `emit` dedupes, or that meets the cap after `build`,
    // leaves its strings in the pool. A mark-and-truncate in `emit`, guarded
    // against interleaved builders, if that waste ever shows up.
    bag: *Bag,
    stage: entry.Stage,
    code: Code,
    span: Span,
    file: location.FileId = .none,
    message: String = .none,
    point_text: String = .none,
    state: State,
    // SAFETY: only the first `label_count`/`note_count` rows are ever read.
    label_rows: [entry.max_children]entry.LabelRow = undefined,
    label_count: u8 = 0,
    note_rows: [entry.max_children]entry.NoteRow = undefined,
    note_count: u8 = 0,

    /// Whether the parts still format.
    pub const State = enum(u8) {
        /// Parts are interned as they come.
        open,
        /// `Bag.build` knew `emit` would drop it: every part is skipped.
        dropped,
        /// A part could not grow the pool: `emit` returns `OutOfMemory`.
        out_of_memory,
    };

    /// Sets the headline printed after `Info.title`.
    pub fn msg(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.message = self.text(fmt, args) orelse return;
    }

    /// Marks this diagnostic's offsets as inside `id`'s own text, not inside
    /// the preprocessed output: the preprocessor's case only, which fails
    /// before an output exists. Asserts that `id` is not `.none`.
    pub fn inFile(self: *Builder, id: location.FileId) void {
        assert(id != .none);
        self.file = id;
        assert(self.file != .none);
    }

    /// Sets the short text beside the PRIMARY caret. Use it when the caret
    /// must say something the headline does not; otherwise leave it unset.
    pub fn point(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.point_text = self.text(fmt, args) orelse return;
    }

    /// Adds a secondary span with its own text; dropped past `max_children`.
    pub fn label(self: *Builder, span: Span, comptime fmt: []const u8, args: anytype) void {
        assert(self.label_count <= entry.max_children);
        if (self.label_count == entry.max_children) return;
        const t = self.text(fmt, args) orelse return;
        self.label_rows[self.label_count] = .{ .span = span, .text = t };
        self.label_count += 1;
    }

    /// Adds a `= note:` line: context, not an instruction.
    pub fn note(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.note, null, fmt, args);
    }

    /// Adds a `= help:` line: what the user should change.
    pub fn help(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.help, null, fmt, args);
    }

    /// Adds a help line with a machine-applicable rewrite; the renderer shows
    /// the patched line under the help text.
    pub fn suggest(self: *Builder, fix: entry.Fix, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.help, fix, fmt, args);
    }

    /// Adds a help line that rewrites the primary span, the did-you-mean
    /// shape of every "unknown name" diagnostic.
    pub fn suggestHere(self: *Builder, replacement: []const u8) void {
        self.suggest(.{ .span = self.span, .replacement = replacement }, "did you mean `{s}`?", .{replacement});
    }

    /// Commits the diagnostic. An allowed code is dropped uncounted; a
    /// duplicate (same code, file and start as a kept row) counts in
    /// `deduped`; anything else counts in `err_count` or `warn_count`, and is
    /// kept unless the bag holds `max_entries` rows, when it counts in
    /// `suppressed`. Returns `OutOfMemory` if a part failed to allocate or
    /// the rows cannot grow; nothing is kept and nothing counted then.
    pub fn emit(self: *Builder) Allocator.Error!void {
        if (self.state == .out_of_memory) return error.OutOfMemory;
        const bag = self.bag;
        assert(bag.rows.len <= bag_file.max_entries);

        const severity: level.Severity = switch (bag.levels.get(self.code)) {
            .allow => return,
            .warn => level.severityOf(self.code),
            // `--deny=W0650` promotes the warning to a hard error.
            .deny, .forbid => .err,
        };

        // `file` is in the key because a preprocessor span is file-local.
        // ponytail: a linear scan, bounded by `max_entries`.
        const codes = bag.rows.items(.code);
        const spans = bag.rows.items(.span);
        const files = bag.rows.items(.file);
        for (codes, spans, files) |c, s, f| {
            if (c == self.code and s.start == self.span.start and f == self.file) {
                bag.deduped += 1;
                return;
            }
        }

        // Room first, so the counters and the rows move together or not at
        // all. The cap bounds the rows: the first emit reserves every one.
        const full = bag.rows.len == bag_file.max_entries;
        if (!full) {
            if (bag.rows.capacity < bag_file.max_entries) try bag.rows.setCapacity(bag.arena, bag_file.max_entries);
            try bag.label_rows.ensureUnusedCapacity(bag.arena, self.label_count);
            try bag.note_rows.ensureUnusedCapacity(bag.arena, self.note_count);
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
        if (full) {
            bag.suppressed += 1;
            return;
        }
        self.commit(severity);
    }

    // ---- private ----

    /// Interns one formatted part, or returns null when the diagnostic is
    /// dropped or the pool cannot grow (latching `out_of_memory`).
    fn text(self: *Builder, comptime fmt: []const u8, args: anytype) ?String {
        if (self.state != .open) return null;
        const s = self.bag.intern(fmt, args) catch {
            self.state = .out_of_memory;
            return null;
        };
        assert(s != .none);
        return s;
    }

    fn pushNote(self: *Builder, kind: entry.Note.Kind, fix: ?entry.Fix, comptime fmt: []const u8, args: anytype) void {
        assert(self.note_count <= entry.max_children);
        if (self.note_count == entry.max_children) return;
        const t = self.text(fmt, args) orelse return;
        // Interned, never `.none`, even for an empty replacement: `.none` is
        // what says "no fix", and a fix that replaces with nothing deletes.
        const replacement: String = if (fix) |f| self.text("{s}", .{f.replacement}) orelse return else .none;
        self.note_rows[self.note_count] = .{
            .kind = kind,
            .text = t,
            .fix_replacement = replacement,
            .fix_span = if (fix) |f| f.span else .none,
        };
        self.note_count += 1;
    }

    /// Appends the row and its children into the room `emit` reserved.
    fn commit(self: *const Builder, severity: level.Severity) void {
        const bag = self.bag;
        const rows_before = bag.rows.len;
        const labels: entry.Children = .{ .start = @intCast(bag.label_rows.items.len), .len = self.label_count };
        const notes: entry.Children = .{ .start = @intCast(bag.note_rows.items.len), .len = self.note_count };
        bag.label_rows.appendSliceAssumeCapacity(self.label_rows[0..self.label_count]);
        bag.note_rows.appendSliceAssumeCapacity(self.note_rows[0..self.note_count]);
        bag.rows.appendAssumeCapacity(.{
            .code = self.code,
            .severity = severity,
            .stage = self.stage,
            .file = self.file,
            .span = self.span,
            .message = self.message,
            .point = self.point_text,
            .labels = labels,
            .notes = notes,
        });
        assert(bag.rows.len == rows_before + 1);
        assert(bag.label_rows.items.len <= bag_file.max_entries * entry.max_children);
    }
};

comptime {
    // Every child of a full bag is addressable by `Children.start`.
    assert(bag_file.max_entries * entry.max_children <= std.math.maxInt(u16));
}
