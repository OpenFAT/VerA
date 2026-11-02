//! The reject half of VerA's analog plug: a fixture's source -> one
//! compilation's `Outcome` (`compileFixture`), judged against its
//! `//! reject` substrings (`verifyRejected`) or its `//! warn` and
//! `//! nowarn` lines (`warningsMet`). The expected behavior is a
//! diagnostic, never a transcript; `Analog.zig` owns the run half.
//!
//! Contents:
//! - `pub const Failure = struct`
//! - `pub const Outcome = union`
//! - `pub fn Outcome.deinit(self: *Outcome, gpa: std.mem.Allocator) void`
//! - `pub fn verifyRejected(gpa: std.mem.Allocator, f: Fixture, source: []const u8, d: tb.Spec, w: *Io.Writer) !Result`
//! - `pub fn compileFixture(gpa: std.mem.Allocator, f: Fixture, source: []const u8, d: tb.Spec) !Outcome`
//! - `pub fn warningsMet(bag: *vera.diag.Bag, f: Fixture, d: tb.Spec, w: *Io.Writer) !bool`

const std = @import("std");
const vera = @import("vera");
const tb = @import("exe");
const harness = @import("Fixtures.zig");

const Io = std.Io;
const Fixture = harness.Fixture;
const Result = harness.Result;

/// Why a fixture failed to produce a device, in the vocabulary the `//! reject`
/// directives are written in.
pub const Failure = struct {
    /// `@errorName` of the returned error, or a synthetic name for the two
    /// failure modes that are not Zig errors (see `compileFixture`).
    error_name: []const u8,
    diags: vera.diag.Bag,
    /// Non-null only for `GeneratedCompileError`; owned by `gpa`.
    generated: ?[]const u8 = null,
};

/// What one compilation did. `accepted` carries the device's size, not its
/// text: nothing downstream reads the text.
pub const Outcome = union(enum) {
    accepted: usize,
    refused: Failure,

    pub fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .accepted => {},
            .refused => |*bad| {
                if (bad.generated) |g| gpa.free(g);
                bad.diags.deinit(gpa);
            },
        }
    }
};

pub fn verifyRejected(
    gpa: std.mem.Allocator,
    f: Fixture,
    source: []const u8,
    d: tb.Spec,
    w: *Io.Writer,
) !Result {
    var outcome = try compileFixture(gpa, f, source, d);
    defer outcome.deinit(gpa);
    const bad = switch (outcome) {
        .accepted => {
            try w.print("FAIL {s}: expected a diagnostic, but it compiled cleanly\n", .{f.path});
            return .unmet;
        },
        .refused => |b| b,
    };

    for (d.harness.reject) |pattern| {
        if (!failureContains(bad, pattern)) {
            try w.print("FAIL {s}: diagnostic substring not found: \"{s}\"\n", .{ f.path, pattern });
            try w.print("  error: {s}\n", .{bad.error_name});
            try printDiags(bad, w);
            return .unmet;
        }
    }
    // `//! reject-only`: the refusal is the named rule's alone. An error no
    // pattern names is a second refusal riding inside this one, which a plain
    // `reject` cannot see.
    if (harness.probe_reject_only) {
        for (0..bad.diags.count()) |i| {
            if (bad.diags.at(i).severity != .err) continue;
            for (d.harness.reject) |pattern| {
                if (diagSays(&bad.diags, i, pattern)) break;
            } else {
                try w.print("ONLY-NO {s}: {t}\n", .{ f.path, bad.diags.at(i).code });
                return .met;
            }
        }
        try w.print("ONLY-OK {s}\n", .{f.path});
        return .met;
    }
    if (d.harness.reject_only) for (0..bad.diags.count()) |i| {
        if (bad.diags.at(i).severity != .err) continue;
        for (d.harness.reject) |pattern| {
            if (diagSays(&bad.diags, i, pattern)) break;
        } else {
            const e = bad.diags.at(i);
            try w.print("FAIL {s}: `//! reject-only`, and a second error fired: {t} {s}\n", .{ f.path, e.code, vera.diag.info(e.code).title });
            try printDiags(bad, w);
            return .unmet;
        }
    };
    return .met;
}

/// One compilation. Two failure modes are not Zig errors and get synthetic
/// names, matching the vocabulary the fixtures use:
///   `DiagnosticsReported`  — compiled, but a stage reported a message.
///   `GeneratedCompileError` — codegen deliberately emitted `@compileError`.
pub fn compileFixture(gpa: std.mem.Allocator, f: Fixture, source: []const u8, d: tb.Spec) !Outcome {
    var diags: vera.diag.Bag = .init(gpa);
    // Codegen too (not only the analysis `--lint` runs): some fixtures are
    // rejected by codegen emitting `@compileError`, which the analysis would
    // never see.
    var result = vera.analyze(gpa, source, .{
        .file_name = f.path,
        .include_dirs = &.{ f.dir(), harness.include_dir },
        // The suite's convention: a source includes the annex D files it uses.
        .require_std_includes = true,
        // Annex E.2: the fixture's `//! spice` cards, read as a netlist.
        .spice_netlist = d.harness.spice,
        .spice_path = f.path,
        .discipline_resolution = d.harness.discipline_resolution,
    }, &diags) catch |err| {
        if (err == error.OutOfMemory) {
            diags.deinit(gpa);
            return error.OutOfMemory;
        }
        return .{ .refused = .{ .error_name = @errorName(err), .diags = diags } };
    };
    defer result.deinit(gpa);

    if (diags.failed()) {
        return .{ .refused = .{ .error_name = "DiagnosticsReported", .diags = diags } };
    }

    var generated = result.generate(gpa, .{}, &diags) catch |err| {
        if (err == error.OutOfMemory) {
            diags.deinit(gpa);
            return error.OutOfMemory;
        }
        return .{ .refused = .{ .error_name = @errorName(err), .diags = diags } };
    };
    if (diags.failed()) {
        generated.deinit(gpa);
        return .{ .refused = .{ .error_name = "DiagnosticsReported", .diags = diags } };
    }
    // The compiler's own flag, not a text search: a kernel may carry
    // `@compileError` in a guard that never fires (`$table_model`'s does).
    if (generated.refused) {
        // The GPA-owned text moves into the failure, which frees it.
        return .{ .refused = .{
            .error_name = "GeneratedCompileError",
            .diags = diags,
            .generated = generated.output.text,
        } };
    }

    defer generated.deinit(gpa);
    diags.deinit(gpa);
    return .{ .accepted = generated.output.text.len };
}

/// `//! warn`: every pattern names a warning in `bag`. `//! nowarn`: `bag`
/// holds no warning. Detail goes to `w` on a miss.
pub fn warningsMet(bag: *vera.diag.Bag, f: Fixture, d: tb.Spec, w: *Io.Writer) !bool {
    for (d.harness.warn) |pattern| {
        for (0..bag.count()) |i| {
            if (bag.at(i).severity == .warning and diagSays(bag, i, pattern)) break;
        } else {
            try w.print("FAIL {s}: no warning matches: \"{s}\"\n", .{ f.path, pattern });
            vera.diag.render(bag, w, .{ .explain_hint = false, .summary = false }) catch {};
            return false;
        }
    }
    if (d.harness.nowarn and bag.count() != 0) {
        try w.print("FAIL {s}: `//! nowarn`, and the compile warned:\n", .{f.path});
        vera.diag.render(bag, w, .{ .explain_hint = false, .summary = false }) catch {};
        return false;
    }
    return true;
}

// ---- private ----

/// Whether the failure matches a `//! reject` pattern: a code, an error name,
/// `@compileError` text, a diagnostic substring, or a phase label derived from
/// the failure:
///   `DiagnosticsReported`  the failure carries at least one diagnostic.
///   `ParseError`           every diagnostic came from preprocess or parse.
fn failureContains(f: Failure, pattern: []const u8) bool {
    if (asCode(pattern) != null) {
        for (0..f.diags.count()) |i| if (diagSays(&f.diags, i, pattern)) return true;
        return false;
    }
    if (std.mem.find(u8, f.error_name, pattern) != null) return true;
    if (f.generated) |g| if (std.mem.find(u8, g, pattern) != null) return true;

    if (!f.diags.isEmpty()) {
        if (std.mem.eql(u8, pattern, "DiagnosticsReported")) return true;
        if (std.mem.eql(u8, pattern, "ParseError")) {
            for (0..f.diags.count()) |i| switch (f.diags.at(i).stage) {
                .preprocess, .parse => {},
                .lower, .proof, .codegen, .run => return false,
            };
            return true;
        }
    }
    for (0..f.diags.count()) |i| if (diagSays(&f.diags, i, pattern)) return true;
    return false;
}

/// Does diagnostic `i` say `pattern`: its code when `pattern` is one, else a
/// substring of its message, point, catalogue title or a note.
fn diagSays(bag: *const vera.diag.Bag, i: usize, pattern: []const u8) bool {
    const d = bag.at(i);
    if (asCode(pattern)) |want| return d.code == want;
    // The title too: much wording lives in `Info.title`, not the message.
    if (std.mem.find(u8, d.message, pattern) != null) return true;
    if (std.mem.find(u8, d.point, pattern) != null) return true;
    if (std.mem.find(u8, vera.diag.info(d.code).title, pattern) != null) return true;
    var nbuf: [vera.diag.max_children]vera.diag.Note = undefined;
    for (bag.notes(d, &nbuf)) |n| {
        if (std.mem.find(u8, n.text, pattern) != null) return true;
    }
    return false;
}

/// A directive is either a CODE (`E0313`, `W0650`) or a message substring.
///
/// Codes are preferred: they are stable and pin which rule fired.
fn asCode(pattern: []const u8) ?vera.diag.Code {
    if (pattern.len != 5) return null;
    if (pattern[0] != 'E' and pattern[0] != 'W') return null;
    for (pattern[1..]) |c| if (!std.ascii.isDigit(c)) return null;
    return std.meta.stringToEnum(vera.diag.Code, pattern);
}

fn printDiags(f: Failure, w: *Io.Writer) !void {
    // Render the real thing, so a failing fixture shows exactly what a user
    // would see — snippet, carets, notes and all. Colour is off: this output is
    // read from a log as often as from a terminal.
    var bag = f.diags;
    vera.diag.render(&bag, w, .{ .explain_hint = false, .summary = false }) catch {};
    // A `@compileError` carries the whole reason; without it
    // "GeneratedCompileError" says nothing about WHICH construct codegen refused.
    if (f.generated) |g| {
        var rest = g;
        while (std.mem.find(u8, rest, "@compileError")) |at| {
            const line_end = std.mem.findScalar(u8, rest[at..], '\n') orelse rest.len - at;
            try w.print("  codegen: {s}\n", .{rest[at .. at + line_end]});
            rest = rest[at + line_end ..];
        }
    }
}
