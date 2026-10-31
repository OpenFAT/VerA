//! Netlist files in, their physical lines (lower-cased, comments stripped)
//! out, `.INCLUDE` and `.LIB` expanded in place as SPICE reads them and
//! HSPICE `.HDL` sources recorded; a file that cannot be read, a missing
//! entry or a cycle is a `Refusal` at the card.
//! Cites: LRM annex E.1.2, E.2; specification/Vague_Decisions.md VD-091.
//!
//! Contents:
//! - `pub const Reader = struct`: `read`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const spice_cards = @import("../spice_cards.zig");
const Refusal = spice_cards.Refusal;
const File = spice_cards.File;
const deep_stack = @import("base").deep_stack;
const preprocessor = @import("../preprocessor.zig");
const spice_card = @import("card.zig");
const Card = spice_card.Card;
const Refusals = spice_card.Refusals;
const hasEntry = spice_card.hasEntry;
const unquote = spice_card.unquote;
const strip = spice_card.strip;

/// Reads netlist files into `lines`, the way SPICE reads them: a `.INCLUDE
/// file` card is replaced by the file's lines, a `.LIB file entry` card by
/// the lines between `.LIB entry` and `.ENDL` in that file, and a `.LIB
/// entry` ... `.ENDL` block met any other way is a library entry, read only
/// when called. A relative file name is looked for beside the file whose
/// card names it, as VD-091 does for `` `include ``. `.HDL file` names a
/// Verilog-A source (`Synthesized.hdl`). A file that cannot be read, an entry
/// it does not have, or a cycle (a file, or a `.LIB` entry of it, read again
/// inside itself, which never ends) is a `Refusal` at the card. Any finite
/// nesting is read.
pub const Reader = struct {
    arena: Allocator,
    scratch: Allocator,
    refusals: *Refusals,
    /// Every physical line read, one `Card` each, in reading order.
    lines: std.ArrayList(Card) = .empty,
    files: std.ArrayList(File) = .empty,
    hdl: std.ArrayList([]const u8) = .empty,
    /// The files being read now, outermost first: each one's path with `.`
    /// and `..` resolved, and the `.LIB` entry read from it (null: all of
    /// it). Reading one of them again is a cycle.
    reading: std.ArrayList(struct { key: []const u8, entry: ?[]const u8 }) = .empty,

    /// Appends file `fi`'s lines, or with `entry` only those of its `.LIB
    /// entry` block.
    /// Asserts that `fi` names a file already in `files`.
    pub fn read(r: *Reader, fi: u32, entry: ?[]const u8) Allocator.Error!void {
        assert(fi < r.files.items.len);
        try r.reading.append(r.scratch, .{ .key = try std.fs.path.resolve(r.scratch, &.{r.files.items[fi].name}), .entry = entry });
        defer _ = r.reading.pop();
        const text = r.files.items[fi].text;
        // Inside a `.LIB name` block: true when it is the entry asked for.
        var in_lib: ?bool = null;
        // The open block's header, so one `.ENDL` never closes is not a
        // silent end of the file.
        var header: Card = undefined;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = strip(raw);
            if (line.len == 0) continue;
            const at: u32 = @intCast(line.ptr - text.ptr);
            const card: Card = .{ .text = line, .file = fi, .at = at, .len = @intCast(line.len) };
            var it = std.mem.tokenizeAny(u8, line, " \t");
            const kw = try std.ascii.allocLowerString(r.scratch, it.next().?);
            const arg = unquote(it.next() orelse "");
            const arg2 = unquote(it.next() orelse "");
            if (std.mem.eql(u8, kw, ".lib") and arg2.len == 0) {
                // A library entry's header, not a call.
                if (in_lib == null) {
                    in_lib = if (entry) |e| std.ascii.eqlIgnoreCase(e, arg) else false;
                    header = card;
                }
                continue;
            }
            if (std.mem.eql(u8, kw, ".endl")) {
                const done = in_lib orelse false;
                in_lib = null;
                if (done) return;
                continue;
            }
            if (entry != null and !(in_lib orelse false)) continue;
            if (in_lib == false) continue;
            const include = std.mem.eql(u8, kw, ".include") or std.mem.eql(u8, kw, ".inc");
            if (include or std.mem.eql(u8, kw, ".lib")) {
                if (arg.len == 0) {
                    try r.refusals.add(card, "`{s}` names no file", .{kw});
                    continue;
                }
                const sub = try r.open(card, kw, arg) orelse continue;
                const sub_entry: ?[]const u8 = if (include) null else arg2;
                if (try r.cycle(sub, sub_entry)) |chain| {
                    try r.refusals.add(card, "`{s}` cycle: {s}", .{ kw, chain });
                    continue;
                }
                const before = r.lines.items.len;
                // Every 512 nested files continue on a fresh stack segment,
                // so nesting is bounded by memory, not the caller's stack.
                if (r.reading.items.len % 512 != 0) try r.read(sub, sub_entry) else deep_stack.run(512, read, .{ r, sub, sub_entry }) catch |e| switch (e) {
                    error.DeepStackUnavailable => {
                        try r.refusals.add(card, "`{s}`: no stack left for {d} nested files", .{ kw, r.reading.items.len });
                        continue;
                    },
                    error.OutOfMemory => |oom| return oom,
                };
                if (!include and r.lines.items.len == before and !hasEntry(r.files.items[sub].text, arg2))
                    try r.refusals.add(card, "`{s}` has no `.lib {s}` entry", .{ r.files.items[sub].name, arg2 });
                continue;
            }
            if (std.mem.eql(u8, kw, ".hdl")) {
                if (arg.len == 0) {
                    try r.refusals.add(card, "`.hdl` names no file", .{});
                    continue;
                }
                const full = try r.resolve(fi, arg);
                for (r.hdl.items) |h| {
                    if (std.mem.eql(u8, h, full)) break;
                } else try r.hdl.append(r.arena, full);
                continue;
            }
            var lowered = card;
            lowered.text = try std.ascii.allocLowerString(r.scratch, line);
            try r.lines.append(r.scratch, lowered);
        }
        if (in_lib != null) try r.refusals.add(header, "`.lib` entry has no `.endl`; the cards after it are not read", .{});
    }

    /// The chain `a -> b -> a` when reading file `fi` (`entry` of it) now
    /// would repeat a read still open, else null.
    fn cycle(r: *Reader, fi: u32, entry: ?[]const u8) Allocator.Error!?[]const u8 {
        const key = try std.fs.path.resolve(r.scratch, &.{r.files.items[fi].name});
        for (r.reading.items, 0..) |o, k| {
            const same_entry = if (o.entry) |a| (if (entry) |b| std.ascii.eqlIgnoreCase(a, b) else false) else entry == null;
            if (!same_entry or !std.mem.eql(u8, o.key, key)) continue;
            var chain: std.ArrayList(u8) = .empty;
            for (r.reading.items[k..]) |c| try chain.print(r.scratch, "{s} -> ", .{c.key});
            try chain.appendSlice(r.scratch, key);
            return chain.items;
        }
        return null;
    }

    /// `name` beside the file `fi` was opened by, or as written when absolute.
    fn resolve(r: *Reader, fi: u32, name: []const u8) Allocator.Error![]const u8 {
        assert(fi < r.files.items.len);
        assert(r.files.items[0].name.len != 0); // `synthesize` names the netlist
        if (std.fs.path.isAbsolute(name)) return r.arena.dupe(u8, name);
        const dir = std.fs.path.dirname(r.files.items[fi].name) orelse ".";
        const base = if (fi == 0 and r.files.items[0].name[0] == '<') "." else dir;
        return std.fs.path.join(r.arena, &.{ base, name });
    }

    /// Reads the file `card` names (`.include` or `.lib`) into `files`, or
    /// records why not and returns null.
    fn open(r: *Reader, card: Card, kw: []const u8, name: []const u8) Allocator.Error!?u32 {
        assert(card.text.len > 0);
        const full = try r.resolve(card.file, name);
        const io = std.Io.Threaded.global_single_threaded.io();
        const text = preprocessor.readText(io, .cwd(), full, r.arena) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try r.refusals.add(card, "`{s}`: cannot read \"{s}\" ({t})", .{ kw, full, e });
                return null;
            },
        };
        try r.files.append(r.arena, .{ .name = full, .text = text });
        return @intCast(r.files.items.len - 1);
    }
};
