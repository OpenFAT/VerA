//! Preprocessor state for one compilation (`Pp`): the macro table, the
//! open conditionals and `include`s, the output text and its source map,
//! the directive events while they fill, and the helpers every handler shares
//! (diagnostics, nesting on a `deep_stack` segment, the line remap). Also the
//! per-file step, `runFile`: one raw file in, its stripped text scanned into
//! `out`.
//! Cites: LRM §2.4, §10.4, §10.5, §10.7; IEEE 1364-2005 §19.5, §19.7.
//!
//! Two lifetimes. `arena` is the caller's and holds only what outlives
//! `process` through the bag: each file's stripped text and marks, an
//! `include's bytes and path, a suggestion's replacement text, and the
//! published copies `process` makes at the end. Every table lives on
//! `scratch`, which `process` frees on return; a slice of a macro body (also
//! on scratch) that must outlive it is copied to `arena` where it is stored.
//! Offsets are `u32`, the unit `diag.Span` and `diag.Segment` store.
//!
//! Contents:
//! - `pub const Error = preprocessor.Error`
//! - `pub const Macro = struct`
//! - `pub const Cond = struct`
//! - `pub const Open = struct`
//! - `pub fn putMacro(pp: *Pp, name: []const u8, m: Macro) Allocator.Error!void`
//! - `pub fn removeMacro(pp: *Pp, name: []const u8) void`
//! - `pub fn nested(pp: *Pp, span: diag.Span, comptime f: anytype, args: anytype) Error!void`
//! - `pub fn checkTextSize(pp: *Pp, span: diag.Span) Error!void`
//! - `pub fn emitting(pp: *const Pp) bool`
//! - `pub fn mark(pp: *Pp, list: anytype, value: anytype) Allocator.Error!void`
//! - `pub fn putNewlines(pp: *Pp, span: []const u8) Error!void`
//! - `pub fn spanAt(pp: *const Pp, start: usize, end: usize) diag.Span`
//! - `pub fn physicalLine(pp: *const Pp, at: usize) u32`
//! - `pub fn currentLine(pp: *const Pp, at: usize) u64`
//! - `pub fn failWith(pp: *Pp, span: diag.Span, code: diag.Code) diag.Builder`
//! - `pub fn fail(pp: *Pp, span: diag.Span, code: diag.Code, comptime fmt: []const u8, args: anytype) Error`
//! - `pub fn addFile(pp: *Pp, name: []const u8, text: []const u8) Error!diag.FileId`
//! - `pub fn resync(pp: *Pp, at: usize) Error!void`
//! - `pub fn runStdDefs(pp: *Pp) Error!void`
//! - `pub fn runSpicePrimitives(pp: *Pp) Error!void`
//! - `pub fn replayStdDefs(pp: *Pp) Error!void`
//! - `pub fn runFile(pp: *Pp, raw: []const u8, file: []const u8, existing: diag.FileId) Error!void`
//! - `pub fn joinChain(pp: *Pp, stack: []const []const u8, last: []const u8) Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const deep_stack = @import("base").deep_stack;
const preprocessor = @import("../preprocessor.zig");
const Options = preprocessor.Options;
const max_text_bytes = preprocessor.max_text_bytes;
const segment_levels = preprocessor.segment_levels;
const caller_levels = preprocessor.caller_levels;
const Events = @import("events.zig").Events;
const pp_comments = @import("comments.zig");
const pp_scan = @import("scan.zig");
const pp_prelude = @import("prelude.zig");
const pp_annex_d = @import("annex_d.zig");
const pp_annex_e = @import("annex_e.zig");

/// The caller's allocator; holds what outlives `process`.
arena: Allocator,
/// Freed when `process` returns; holds every table below.
scratch: Allocator,
opts: Options,

// ---- outputs, copied to `arena` by `process` ------------------------
out: std.ArrayList(u8) = .empty,
/// Provenance of the output so far. Appended to only, so it stays sorted
/// by `out_start` and `SourceMap.resolve` can binary-search it.
segs: std.ArrayList(diag.Segment) = .empty,
events: Events = .{},
/// `Output.annex_d_included`, set by `directive.builtin`.
annex_d_included: bool = false,
/// An `include named constants.vams (constants.h) / disciplines.vams
/// (discipline.h), set by `directive.include`; `Output.disciplines_included`.
constants_included: bool = false,
disciplines_included: bool = false,
/// Running text VerA ships (the prelude, a synthesized netlist), which
/// reads annex D.2 whatever the source includes.
in_std_defs: bool = false,

// ---- scan state ------------------------------------------------------
macros: std.StringHashMapUnmanaged(Macro) = .empty,
conds: std.ArrayList(Cond) = .empty,
/// Macro-expansion cycle guard (§10.4): names currently being expanded,
/// outermost first, and the same names as a set, so a chain of n distinct
/// macros costs O(n), not O(n^2). A name is pushed only inside a live
/// `expand` call. A cycle is E0118; any finite chain is legal.
expanding: std.ArrayList([]const u8) = .empty,
expanding_set: std.StringHashMapUnmanaged(void) = .empty,
/// `include stack, innermost last: each open file and the macro state it
/// was opened in. E0125 refuses an `include that repeats an entry, the
/// one thing that makes the nesting never end (`directive.handleInclude`).
includes: std.ArrayList(Open) = .empty,
/// Order-free hash of the macro table (`macroHash` of every entry,
/// XORed), kept by `putMacro` and `removeMacro`.
macro_hash: u64 = 0,
/// Open `nested` levels, and their count when the current stack
/// segment began.
seg: deep_stack.Segments = .{},
/// IEEE 1364 §19.7 `line remap for §10.7 `__LINE__`; `line_to` is null when
/// the current file is numbered naturally. `line_from` is the physical
/// 1-based line after the directive and `line_to` the number §19.7 gives
/// it, so a later line L reports `to + (L - from)`. Per file: `runFile`
/// saves and restores both, as §10.7 requires at the end of an `include.
line_from: u32 = 0,
line_to: ?u32 = null,
/// The `line directive's file name, which §10.7 lets replace `__FILE__`.
/// Null means the current file's real name.
file_override: ?[]const u8 = null,
/// The file the current offsets belong to.
cur_file_id: diag.FileId = .root,
/// The outermost invocation's offset while a macro body is rescanned.
/// Offsets inside a body index no file, so diagnostics there report here.
expand_site: ?u32 = null,
/// `out` is an actual's own buffer (`expandArg`), not the output, so no
/// segment may be recorded: the text is mapped when the expansion that
/// substitutes it is.
in_actual: bool = false,
/// Index in `segs` of the outermost expansion's `.macro` segment, valid
/// while that expansion set `expand_site` outside an actual. `runFile`
/// repeats it after an `include the expansion reached.
expansion_seg: u32 = 0,

/// Every way a preprocessor step fails (`preprocessor.Error`).
pub const Error = preprocessor.Error;

/// One `define (§10.4), the value of `Pp.macros` under its name. Every slice
/// borrows the defining text (a file's stripped text, a macro body on
/// `Pp.scratch`, or the process-lifetime prelude), all of which outlive the
/// table.
pub const Macro = struct {
    /// The formal argument names, in order. Empty and `is_func == false`
    /// means an object-like macro.
    params: []const []const u8 = &.{},
    /// A formal list was written, even an empty one: `M()` takes zero
    /// arguments where object-like `M` takes none at all.
    is_func: bool = false,
    /// The macro text, one logical line, continuations joined (§10.4).
    body: []const u8,
    /// §10.5 predefined: survives `undef and `resetall.
    predefined: bool = false,
    /// Defined by the prelude's annex D.2 constants.vams: under
    /// `Options.require_std_includes` a use needs `include "constants.vams"`.
    annex_d2: bool = false,
    /// Defined by the prelude's annex D.1 disciplines.vams (its guard
    /// `DISCIPLINES_VAMS`): under `Options.require_std_includes` an `ifdef
    /// reads it as undefined until the source includes the file.
    annex_d1: bool = false,

    // Budget: two slices and three flags. A few hundred per compilation (psp103
    // holds 204: 45 prelude, 156 its own, 3 predefined), so packing the slices
    // into pool offsets would save under 4 KB of scratch.
    comptime {
        assert(@sizeOf(Macro) <= 40);
    }
};

/// One `ifdef/`ifndef level.
pub const Cond = struct {
    /// Enclosing levels are all emitting.
    parent_active: bool,
    /// This level emits right now (already includes `parent_active`).
    active: bool,
    /// Some arm of this level was taken, so later `elsif/`else are dead.
    taken: bool,
    /// The level's `else has been read, so another `else or `elsif is E0106.
    seen_else: bool = false,
    /// The `ifdef that opened this level, for E0101's label.
    span: diag.Span = .{},
    file: diag.FileId = .root,

    // Budget: one row per open nesting level, a handful at most, so the four
    // flags stay plain bools rather than a packed set (which saves 4 B).
    comptime {
        assert(@sizeOf(Cond) == 16);
    }
};

/// One open `include: its path with `.` and `..` resolved (the cycle
/// key), the path it was opened by (`joinChain`), and the macro state and
/// conditional depth at the `include. The preprocessor's control flow
/// (which arms are live, which files open) reads only those, so two opens
/// on one stack that agree on all three repeat forever.
pub const Open = struct { key: []const u8, path: []const u8, macro_hash: u64, conds: usize };

const Pp = @This();

/// Defines (or redefines) `name`, keeping `macro_hash`.
pub fn putMacro(pp: *Pp, name: []const u8, m: Macro) Allocator.Error!void {
    assert(name.len > 0);
    const gop = try pp.macros.getOrPut(pp.scratch, name);
    if (gop.found_existing) pp.macro_hash ^= macroHash(name, gop.value_ptr.*);
    gop.value_ptr.* = m;
    pp.macro_hash ^= macroHash(name, m);
    assert(pp.macros.contains(name));
}

/// Removes `name` if defined, keeping `macro_hash`.
pub fn removeMacro(pp: *Pp, name: []const u8) void {
    const kv = pp.macros.fetchRemove(name) orelse return;
    pp.macro_hash ^= macroHash(kv.key, kv.value);
    assert(!pp.macros.contains(name));
}

/// Calls `f(args)` as one more level of `include or macro-expansion
/// nesting: on a fresh `deep_stack` segment when this one is full. A
/// segment that cannot be reserved is E0119 at `span`.
pub fn nested(pp: *Pp, span: diag.Span, comptime f: anytype, args: anytype) Error!void {
    const frames = pp.seg.frames;
    defer assert(pp.seg.frames == frames);
    if (!pp.seg.due(caller_levels, segment_levels)) {
        pp.seg.frames += 1;
        defer pp.seg.frames -= 1;
        return @call(.auto, f, args);
    }
    return pp.seg.segment(segment_levels, f, args) catch |e| switch (e) {
        error.DeepStackUnavailable => pp.fail(span, .E0119, "{d} levels deep", .{pp.seg.frames}),
        else => |other| other,
    };
}

/// E0150 when the text built so far (`out`, or an actual's own buffer
/// while one is expanded) has passed `Options.text_limit`.
pub fn checkTextSize(pp: *Pp, span: diag.Span) Error!void {
    assert(pp.opts.text_limit <= max_text_bytes);
    if (pp.out.items.len > pp.opts.text_limit)
        return pp.fail(span, .E0150, "past {d} bytes", .{pp.opts.text_limit});
}

/// Returns whether every enclosing conditional arm is active.
pub fn emitting(pp: *const Pp) bool {
    const n = pp.conds.items.len;
    if (n == 0) return true;
    const top = pp.conds.items[n - 1];
    // A level can be live only inside a live parent.
    if (top.active) assert(top.parent_active);
    return top.active;
}

/// Appends an event to `list` at the current output length, which is where
/// the directive's own collapsed text ends and its region begins.
pub fn mark(pp: *Pp, list: anytype, value: anytype) Allocator.Error!void {
    const at: u32 = @intCast(pp.out.items.len);
    // Text-stream order: an event never lands before the one already there.
    if (list.items.len != 0) assert(list.items[list.items.len - 1].at <= at);
    try list.append(pp.scratch, .{ .at = at, .value = value });
}

/// Emits only the newlines in `span`, so dropped text (a dead `ifdef arm,
/// a collapsed directive) keeps the output's line count.
pub fn putNewlines(pp: *Pp, span: []const u8) Error!void {
    // Count-then-fill: `std.mem.countScalar` is vectorized.
    try pp.out.appendNTimes(pp.scratch, '\n', std.mem.countScalar(u8, span, '\n'));
}

/// Returns a file-local span for `[start, end)` of the text being scanned,
/// or the invocation site inside a macro body.
pub fn spanAt(pp: *const Pp, start: usize, end: usize) diag.Span {
    assert(start <= end);
    if (pp.expand_site) |s| return .at(s);
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

/// Returns the physical 1-based line of `at` in the current file, or of the
/// invocation site inside a macro body. O(offset): counts newlines.
pub fn physicalLine(pp: *const Pp, at: usize) u32 {
    const off = pp.expand_site orelse @as(u32, @intCast(at));
    const text = pp.opts.bag.fileText(pp.cur_file_id);
    const line: u32 = @intCast(1 + std.mem.countScalar(u8, text[0..@min(off, text.len)], '\n'));
    assert(line >= 1);
    return line;
}

/// Returns §10.7 `__LINE__` at `at`: the physical line, remapped by an
/// IEEE 1364 §19.7 `line when one is in force.
pub fn currentLine(pp: *const Pp, at: usize) u64 {
    const phys = pp.physicalLine(at);
    const to = pp.line_to orelse return phys;
    // Saturating: a `line whose operand is smaller than the offset it
    // corrects for cannot produce a line 0, let alone a negative one.
    return if (phys >= pp.line_from) @as(u64, to) + (phys - pp.line_from) else to;
}

/// Starts a diagnostic in the current file. Preprocessor spans are
/// file-local, since no preprocessed text exists yet to map them through.
pub fn failWith(pp: *Pp, span: diag.Span, code: diag.Code) diag.Builder {
    assert(span.start <= span.end);
    var b = pp.opts.bag.build(.preprocess, code, span);
    b.inFile(pp.cur_file_id);
    return b;
}

/// Emits `code` at `span` and returns `error.PreprocessFailed` to propagate.
pub fn fail(pp: *Pp, span: diag.Span, code: diag.Code, comptime fmt: []const u8, args: anytype) Error {
    var b = pp.failWith(span, code);
    b.msg(fmt, args);
    try b.emit();
    return error.PreprocessFailed;
}

/// Registers `name` and `text` in the bag and returns its id. The file table
/// holds `diag.files_max` files, and an include tree is input, so a file past
/// it is E0154 (`error.PreprocessFailed`), never a crash.
pub fn addFile(pp: *Pp, name: []const u8, text: []const u8) Error!diag.FileId {
    const before = pp.opts.bag.files.items.len;
    const id = pp.opts.bag.addFile(name, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyFiles => {
            assert(before == diag.files_max);
            var b = pp.opts.bag.build(.preprocess, .E0154, .none);
            b.msg("`{s}` would be file {d}", .{ name, before + 1 });
            try b.emit();
            return error.PreprocessFailed;
        },
    };
    assert(@backingInt(id) == before);
    return id;
}

/// Records that the output continues from `at` in the current file. Called
/// after every directive, because a directive that collapses to its
/// newlines makes the output shorter than the file it came from.
pub fn resync(pp: *Pp, at: usize) Error!void {
    // Inside a macro body there is no file offset to resync to; the
    // enclosing `.macro` segment already covers the whole expansion. An
    // actual's buffer is not the output at all.
    assert(at <= std.math.maxInt(u32));
    if (pp.expand_site != null or pp.in_actual) return;
    try pp.segs.append(pp.scratch, .{
        .out_start = @intCast(pp.out.items.len),
        .in_start = @intCast(at),
        .file = pp.cur_file_id,
        .kind = .verbatim,
    });
}

/// Preprocesses annex D.2, D.1 and Table E.1 into `pp`. Called once per
/// process by `buildPrelude`, and by the snapshot equivalence test.
pub fn runStdDefs(pp: *Pp) Error!void {
    // annex D.2 first: disciplines.vams reads `*_ABSTOL overrides, and the
    // constants are pure directives (they contribute only newlines here).
    pp.in_std_defs = true;
    defer pp.in_std_defs = false;
    try pp.runFile(pp_annex_d.constants_vams, "constants.vams", .none);
    // Every macro so far but the §10.5 predefined ones is D.2's.
    var it = pp.macros.valueIterator();
    while (it.next()) |m| m.annex_d2 = !m.predefined;
    try pp.runFile(pp_annex_d.disciplines_vams, "disciplines.vams", .none);
    // What D.1 added (its own guard) is D.1's, for the same rule.
    var d1 = pp.macros.valueIterator();
    while (d1.next()) |m| m.annex_d1 = !m.predefined and !m.annex_d2;
    // Annex E after annex D.1: the primitives' ports are `electrical`, which
    // disciplines.vams declares, and the source rows read `M_TWO_PI, which
    // constants.vams defines. Before the user's source, so nothing the user
    // `defines can reach into a shipped standard file.
    try pp.runFile(pp_annex_e.spice_primitives, "spice_primitives.vams", .none);
}

/// Table E.1 alone (`Options.spice_primitives`): its source rows read
/// annex D.2's `M_TWO_PI, defined for this file only, so no annex D macro
/// reaches the source.
pub fn runSpicePrimitives(pp: *Pp) Error!void {
    pp.in_std_defs = true;
    defer pp.in_std_defs = false;
    try pp.putMacro("M_TWO_PI", .{ .body = "6.28318530717958647693" });
    defer pp.removeMacro("M_TWO_PI");
    try pp.runFile(pp_annex_e.spice_primitives, "spice_primitives.vams", .none);
}

/// Copies `runStdDefs`' result out of the process-lifetime snapshot. Must
/// leave `pp` in exactly the state `runStdDefs` would.
pub fn replayStdDefs(pp: *Pp) Error!void {
    const p = try pp_prelude.preludeSnapshot();
    for (p.files, 1..) |f, want_id| {
        const id = try pp.addFile(f.name, f.raw);
        // `Prelude.segs` names files by index, so the three must land at
        // 1, 2, 3: only the compilation unit (`.root`) is registered yet.
        assert(@backingInt(id) == want_id);
        // Same state `runFile` leaves: spans index the stripped text and the
        // renderer maps back to the raw text through the marks.
        pp.opts.bag.setStrippedText(id, f.stripped, f.marks);
    }
    try pp.out.appendSlice(pp.scratch, p.text);
    try pp.segs.appendSlice(pp.scratch, p.segs);
    for (p.macros) |d| try pp.putMacro(d.name, d.macro);
    assert(pp.out.items.len >= p.text.len);
}

/// Registers `raw`, strips its comments and scans it. Saves and restores
/// the file context, so an error inside an `include names the right file.
/// `existing` is the id of an already-registered file (the compilation
/// unit), or `.none` to register a new one. Fails as `process` does.
pub fn runFile(pp: *Pp, raw: []const u8, file: []const u8, existing: diag.FileId) Error!void {
    assert(raw.len <= max_text_bytes);
    const segs_before = pp.segs.items.len;
    const saved_id = pp.cur_file_id;
    defer pp.cur_file_id = saved_id;

    // An `include that a macro expansion reached (IEEE 1364 §19.3.1 puts
    // the expansion in the text stream) opens a real file whose offsets
    // are its own: until it ends, spans and §10.7 `__LINE__` stop
    // reporting the invocation site.
    const saved_site = pp.expand_site;
    const saved_seg = pp.expansion_seg;
    pp.expand_site = null;
    defer {
        pp.expand_site = saved_site;
        pp.expansion_seg = saved_seg;
    }

    // §10.7: at the end of an included file "the expansions of `__FILE__
    // and `__LINE__ revert to the values they had before the `include".
    // `__LINE__` derives from a physical offset, so restoring the remap is
    // all that takes.
    const saved_from = pp.line_from;
    const saved_to = pp.line_to;
    const saved_override = pp.file_override;
    pp.line_from = 0;
    pp.line_to = null;
    pp.file_override = null;
    defer {
        pp.line_from = saved_from;
        pp.line_to = saved_to;
        pp.file_override = saved_override;
    }

    const id = if (existing != .none) existing else try pp.addFile(file, raw);
    pp.cur_file_id = id;

    // Registered raw first so a stripComments failure resolves, then
    // repointed: every later offset indexes the stripped text.
    const s = try pp_comments.stripComments(pp, raw);
    pp.opts.bag.setStrippedText(id, s.text, s.marks);
    const text = s.text;

    // In an actual's buffer the file's text is mapped with the expansion
    // that substitutes it (`resync`).
    if (!pp.in_actual) try pp.segs.append(pp.scratch, .{
        .out_start = @intCast(pp.out.items.len),
        .in_start = 0,
        .file = id,
        .kind = .verbatim,
    });
    try pp_scan.scan(pp, text);
    // Back inside the expansion that reached the `include: the rest of its
    // text maps to the invocation again.
    if (saved_site != null and !pp.in_actual) {
        var seg = pp.segs.items[saved_seg];
        seg.out_start = @intCast(pp.out.items.len);
        try pp.segs.append(pp.scratch, seg);
    }
    // The source map only grows.
    assert(pp.segs.items.len >= segs_before);
}

/// Returns `stack` and `last` joined as `A -> B -> C`, on `scratch`: for a
/// diagnostic's format arguments, which the bag copies.
pub fn joinChain(pp: *Pp, stack: []const []const u8, last: []const u8) Error![]const u8 {
    const sep = " -> ";
    var n = last.len + stack.len * sep.len;
    for (stack) |s| n += s.len;
    var out: std.ArrayList(u8) = try .initCapacity(pp.scratch, n);
    for (stack) |s| {
        out.appendSliceAssumeCapacity(s);
        out.appendSliceAssumeCapacity(sep);
    }
    out.appendSliceAssumeCapacity(last);
    assert(out.items.len == n);
    return out.items;
}

// ---- private ----

fn macroHash(name: []const u8, m: Macro) u64 {
    var h: std.hash.Wyhash = .init(0);
    h.update(name);
    h.update(&.{ 0, @intFromBool(m.is_func), @intFromBool(m.predefined) });
    for (m.params) |p| {
        h.update(p);
        h.update(&.{0});
    }
    h.update(&.{1});
    h.update(m.body);
    return h.final();
}
