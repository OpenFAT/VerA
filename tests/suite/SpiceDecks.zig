//! The `spice` mode: each `.sp` deck (a SPICE netlist with `.hdl "model.va"`
//! cards and an `.expected.json` analytic oracle) -> PASS or FAIL. First the
//! half every deck needs: the oracle exists, every `.hdl` model resolves
//! (`resolveModel`) and compiles under `vera --check`. Then `execute` runs
//! the deck on the ESPice CLI, a full SPICE simulator, with `--format=csv`,
//! and `grade` holds the CSV to the oracle's own values and tolerances.
//! espice runs every deck or the deck FAILs: nothing is skipped.
//!
//! After the mode word: `--espice=PATH` names the executable (required),
//! `--results=PATH` writes the per-deck ledger, a bare word filters the
//! decks, and any other `--` argument is espice's own, forwarded untouched
//! (`--backend=cuda`, `--jobs=4`): CPU or GPU is never VerA's decision.
//!
//!   zig build test-spice -Despice=PATH                    # an espice built elsewhere
//!   zig build test-spice -Despice=PATH -- timer           # the decks whose name contains timer
//!   zig build test-spice -Despice=PATH -- --backend=cuda  # forwarded to espice
//!
//! Contents:
//! - `pub fn run(init: std.process.Init, vera_exe: []const u8, args: *Args) !u8`

const Fixtures = @import("Fixtures.zig");
const Child = @import("Child.zig");
const std = @import("std");
const options = @import("suite_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Args = std.process.Args.Iterator;

const harness = Fixtures;
const child = Child;

const Verdict = union(enum) {
    /// What was checked.
    pass: []const u8,
    fail: []const u8,
};

/// One plot of espice's CSV: `names[i]` heads `cols[i]`, and column 0 is the
/// axis (`time`, `frequency`).
const Table = struct {
    names: []const []const u8,
    cols: []const []const f64,
};

/// The `spice` mode: checks, then runs on espice, each `.sp` deck matching
/// the filter in `args`, printing one PASS/FAIL line per deck and a census to
/// stderr. Exit 1 on any FAIL or when nothing matched, 2 without `--espice=`.
pub fn run(init: std.process.Init, vera_exe: []const u8, args: *Args) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var filter: ?[]const u8 = null;
    var results_path: ?[]const u8 = null;
    var espice: ?[]const u8 = null;
    var espice_args: std.ArrayList([]const u8) = .empty;
    while (args.next()) |a| {
        if (std.mem.cutPrefix(u8, a, "--results=")) |path| {
            results_path = path;
        } else if (std.mem.cutPrefix(u8, a, "--espice=")) |path| {
            espice = path;
        } else if (std.mem.startsWith(u8, a, "--")) {
            // espice's own (`--backend=cuda`, `--jobs=4`), untouched: where a
            // deck runs is espice's decision.
            try espice_args.append(arena_state.allocator(), a);
        } else {
            filter = a;
        }
    }
    const espice_name = espice orelse return harness.usage(io, "spice: --espice=PATH names the espice executable");
    // A built espice is build.zig's cwd-relative `.zig-cache/o/...` path and
    // espice runs from each deck's directory; a bare name stays PATH's.
    const espice_exe: []const u8 = if (std.mem.findScalar(u8, espice_name, std.fs.path.sep) != null)
        try Io.Dir.cwd().realPathFileAlloc(io, espice_name, arena_state.allocator())
    else
        espice_name;
    var results: Io.Writer.Allocating = .init(gpa);
    defer results.deinit();

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    // The decks: every `.sp` with an `.expected.json` beside it under the AMS
    // directories (`harness.ams_dirs`), relative to the fixture root. Never
    // the suite's `netlist/` (ESPice's own decks), nor VerA's
    // `vera/osdi/*.sp` (ngspice `.control` decks `tools/external_analog.py`
    // runs, with no `.hdl` card and no `.expected.json`).
    var decks: std.ArrayList([]const u8) = .empty;
    defer decks.deinit(gpa);
    for (harness.ams_dirs) |sub| {
        const pa = arena_state.allocator();
        var root = Io.Dir.cwd().openDir(io, try std.fs.path.join(pa, &.{ options.fixture_root, sub }), .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer root.close(io);
        var walker = try root.walk(pa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".sp")) continue;
            const oracle = try pa.print("{s}.expected.json", .{entry.path[0 .. entry.path.len - ".sp".len]});
            if (root.access(io, oracle, .{})) |_| {} else |_| continue;
            try decks.append(gpa, try std.fs.path.join(pa, &.{ sub, entry.path }));
        }
    }
    std.mem.sort([]const u8, decks.items, {}, harness.strLess);

    var ran: usize = 0;
    var failed: usize = 0;
    var passed: usize = 0;
    for (decks.items) |rel| {
        if (filter) |f| if (std.mem.find(u8, rel, f) == null) continue;
        ran += 1;
        var status: []const u8 = "fail";
        defer if (results_path != null) {
            results.writer.print("{s}\tspice.test.{s}\n", .{ status, rel }) catch @panic("OOM");
        };
        const pa = arena_state.allocator();
        const path = try std.fs.path.join(pa, &.{ options.fixture_root, rel });
        const dir_path = std.fs.path.dirname(path) orelse ".";
        const name = std.fs.path.basename(rel);
        var bad = false;

        // 1. The oracle, which the walk saw beside the deck.
        const stem = path[0 .. path.len - ".sp".len];
        const oracle_path = try pa.print("{s}.expected.json", .{stem});
        const oracle = Io.Dir.cwd().readFileAlloc(io, oracle_path, pa, .limited(1 << 20)) catch blk: {
            try w.print("FAIL {s}: no .expected.json beside it\n", .{name});
            bad = true;
            break :blk "";
        };

        // 2. Every model the deck names, one `.hdl "<path>"` per line.
        const source = try Io.Dir.cwd().readFileAlloc(io, path, pa, .limited(1 << 20));
        var lines = std.mem.splitScalar(u8, source, '\n');
        var models: usize = 0;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, ".hdl")) continue;
            const open = std.mem.findScalar(u8, line, '"') orelse continue;
            const rest = line[open + 1 ..];
            const close = std.mem.findScalar(u8, rest, '"') orelse continue;
            const ref = rest[0..close];

            const model = (try resolveModel(pa, io, dir_path, ref)) orelse {
                try w.print("FAIL {s}: .hdl \"{s}\" resolves to no file\n", .{ name, ref });
                bad = true;
                continue;
            };
            models += 1;
            // 3. VerA's own half: the model has to compile. `--check` and both
            //    include dirs: `check.vh` is in the suite's `include/` and the
            //    model's siblings are beside it.
            const r = child.capture(pa, io, &.{
                vera_exe, "--check",           "--contract", options.contract,
                "-I",     harness.include_dir, "-I",         dir_path,
                model,
            }) catch |e| {
                try w.print("FAIL {s}: could not run vera: {s}\n", .{ name, @errorName(e) });
                bad = true;
                continue;
            };
            if (r.exit != 0) {
                try w.print("FAIL {s}: model {s} does not compile\n{s}", .{
                    name, std.fs.path.basename(model), r.stderr,
                });
                bad = true;
            }
        }
        if (models == 0 and !bad) {
            try w.print("FAIL {s}: no .hdl card, so the deck names no model\n", .{name});
            bad = true;
        }
        if (bad) {
            failed += 1;
            continue;
        }

        // 4. Run it on espice and hold its CSV to the oracle.
        const verdict = try execute(pa, io, espice_exe, espice_args.items, std.fs.path.basename(stem), path, dir_path, analysisOf(source), oracle);
        switch (verdict) {
            .pass => |what| {
                try w.print("PASS {s}: {s}\n", .{ name, what });
                passed += 1;
                status = "pass";
            },
            .fail => |why| {
                try w.print("FAIL {s}: {s}\n", .{ name, why });
                failed += 1;
            },
        }
    }
    if (results_path) |path| {
        if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = results.written() });
    }

    if (ran == 0) {
        try w.print("spice: nothing matched `{s}`\n", .{filter orelse ""});
        return 1;
    }
    try w.print("spice: {d}/{d} decks executed on espice and match their oracle; {d} FAIL\n", .{ passed, ran, failed });
    return if (failed == 0) 0 else 1;
}

// ---- private ----

/// `.hdl` paths are relative to the deck, exactly as written.
fn resolveModel(arena: Allocator, io: Io, dir_path: []const u8, ref: []const u8) !?[]const u8 {
    const literal = try std.fs.path.join(arena, &.{ dir_path, ref });
    if (Io.Dir.cwd().access(io, literal, .{})) |_| return literal else |_| {}
    return null;
}

/// The deck's analysis as the oracle's `analysis` names it: its first
/// `.tran`, `.noise`, `.ac`, `.dc` or `.op` card without the dot. SPICE cards
/// are case-insensitive. Null when the deck has none.
fn analysisOf(source: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeAny(u8, raw, " \t\r");
        const card = it.next() orelse continue;
        if (card[0] != '.') continue;
        for ([_][]const u8{ "tran", "noise", "ac", "dc", "op" }) |a| {
            if (std.ascii.eqlIgnoreCase(card[1..], a)) return a;
        }
    }
    return null;
}

/// Runs `deck` on espice, its CSV in a fresh `<work_root>/spice/<stem>/`, and
/// grades what it wrote against `oracle_text`.
fn execute(
    arena: Allocator,
    io: Io,
    espice: []const u8,
    espice_args: []const []const u8,
    stem: []const u8,
    deck: []const u8,
    dir_path: []const u8,
    analysis: ?[]const u8,
    oracle_text: []const u8,
) !Verdict {
    const work = try std.fs.path.join(arena, &.{ options.work_root, "spice", stem });
    // An earlier run's `<stem>.csv.2` would be read as this run's second plot.
    try Io.Dir.cwd().deleteTree(io, work);
    try Io.Dir.cwd().createDirPath(io, work);
    const out = try std.fs.path.join(arena, &.{ work, try arena.print("{s}.csv", .{stem}) });
    // `-I`: the models `include "check.vh"` from the suite's `include/`, as
    // the `vera --check` half is told; espice searches a model's own
    // directory and each `-I` for its `.hdl` includes.
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{ espice, "--format=csv", "-r", out, "-I", harness.include_dir }, espice_args, &.{deck} });
    // From the deck's directory, as `.hdl` paths are written relative to it;
    // `deck` and `out` are absolute.
    const r = child.captureIn(arena, io, argv, dir_path) catch |e|
        return .{ .fail = try arena.print("could not run {s}: {s}", .{ espice, @errorName(e) }) };
    if (r.exit != 0) return .{ .fail = try arena.print("espice exited {d}:\n{s}", .{ r.exit, r.stderr }) };
    return grade(arena, io, analysis, out, oracle_text);
}

/// Reads `text` as espice's `--format=csv` writes it: a header of names, then
/// one row of numbers per point. A name holding `,` or `"` is quoted with its
/// `"` doubled (RFC 4180). A row whose field count is not the header's, or a
/// field that is not a number, is `error.BadCsv`.
fn parseCsv(arena: Allocator, text: []const u8) !Table {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = std.mem.trimEnd(u8, lines.first(), "\r");
    var names: std.ArrayList([]const u8) = .empty;
    var name: std.ArrayList(u8) = .empty;
    var quoted = false;
    var i: usize = 0;
    while (i < header.len) : (i += 1) {
        const c = header[i];
        if (quoted) {
            if (c != '"') {
                try name.append(arena, c);
            } else if (i + 1 < header.len and header[i + 1] == '"') {
                try name.append(arena, '"');
                i += 1;
            } else quoted = false;
        } else if (c == '"') {
            quoted = true;
        } else if (c == ',') {
            try names.append(arena, name.items);
            name = .empty;
        } else try name.append(arena, c);
    }
    if (quoted) return error.BadCsv;
    try names.append(arena, name.items);

    const cols = try arena.alloc(std.ArrayList(f64), names.items.len);
    @memset(cols, .empty);
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ',');
        for (cols) |*col| {
            const f = fields.next() orelse return error.BadCsv;
            try col.append(arena, std.fmt.parseFloat(f64, f) catch return error.BadCsv);
        }
        if (fields.next() != null) return error.BadCsv;
    }
    const flat = try arena.alloc([]const f64, cols.len);
    for (cols, flat) |c, *f| f.* = c.items;
    return .{ .names = names.items, .cols = flat };
}

/// The column `name` of `tables`, ignoring case as SPICE does, and the axis
/// of the table holding it. A run may also write an operating point (one row
/// of the same `v(...)` names) or several plots, so the tables on the
/// analysis's own axis (`time` for tran, `frequency` for noise and ac) are
/// searched first, then every table in file order.
fn column(tables: []const Table, analysis: []const u8, name: []const u8) ?struct { axis: []const f64, col: []const f64 } {
    const own: ?[]const u8 = if (std.mem.eql(u8, analysis, "tran"))
        "time"
    else if (std.mem.eql(u8, analysis, "noise") or std.mem.eql(u8, analysis, "ac"))
        "frequency"
    else
        null;
    if (own) |axis| for (tables) |t| if (std.ascii.eqlIgnoreCase(t.names[0], axis)) {
        for (t.names, t.cols) |n, c| if (std.ascii.eqlIgnoreCase(n, name)) return .{ .axis = t.cols[0], .col = c };
    };
    for (tables) |t| for (t.names, t.cols) |n, c| if (std.ascii.eqlIgnoreCase(n, name)) return .{ .axis = t.cols[0], .col = c };
    return null;
}

fn num(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn fieldNum(v: std.json.Value, key: []const u8, default: f64) f64 {
    return num(field(v, key) orelse return default) orelse default;
}

fn numbers(arena: Allocator, v: ?std.json.Value) ![]const f64 {
    const arr = (v orelse return error.BadOracle);
    if (arr != .array) return error.BadOracle;
    const out = try arena.alloc(f64, arr.array.items.len);
    for (arr.array.items, out) |e, *o| o.* = num(e) orelse return error.BadOracle;
    return out;
}

/// `|got - want| <= atol + rtol*|want|`, the oracle's tolerance.
fn within(got: f64, want: f64, rtol: f64, atol: f64) bool {
    return @abs(got - want) <= atol + rtol * @abs(want);
}

/// Linear interpolation of `col` over `axis` at `a`, inside the run only.
fn sampleAt(axis: []const f64, col: []const f64, a: f64) ?f64 {
    if (axis.len == 0 or a < axis[0] or a > axis[axis.len - 1]) return null;
    for (axis[1..], 1..) |hi, i| if (a <= hi) {
        const lo = axis[i - 1];
        if (hi == lo) return col[i];
        return col[i - 1] + (col[i] - col[i - 1]) * (a - lo) / (hi - lo);
    };
    return col[col.len - 1];
}

/// Holds espice's CSV at `out` to the oracle. CSV holds one plot per file, so
/// a run's second plot is `out.2`, its third `out.3`, and a graded column is
/// found by name across them (`column`). Reads `analysis`,
/// `expect.status`, `expect.plots` (`match` `exact`: that column's table has
/// the same rows, or `samples`: each column interpolated at the axis values),
/// `expect.checks` (`selected_values`: a row at exactly each coordinate) and
/// `finite_values_required`. Anything else in `expect` it does not know is a
/// FAIL, never a skip.
fn grade(arena: Allocator, io: Io, analysis: ?[]const u8, out: []const u8, oracle_text: []const u8) !Verdict {
    const oracle = std.json.parseFromSliceLeaky(std.json.Value, arena, oracle_text, .{}) catch
        return .{ .fail = "the oracle is not JSON" };
    const runs = analysis orelse return .{ .fail = "the deck has no .tran, .noise, .ac, .dc or .op card" };
    const want_analysis = field(oracle, "analysis") orelse return .{ .fail = "the oracle names no analysis" };
    if (want_analysis != .string or !std.mem.eql(u8, want_analysis.string, runs))
        return .{ .fail = try arena.print("the oracle is a {s} analysis and the deck runs {s}", .{ if (want_analysis == .string) want_analysis.string else "?", runs }) };
    const expect = field(oracle, "expect") orelse return .{ .fail = "the oracle has no expect" };
    var it = expect.object.iterator();
    while (it.next()) |e| {
        const known = [_][]const u8{ "status", "plots", "checks", "finite_values_required", "all_requested_analyses_must_complete" };
        for (known) |k| {
            if (std.mem.eql(u8, k, e.key_ptr.*)) break;
        } else return .{ .fail = try arena.print("the oracle's expect.{s} is not graded by this harness", .{e.key_ptr.*}) };
    }
    if (field(expect, "status")) |s| if (s != .string or !std.mem.eql(u8, s.string, "success"))
        return .{ .fail = "the oracle expects a status other than success" };

    var tables: std.ArrayList(Table) = .empty;
    var read: std.ArrayList(u8) = .empty; // the files, for the FAIL line
    var path = out;
    while (true) {
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| switch (e) {
            error.FileNotFound => break,
            else => return .{ .fail = try arena.print("cannot read {s}: {s}", .{ path, @errorName(e) }) },
        };
        const table = parseCsv(arena, text) catch
            return .{ .fail = try arena.print("espice wrote a malformed line in {s}", .{path}) };
        try tables.append(arena, table);
        try read.print(arena, " {s}", .{path});
        path = try arena.print("{s}.{d}", .{ out, tables.items.len + 1 });
    }
    var rows: usize = 0;
    for (tables.items) |t| rows += t.cols[0].len;
    if (rows == 0) return .{ .fail = try arena.print("espice wrote no {s} plot; files read:{s}", .{ runs, if (read.items.len == 0) " none" else read.items }) };
    if (field(expect, "finite_values_required")) |f| if (f == .bool and f.bool) {
        for (tables.items) |t| for (t.cols) |c| for (c) |v| if (!std.math.isFinite(v)) return .{ .fail = "a value is not finite" };
    };

    var checked: usize = 0;
    if (field(expect, "plots")) |plots| for (plots.array.items) |p| {
        const match = (field(p, "match") orelse return .{ .fail = "a plot without match" }).string;
        const ax = field(p, "axis") orelse return .{ .fail = "a plot without axis" };
        const want_axis = try numbers(arena, field(ax, "values"));
        const exact = std.mem.eql(u8, match, "exact");
        if (!exact and !std.mem.eql(u8, match, "samples")) return .{ .fail = try arena.print("plot match `{s}` is not graded", .{match}) };
        const columns = field(p, "columns") orelse return .{ .fail = "a plot without columns" };
        var ci = columns.object.iterator();
        while (ci.next()) |c| {
            const t = column(tables.items, runs, c.key_ptr.*) orelse return .{ .fail = try arena.print("espice wrote no column `{s}`", .{c.key_ptr.*}) };
            if (exact) {
                const rc = fieldNum(p, "row_count", @floatFromInt(want_axis.len));
                if (t.axis.len != want_axis.len or rc != @as(f64, @floatFromInt(t.axis.len)))
                    return .{ .fail = try arena.print("{d} rows, the oracle wants {d}", .{ t.axis.len, want_axis.len }) };
                for (t.axis, want_axis) |g, wv| if (!within(g, wv, fieldNum(ax, "rtol", 0), fieldNum(ax, "atol", 0)))
                    return .{ .fail = try arena.print("axis value {e}, the oracle wants {e}", .{ g, wv }) };
            }
            const want = try numbers(arena, field(c.value_ptr.*, "values"));
            if (want.len != want_axis.len) return .{ .fail = "an oracle column's length differs from its axis" };
            const rtol = fieldNum(c.value_ptr.*, "rtol", 0);
            const atol = fieldNum(c.value_ptr.*, "atol", 0);
            for (want_axis, want, 0..) |a, wv, i| {
                const g = if (exact) t.col[i] else sampleAt(t.axis, t.col, a) orelse
                    return .{ .fail = try arena.print("{s} at {e} is outside the run", .{ c.key_ptr.*, a }) };
                if (!within(g, wv, rtol, atol))
                    return .{ .fail = try arena.print("{s} at {e} = {e}, the oracle wants {e} (rtol {e}, atol {e})", .{ c.key_ptr.*, a, g, wv, rtol, atol }) };
                checked += 1;
            }
        }
    };
    if (field(expect, "checks")) |checks| for (checks.array.items) |ck| {
        const kind = (field(ck, "kind") orelse return .{ .fail = "a check without kind" }).string;
        if (!std.mem.eql(u8, kind, "selected_values")) return .{ .fail = try arena.print("check kind `{s}` is not graded", .{kind}) };
        // ponytail: `period` folds a coordinate into one period of a periodic
        // run. Every deck's period exceeds its run, so it is not applied.
        const cname = (field(ck, "column") orelse return .{ .fail = "a check without column" }).string;
        const t = column(tables.items, runs, cname) orelse return .{ .fail = try arena.print("espice wrote no column `{s}`", .{cname}) };
        const coords = try numbers(arena, field(ck, "coordinates"));
        const want = try numbers(arena, field(ck, "values"));
        if (coords.len != want.len) return .{ .fail = "a check's coordinates and values differ in length" };
        for (coords, want) |cv, wv| {
            // The coordinate itself must be an accepted point: interpolation
            // across it would hide a missing timepoint.
            const i = std.mem.findScalar(f64, t.axis, cv) orelse
                return .{ .fail = try arena.print("MissingCoordinate: no accepted point at {e}", .{cv}) };
            if (!within(t.col[i], wv, fieldNum(ck, "rtol", 0), fieldNum(ck, "atol", 0)))
                return .{ .fail = try arena.print("{s} at {e} = {e}, the oracle wants {e}", .{ cname, cv, t.col[i], wv }) };
            checked += 1;
        }
    };
    if (checked == 0) return .{ .fail = "the oracle states no value, so nothing was graded" };
    return .{ .pass = try arena.print("{s}, {d} values within the oracle over {d} rows", .{ runs, checked, rows }) };
}

test "parseCsv reads espice's CSV, and column prefers the analysis's own axis" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // f64, as espice prints them: a `comptime_float` prints at f128 precision.
    const third: f64 = 1.0 / 3.0;
    const t = try parseCsv(a, try a.print("time,\"v(a,\"\"b\"\")\"\n0e0,{e}\n{e},-inf\n", .{ third, @as(f64, 1e-4) }));
    try std.testing.expectEqualStrings("time", t.names[0]);
    try std.testing.expectEqualStrings("v(a,\"b\")", t.names[1]);
    try std.testing.expectEqualSlices(f64, &.{ 0, 1e-4 }, t.cols[0]);
    try std.testing.expectEqualSlices(f64, &.{ third, -std.math.inf(f64) }, t.cols[1]);
    try std.testing.expectError(error.BadCsv, parseCsv(a, "time,v(out)\n0e0,1e0\n1e-4\n"));

    // An operating point written first holds `v(out)` too: the time-axis
    // table's wins, and `v(in)`, on no time axis, falls back to the first.
    const tables = [_]Table{
        try parseCsv(a, "v(in),v(out)\n1e0,5e-1\n"),
        try parseCsv(a, "Time,v(out)\n0e0,5e-1\n1e-3,7.5e-1\n"),
    };
    try std.testing.expectEqualSlices(f64, &.{ 5e-1, 7.5e-1 }, column(&tables, "tran", "V(OUT)").?.col);
    try std.testing.expectEqualSlices(f64, &.{1e0}, column(&tables, "tran", "v(in)").?.col);
}

test "analysisOf names the deck's first analysis card, past comments and .hdl" {
    try std.testing.expectEqualStrings("noise", analysisOf("* a .tran in a comment\n.hdl \"m.va\"\n.NOISE v(out) v1 dec 1 1 10\n.tran 1 2\n").?);
    try std.testing.expect(analysisOf("R1 a 0 1k\n.options reltol=1e-4\n.end\n") == null);
}
