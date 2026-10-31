//! Rendering: a bag in, terminal text with source snippets out (rustc's
//! layout), and a code in, its `--explain` entry out.
//!
//! Cites no LRM clause: the output format is VerA's own. Goldens and the
//! fixture suites compare this text byte for byte.
//!
//! Contents:
//! - `pub const Palette = struct`, `off`, `on`
//! - `pub const RenderOptions = struct { palette, explain_hint, summary }`
//! - `pub const RenderError = std.Io.Writer.Error || Allocator.Error`
//! - `pub fn render(bag: *Bag, w: *std.Io.Writer, opts: RenderOptions) RenderError!void`
//! - `pub fn explain(c: Code, w: *std.Io.Writer, palette: Palette) std.Io.Writer.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const code = @import("code.zig");
const Severity = @import("level.zig").Severity;
const entry = @import("entry.zig");
const location = @import("location.zig");
const bag_file = @import("bag.zig");
const Bag = bag_file.Bag;
const Code = code.Code;
const FileId = location.FileId;
const Span = location.Span;

/// SGR escapes, or all empty when colour is off, so coloured and plain
/// output share one code path and cannot drift apart.
pub const Palette = struct {
    reset: []const u8 = "",
    bold: []const u8 = "",
    err: []const u8 = "",
    warn: []const u8 = "",
    gutter: []const u8 = "",
    note: []const u8 = "",
    help: []const u8 = "",
    good: []const u8 = "",

    /// Plain text, the default: what goldens and the test suites compare.
    pub const off: Palette = .{};

    /// ANSI SGR colours, rustc's scheme.
    pub const on: Palette = .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .err = "\x1b[1;31m", // Bold red.
        .warn = "\x1b[1;33m", // Bold yellow.
        .gutter = "\x1b[1;34m", // Bold blue.
        .note = "\x1b[1;36m", // Bold cyan.
        .help = "\x1b[1;36m",
        .good = "\x1b[1;32m", // Bold green: suggested insertions.
    };

    fn forSeverity(self: Palette, s: Severity) []const u8 {
        return switch (s) {
            .err => self.err,
            .warning => self.warn,
        };
    }
};

/// What `render` draws besides each diagnostic's headline and location.
pub const RenderOptions = struct {
    palette: Palette = .off,
    /// Print `= help: run vera --explain EXXXX` after the first diagnostic
    /// carrying each code.
    explain_hint: bool = true,
    /// Print the `N error(s), M warning(s)` trailer.
    summary: bool = true,
};

/// Every way `render` fails: the writer's error, or the line-index scratch
/// running out. Whatever was written before the failure stays written.
pub const RenderError = Writer.Error || Allocator.Error;

/// Tabs are expanded to this many spaces before a snippet is drawn, so a
/// caret lands under the character it means (as rustc does).
const tab_width = 4;

/// One span, resolved all the way to something printable.
const Placed = struct {
    file: FileId,
    /// 1-based line in the ORIGINAL file.
    line: u32,
    /// 0-based display column.
    col: u32,
    /// Display width of the underline, at least 1.
    width: u32,
    text: []const u8,
    primary: bool,
};

/// The state one `render` call shares between its steps.
const Pass = struct {
    bag: *const Bag,
    scratch: Allocator,
    lines: location.LineCache,
    w: *Writer,
    p: Palette,

    /// The index of `file`'s ORIGINAL text: everything derived from it is
    /// shown to the user, who recognises what they wrote. Offsets go through
    /// `toSourceOffset` before they meet it.
    fn lineIndex(pass: Pass, file: FileId) Allocator.Error!location.LineIndex {
        return pass.lines.index(pass.scratch, file, pass.bag.sourceText(file));
    }
};

const spaces_pad: [24]u8 = @splat(' ');

/// Renders `bag` to `w`: one block per kept diagnostic, in source order (the
/// bag is sorted first, which invalidates every earlier `Entry.index`), then
/// the cap trailer and the summary. A span is drawn on its first line only,
/// clamped to that line, even one that starts past the line's end; a label
/// in another file than the primary's gets its own `::: file:line:col`
/// header. Line-index scratch lives in `bag.arena` and is freed on return.
pub fn render(bag: *Bag, w: *Writer, opts: RenderOptions) RenderError!void {
    if (bag.isEmpty() and bag.suppressed == 0) return;
    bag.sort();
    assert(bag.run_err_count <= bag.err_count);

    // Freed here rather than left on `bag.arena`: after `detach` that arena
    // IS the caller's gpa, and leaving it would leak on every render.
    var scratch_state = std.heap.ArenaAllocator.init(bag.arena);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const pass: Pass = .{
        .bag = bag,
        .scratch = scratch,
        .lines = try .init(scratch, bag.files.items.len),
        .w = w,
        .p = opts.palette,
    };

    var explained: std.EnumSet(Code) = .empty;
    for (0..bag.count()) |i| {
        const e = bag.at(i);
        const gutter = try renderOne(pass, e);
        if (opts.explain_hint and !explained.contains(e.code)) {
            explained.insert(e.code);
            try w.print("{s}{s} ={s} {s}help{s}: run `vera --explain {s}` for a detailed explanation\n", .{
                spaces(gutter), pass.p.gutter, pass.p.reset, pass.p.help, pass.p.reset, e.code.name(),
            });
        }
        try w.writeByte('\n');
    }
    try renderTrailer(pass, opts.summary);
}

/// Writes the `--explain` entry of `c`: code, title, LRM citation, and
/// `Info.explain` verbatim.
pub fn explain(c: Code, w: *Writer, palette: Palette) Writer.Error!void {
    const meta = code.info(c);
    assert(meta.title.len > 0);
    assert(meta.explain.len > 0);
    try w.print("{s}{s}{s}: {s}{s}{s}\n", .{
        palette.bold, c.name(), palette.reset, palette.bold, meta.title, palette.reset,
    });
    if (meta.lrm.len != 0) {
        try w.print("{s}LRM {s}{s}{s}\n", .{ palette.note, meta.annexPrefix(), meta.lrm, palette.reset });
    }
    try w.print("\n{s}\n", .{meta.explain});
}

// ---- private ----

/// Writes the headline, location, snippet, citation and notes of one
/// diagnostic, and returns the gutter width it drew them with; the
/// `--explain` hint and the blank line after it are the caller's.
fn renderOne(pass: Pass, e: entry.Entry) RenderError!u32 {
    const p = pass.p;
    const w = pass.w;
    const meta = code.info(e.code);

    // `error[E0313]: unknown variable: <message>`
    try w.print("{s}{s}[{s}]{s}{s}: {s}{s}", .{
        p.forSeverity(e.severity), e.severity.word(), e.code.name(), p.reset,
        p.bold,                    meta.title,        p.reset,
    });
    if (e.message.len != 0) try w.print(": {s}", .{e.message});
    try w.writeByte('\n');

    // `  --> file.va:12:5`, then the snippet, gutter as wide as its widest line.
    var gutter: u32 = 1;
    if (try place(pass, e.span, e.file, e.point, true)) |primary| {
        gutter = digits(primary.line);
        try w.print("{s}{s}-->{s} {s}:{d}:{d}\n", .{
            spaces(gutter), p.gutter, p.reset, pass.bag.fileName(primary.file), primary.line, primary.col + 1,
        });
        // SAFETY: the first `n` are written before `placed` is sliced.
        var placed_buf: [entry.max_children + 1]Placed = undefined;
        placed_buf[0] = primary;
        var n: usize = 1;
        // SAFETY: `labels` writes the slots it returns.
        var label_buf: [entry.max_children]entry.Label = undefined;
        for (pass.bag.labels(e, &label_buf)) |l| {
            const q = try place(pass, l.span, e.file, l.text, false) orelse continue;
            placed_buf[n] = q;
            n += 1;
        }
        const placed = placed_buf[0..n];
        for (placed) |q| gutter = @max(gutter, digits(q.line));
        try renderSnippet(pass, placed, e.severity, gutter);
    }

    // The rule this diagnostic enforces.
    if (meta.lrm.len != 0) {
        try w.print("{s}{s} ={s} {s}note{s}: LRM {s}{s}\n", .{
            spaces(gutter),     p.gutter, p.reset, p.note, p.reset,
            meta.annexPrefix(), meta.lrm,
        });
    }

    // SAFETY: `notes` writes the slots it returns.
    var note_buf: [entry.max_children]entry.Note = undefined;
    for (pass.bag.notes(e, &note_buf)) |n| {
        const colour = switch (n.kind) {
            .note => p.note,
            .help => p.help,
        };
        try w.print("{s}{s} ={s} {s}{s}{s}: {s}\n", .{
            spaces(gutter), p.gutter, p.reset, colour, @tagName(n.kind), p.reset, n.text,
        });
        if (n.fix) |fix| try renderFix(pass, fix, e.file, gutter);
    }
    assert(gutter >= 1);
    return gutter;
}

/// Resolves `span` to a file line and display columns, or null when there is
/// no span or no text to show it in.
fn place(pass: Pass, span: Span, file: FileId, text: []const u8, primary: bool) Allocator.Error!?Placed {
    if (span.isNone()) return null;
    const bag = pass.bag;
    const r = bag.locate(span, file);
    const file_text = bag.sourceText(r.file);
    if (file_text.len == 0) return null;
    const index = try pass.lineIndex(r.file);

    // `r.offset` is in span currency, the comment-STRIPPED text; from here
    // on everything is measured in the ORIGINAL file. Both ends map, so a
    // span that straddles a stripped comment widens to cover it rather than
    // underlining the wrong bytes.
    const src_off = bag.toSourceOffset(r.file, r.offset);
    const src_end = @max(src_off, bag.toSourceOffset(r.file, r.offset +| span.len()));
    const loc = index.loc(src_off);
    assert(loc.line >= 1);
    assert(loc.col >= 1);
    const line_text = index.lineText(file_text, loc.line);
    const start_col = displayCol(line_text, loc.col - 1);

    // A span past its line's end is clamped: an underline may not wrap, and
    // the first line is the informative one. One that STARTS past its line's
    // text (the '\n' of a "\r\n", or past the end of the file) holds its end
    // at the start, so the caret sits just after the line, one column wide.
    const line_end = (src_off - (loc.col - 1)) + @as(u32, @intCast(line_text.len));
    const clamped = @max(src_off, @min(src_end, line_end));
    const end_col = displayCol(line_text, clamped - src_off + (loc.col - 1));
    return .{
        .file = r.file,
        .line = loc.line,
        .col = start_col,
        .width = @max(1, end_col -| start_col),
        .text = text,
        .primary = primary,
    };
}

/// The ` 12 | source text` / `    | ^^^ label` block. Placed spans are
/// grouped by line; a gap between printed lines becomes `...`, like rustc.
fn renderSnippet(pass: Pass, placed: []Placed, severity: Severity, gutter: u32) RenderError!void {
    assert(placed.len > 0);
    assert(placed[0].primary);
    const p = pass.p;
    const w = pass.w;
    // The primary's file first, under the `-->` line; any other file after,
    // in id order. Within a file: line, then column. Stable, so spans at one
    // position keep the primary-then-labels order.
    const home = placed[0].file;
    std.mem.sort(Placed, placed, home, snippetOrder);

    try w.print("{s}{s} |{s}\n", .{ spaces(gutter), p.gutter, p.reset });
    var i: usize = 0;
    var prev_line: u32 = 0;
    var prev_file = home;
    while (i < placed.len) {
        const line = placed[i].line;
        const file = placed[i].file;
        var j = i + 1;
        while (j < placed.len and placed[j].line == line and placed[j].file == file) j += 1;

        if (file != prev_file) {
            // A label in another file: rustc's `:::` header, aligned with the
            // `-->` line, so its line is never read as the primary file's.
            try w.print("{s}{s} |{s}\n", .{ spaces(gutter), p.gutter, p.reset });
            try w.print("{s}{s}:::{s} {s}:{d}:{d}\n", .{
                spaces(gutter), p.gutter, p.reset, pass.bag.fileName(file), line, placed[i].col + 1,
            });
            try w.print("{s}{s} |{s}\n", .{ spaces(gutter), p.gutter, p.reset });
            prev_file = file;
            prev_line = 0;
        }
        if (prev_line != 0 and line > prev_line + 1) try w.print("{s}...{s}\n", .{ p.gutter, p.reset });
        prev_line = line;

        const index = try pass.lineIndex(file);
        try w.print("{s}{d}{s} |{s} ", .{ p.gutter, line, spaces(gutter -| digits(line)), p.reset });
        try writeExpanded(w, index.lineText(pass.bag.sourceText(file), line));
        try w.writeByte('\n');

        // One underline row per span on this line, deepest column last, so
        // the labels stack instead of overlapping.
        for (placed[i..j]) |q| {
            try w.print("{s}{s} |{s} ", .{ spaces(gutter), p.gutter, p.reset });
            try w.splatByteAll(' ', q.col);
            try w.print("{s}", .{if (q.primary) p.forSeverity(severity) else p.gutter});
            try w.splatByteAll(if (q.primary) '^' else '-', q.width);
            if (q.text.len != 0) try w.print(" {s}", .{q.text});
            try w.print("{s}\n", .{p.reset});
        }
        assert(j > i);
        i = j;
    }
    try w.print("{s}{s} |{s}\n", .{ spaces(gutter), p.gutter, p.reset });
}

fn snippetOrder(home: FileId, a: Placed, b: Placed) bool {
    if (a.file != b.file) {
        if ((a.file == home) != (b.file == home)) return a.file == home;
        return @backingInt(a.file) < @backingInt(b.file);
    }
    if (a.line != b.line) return a.line < b.line;
    return a.col < b.col;
}

/// Shows a machine-applicable rewrite as the patched line, with `+` under an
/// insertion and `~` under a replacement.
fn renderFix(pass: Pass, fix: entry.Fix, file: FileId, gutter: u32) RenderError!void {
    const p = pass.p;
    const w = pass.w;
    const bag = pass.bag;
    const r = bag.locate(fix.span, file);
    const file_text = bag.sourceText(r.file);
    if (file_text.len == 0) return;
    const index = try pass.lineIndex(r.file);
    // The strip-map step `place` takes: the patched line drawn is the
    // ORIGINAL, so the cut points are measured in it.
    const src_off = bag.toSourceOffset(r.file, r.offset);
    const src_end = @max(src_off, bag.toSourceOffset(r.file, r.offset +| fix.span.len()));
    const loc = index.loc(src_off);
    const line = index.lineText(file_text, loc.line);
    const cut = @min(loc.col - 1, line.len);
    const cut_end = @min(cut + (src_end - src_off), line.len);
    assert(cut <= cut_end);

    try w.print("{s}{s} |{s}\n", .{ spaces(gutter), p.gutter, p.reset });
    try w.print("{s}{d}{s} |{s} ", .{ p.gutter, loc.line, spaces(gutter -| digits(loc.line)), p.reset });
    try writeExpanded(w, line[0..cut]);
    // Expanded like the line around it, so the ruler below counts it in the
    // display columns a caret uses.
    try w.print("{s}", .{p.good});
    try writeExpanded(w, fix.replacement);
    try w.print("{s}", .{p.reset});
    try writeExpanded(w, line[cut_end..]);
    try w.writeByte('\n');

    try w.print("{s}{s} |{s} ", .{ spaces(gutter), p.gutter, p.reset });
    try w.splatByteAll(' ', displayCol(line, @intCast(cut)));
    try w.print("{s}", .{p.good});
    try w.splatByteAll(
        if (fix.span.len() == 0) '+' else '~',
        @max(1, displayCol(fix.replacement, @intCast(fix.replacement.len))),
    );
    try w.print("{s}\n", .{p.reset});
}

/// The cap trailer, then the summary; a `.run` error was raised after the
/// design compiled, so it is its own report and no compile failure (#72).
fn renderTrailer(pass: Pass, summary: bool) Writer.Error!void {
    const bag = pass.bag;
    const p = pass.p;
    const w = pass.w;
    if (bag.suppressed != 0) {
        try w.print("{s}{s}:{s} {d} further diagnostic(s) not shown (limit {d})\n", .{
            p.warn, "warning", p.reset, bag.suppressed, bag_file.max_entries,
        });
    }
    const compile_errs = bag.err_count - bag.run_err_count;
    if (!summary or (compile_errs == 0 and bag.warn_count == 0)) return;
    if (compile_errs != 0) {
        try w.print("{s}error{s}: could not compile due to {d} previous error(s)", .{ p.err, p.reset, compile_errs });
        if (bag.warn_count != 0) try w.print("; {d} warning(s) emitted", .{bag.warn_count});
        try w.writeByte('\n');
    } else {
        try w.print("{s}warning{s}: {d} warning(s) emitted\n", .{ p.warn, p.reset, bag.warn_count });
    }
}

/// Returns the display column of byte `byte_col` of `line`: a tab is
/// `tab_width` columns and a UTF-8 continuation byte none. Codepoints, not
/// grapheme clusters or wcwidth: the approximation rustc makes, and no
/// invalid-input error.
fn displayCol(line: []const u8, byte_col: u32) u32 {
    var col: u32 = 0;
    for (line[0..@min(byte_col, line.len)]) |c| {
        if (c & 0xc0 == 0x80) continue;
        col += if (c == '\t') tab_width else 1;
    }
    return col;
}

fn writeExpanded(w: *Writer, line: []const u8) Writer.Error!void {
    for (line) |c| {
        if (c == '\t') try w.splatByteAll(' ', tab_width) else try w.writeByte(c);
    }
}

fn digits(n: u32) u32 {
    var v = n;
    var d: u32 = 1;
    while (v >= 10) : (v /= 10) d += 1;
    assert(d <= 10);
    return d;
}

fn spaces(n: u32) []const u8 {
    return spaces_pad[0..@min(n, spaces_pad.len)];
}
