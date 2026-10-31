//! `include: the line after an IEEE 1364-2005 §19.5 `include word in, the
//! named file read and scanned in place out, refusing the one repetition that
//! makes nesting infinite (E0125). Search order: an absolute path as written,
//! the including file's directory, the include dirs, then the built-in annex
//! D files (`builtin_includes`).
//! Cites: IEEE 1364-2005 §19.5 Syntax 19-6; LRM §10.7, annex D;
//! specification/Vague_Decisions.md VD-091, VD-093.
//!
//! Contents:
//! - `pub const builtin_includes: std.StaticStringMap([]const u8)`
//! - `pub fn handleInclude(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const diag = @import("diag");
const preprocessor = @import("../preprocessor.zig");
const Pp = @import("Pp.zig");
const Error = Pp.Error;
const Rest = @import("scan.zig").Rest;
const pp_annex_d = @import("annex_d.zig");
const pp_annex_e = @import("annex_e.zig");

/// Built-in annex D files, resolvable by `include even with no include_dirs.
/// All three are self-guarded, so an explicit `include after the prelude
/// expands to nothing. Only D.1 and D.2 are preloaded (see `process`); D.3
/// driver_access.vams must be included. `discipline.h` and `constants.h`
/// are the OVI Verilog-A 1.0 names of D.1 and D.2, which CMC models of that
/// era include (specification/Vague_Decisions.md VD-093).
pub const builtin_includes = std.StaticStringMap([]const u8).initComptime(.{
    .{ "constants.vams", pp_annex_d.constants_vams },
    .{ "disciplines.vams", pp_annex_d.disciplines_vams },
    .{ "constants.h", pp_annex_d.constants_vams },
    .{ "discipline.h", pp_annex_d.disciplines_vams },
    .{ "driver_access.vams", pp_annex_e.driver_access_vams },
});

/// The bytes of an `include and the path they were opened by, which §10.7
/// makes `__FILE__`: "the path by which a tool opened the file, not the short
/// name specified in `include". A built-in annex D file keeps the name written.
const Included = struct { text: []const u8, path: []const u8 };

/// Reads and scans the file an IEEE 1364 §19.5 `include names. `rest` is the
/// line after the word, starting at offset `off`; `at` is the '`'. Fails with
/// E0121-E0124 (the name), E0144 (text after it), E0125 (an include cycle),
/// E0126 (not found) or E1013 (larger than `preprocessor.max_text_bytes`).
pub fn handleInclude(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    // The open-includes stack is the cycle check's: it leaves as it came.
    assert(off > at);
    const depth = pp.includes.items.len;
    defer assert(pp.includes.items.len == depth);
    // The directive word, for the errors that have nothing better to point at.
    const sp = pp.spanAt(at, off);
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const open = r.peek() orelse return pp.fail(sp, .E0121, "", .{});
    // IEEE 1364-2005 §19.5 Syntax 19-6 has one form, `include "filename". C's
    // `<file>` is not in it, so `<` is E0122 like any other opener.
    if (open != '"') return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), .E0122, "found `{c}`", .{open});
    r.i += 1;
    const start = r.i;
    r.i = std.mem.findScalarPos(u8, r.s, start, '"') orelse r.s.len;
    if (r.i >= r.s.len) return pp.fail(pp.spanAt(off + start - 1, off + r.i), .E0123, "", .{});
    const path = r.s[start..r.i];
    if (path.len == 0) return pp.fail(pp.spanAt(off + start - 1, off + r.i + 1), .E0124, "", .{});
    // The file name itself, quotes excluded.
    const name_span = pp.spanAt(off + start, off + r.i);
    // IEEE 1364 §19.5: "Only white space or a comment may appear on the same
    // line as the `include compiler directive." Comments are gone already.
    r.i += 1;
    r.skipSpace();
    if (r.i < r.s.len)
        return pp.fail(pp.spanAt(off + r.i, off + r.s.len), .E0144, "`{s}`", .{std.mem.trim(u8, r.s[r.i..], " \t\r\n")});

    const inc = (try readInclude(pp, path, name_span)) orelse {
        var b = pp.failWith(name_span, .E0126);
        b.msg("\"{s}\"", .{path});
        const dirs = if (includerDir(pp)) |d| try std.mem.concat(pp.scratch, []const u8, &.{ &.{d}, pp.opts.include_dirs }) else pp.opts.include_dirs;
        if (dirs.len != 0) b.note("searched, in order: {s}", .{try std.mem.join(pp.scratch, ", ", dirs)});
        b.note("then the built-in annex D headers ({s})", .{"constants.vams, disciplines.vams"});
        try b.emit();
        return error.PreprocessFailed;
    };

    // IEEE 1364-2005 §19.5: "The number of nesting levels for include files
    // shall be finite", and VerA sets no number. What makes nesting infinite
    // is a file opened again inside itself in the state it was first opened
    // in: the preprocessor's control flow reads only the macro table and the
    // open conditionals, so from there it repeats forever. Any other chain
    // ends (a file may include itself under a guard that changes), so only
    // that repetition is refused, naming the cycle. The state is compared by
    // a 64-bit hash of the macro table; two different tables share one with
    // probability 2^-64.
    const opened: Pp.Open = .{
        .key = try std.fs.path.resolve(pp.scratch, &.{inc.path}),
        .path = path,
        .macro_hash = pp.macro_hash,
        .conds = pp.conds.items.len,
    };
    for (pp.includes.items, 0..) |o, k| {
        if (o.macro_hash != opened.macro_hash or o.conds != opened.conds or !std.mem.eql(u8, o.key, opened.key)) continue;
        var chain: std.ArrayList([]const u8) = .empty;
        for (pp.includes.items[k..]) |c| try chain.append(pp.scratch, c.path);
        var b = pp.failWith(name_span, .E0125);
        b.msg("\"{s}\" includes itself with every macro as it was", .{path});
        b.note("include cycle: {s}", .{try pp.joinChain(chain.items, path)});
        try b.emit();
        return error.PreprocessFailed;
    }
    try pp.includes.append(pp.scratch, opened);
    defer _ = pp.includes.pop();
    // `Options.require_std_includes`: the source asked for annex D, from an
    // include directory or built in (a guarded copy is then a no-op).
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "constants.vams") or std.mem.eql(u8, base, "constants.h")) pp.constants_included = true;
    if (std.mem.eql(u8, base, "disciplines.vams") or std.mem.eql(u8, base, "discipline.h")) pp.disciplines_included = true;
    // Registered under the opened path, so `__FILE__` and every diagnostic
    // inside the file name the file that was read (§10.7).
    try pp.nested(name_span, Pp.runFile, .{ pp, inc.text, inc.path, null });
    try pp.checkTextSize(name_span);
    // `scan` resyncs the map back to the parent file when `directive` returns.
}

// ---- private ----

/// Returns the `include file for `path`: an absolute path as written, else
/// the first hit in the including file's directory and then the include dirs
/// (specification/Vague_Decisions.md VD-091), else a built-in annex D file by
/// basename. Null if nothing matched; a file that exists but cannot be read
/// counts as no match. The bytes and the path are on `pp.arena`, since the
/// bag keeps both. Fails with E1013 for a file past
/// `preprocessor.max_text_bytes`.
fn readInclude(pp: *Pp, path: []const u8, span: diag.Span) Error!?Included {
    assert(path.len > 0);
    // IEEE 1364 §19.5: a full path name is opened as written; `join` skips
    // the empty base.
    if (std.fs.path.isAbsolute(path)) return (try readAt(pp, "", path, span)) orelse builtin(pp, path);
    if (includerDir(pp)) |dir| if (try readAt(pp, dir, path, span)) |inc| return inc;
    for (pp.opts.include_dirs) |base| if (try readAt(pp, base, path, span)) |inc| return inc;
    return builtin(pp, path);
}

/// The directory of the file the current `include sits in: the path it was
/// opened by (§10.7), "." for a bare file name, and null for a unit that
/// names no file (`<source>`, `<digital>`), which has no directory to search.
fn includerDir(pp: *const Pp) ?[]const u8 {
    const name = pp.opts.bag.fileName(pp.cur_file_id);
    if (name.len == 0 or name[0] == '<') return null;
    const dir = std.fs.path.dirname(name) orelse ".";
    assert(dir.len > 0);
    return dir;
}

fn readAt(pp: *Pp, base: []const u8, path: []const u8, span: diag.Span) Error!?Included {
    assert(path.len > 0);
    const io = std.Io.Threaded.global_single_threaded.io();
    const full = try std.fs.path.join(pp.arena, &.{ base, path });
    if (preprocessor.readText(io, .cwd(), full, pp.arena)) |bytes| {
        return .{ .text = bytes, .path = full };
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return pp.fail(span, .E1013, "\"{s}\" is larger than {d} bytes", .{ full, preprocessor.max_text_bytes }),
        else => return null, // try the next dir
    }
}

fn builtin(pp: *Pp, path: []const u8) Error!?Included {
    assert(path.len > 0);
    const name = std.fs.path.basename(path);
    const text = builtin_includes.get(name) orelse return null;
    if (std.mem.eql(u8, name, "disciplines.vams") or std.mem.eql(u8, name, "discipline.h")) pp.annex_d_included = true;
    // `path` may slice a macro body on scratch, and the bag keeps the name.
    return .{ .text = text, .path = try pp.arena.dupe(u8, path) };
}
