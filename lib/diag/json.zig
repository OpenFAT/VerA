//! JSON rendering: a bag in, JSON Lines out, one object per diagnostic,
//! shaped like rustc's `--message-format json` so editor plumbing can read
//! it.
//!
//! Cites no LRM clause: the output format is VerA's own.
//!
//! Contents:
//! - `pub fn renderJson(bag: *Bag, w: *std.Io.Writer) RenderError!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const code = @import("code.zig");
const entry = @import("entry.zig");
const location = @import("location.zig");
const bag_file = @import("bag.zig");
const Bag = bag_file.Bag;
const RenderError = @import("render.zig").RenderError;
const FileId = location.FileId;
const Span = location.Span;

/// The state one `renderJson` call shares between its rows.
const Json = struct {
    bag: *const Bag,
    scratch: Allocator,
    lines: location.LineCache,
    w: *Writer,

    fn span(json: Json, s: Span, file: FileId) RenderError!void {
        if (s.isNone()) return json.w.writeAll("null");
        const bag = json.bag;
        const r = bag.locate(s, file);
        const index = try json.lines.index(json.scratch, r.file, bag.sourceText(r.file));
        // Line and column in the ORIGINAL file, strip-mapped like the text
        // renderer; the byte offsets stay in span currency.
        const loc = index.loc(bag.toSourceOffset(r.file, r.offset));
        assert(loc.line >= 1);
        try json.w.writeAll("{\"file\":");
        try writeString(json.w, bag.fileName(r.file));
        try json.w.print(",\"line\":{d},\"col\":{d},\"byte_start\":{d},\"byte_end\":{d}}}", .{
            loc.line, loc.col, s.start, s.end,
        });
    }
};

/// Writes one JSON object per kept diagnostic, one per line. A span is
/// `null` when absent, else its file, 1-based `line` and byte `col` in the
/// ORIGINAL file and its `byte_start`/`byte_end` in span currency. Sorts the
/// bag first, which invalidates earlier `Entry.index` values. The suppressed
/// and deduped counts are not reported. Line-index scratch lives in
/// `bag.arena` and is freed on return.
pub fn renderJson(bag: *Bag, w: *Writer) RenderError!void {
    bag.sort();
    var scratch_state = std.heap.ArenaAllocator.init(bag.arena);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const json: Json = .{ .bag = bag, .scratch = scratch, .lines = try .init(scratch, bag.files.items.len), .w = w };

    for (0..bag.count()) |row| {
        const e = bag.at(row);
        const meta = code.info(e.code);
        try w.writeAll("{\"code\":\"");
        try w.writeAll(e.code.name());
        try w.print("\",\"level\":\"{s}\",\"stage\":\"{s}\",\"lrm\":", .{ e.severity.word(), @tagName(e.stage) });
        try writeString(w, meta.lrm);
        try w.writeAll(",\"title\":");
        try writeString(w, meta.title);
        try w.writeAll(",\"message\":");
        try writeString(w, e.message);
        try w.writeAll(",\"span\":");
        try json.span(e.span, e.file);

        try w.writeAll(",\"labels\":[");
        // SAFETY: `labels` writes the slots it returns.
        var label_buf: [entry.max_children]entry.Label = undefined;
        for (bag.labels(e, &label_buf), 0..) |l, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{\"text\":");
            try writeString(w, l.text);
            try w.writeAll(",\"span\":");
            try json.span(l.span, e.file);
            try w.writeByte('}');
        }

        try w.writeAll("],\"notes\":[");
        // SAFETY: `notes` writes the slots it returns.
        var note_buf: [entry.max_children]entry.Note = undefined;
        for (bag.notes(e, &note_buf), 0..) |n, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("{{\"kind\":\"{s}\",\"text\":", .{@tagName(n.kind)});
            try writeString(w, n.text);
            if (n.fix) |fix| {
                try w.writeAll(",\"fix\":{\"replacement\":");
                try writeString(w, fix.replacement);
                try w.writeAll(",\"span\":");
                try json.span(fix.span, e.file);
                try w.writeByte('}');
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}\n");
    }
    assert(bag.count() <= bag_file.max_entries);
}

// ---- private ----

fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}
