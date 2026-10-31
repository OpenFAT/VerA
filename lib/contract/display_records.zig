//! A device's latched status and its recorded display tasks in, the text a
//! host prints out: the §9.7.3 status code a `$fatal`/`$error` latches, the
//! §9.4 `Say` buffer a device's `say` fills, and their rendering through
//! `c_format.zig`.
//! Cites: VAMS-2023 §9.4.1 (`$debug` at every iteration, `$display` as
//! `$strobe`), §9.4.6 (output only at an accepted iteration), §9.5.9
//! (`$fdebug`), §9.7.3 (`$fatal`, `$error`), §5.2.1 (`analog initial`).
//!
//! Contents:
//! - `pub const StatusSite = struct`
//! - `pub const Severity = enum { fatal, @"error" }`
//! - `pub const SaySite = struct`
//! - `pub const Say = struct`, with `pub fn put` and `pub fn putDebug`
//! - `pub const SayPass = enum { all, iteration, accepted }`
//! - `pub fn statusCode(sev: Severity, site: usize) u32`
//! - `pub fn statusSite(comptime D: type, inst: *const D.Instance) ?StatusSite`
//! - `pub fn formatStatus(comptime D: type, inst: *const D.Instance, w: *std.Io.Writer) std.Io.Writer.Error!void`
//! - `pub fn formatSay(comptime D: type, s: *Say, name: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const c_format = @import("c_format.zig");
const testing = std.testing;
const mocks = @import("mock_devices.zig");

/// §9.7.3 one `$fatal`/`$error` call of a device (`D.status_sites`, in source
/// order). A device cannot print or stop its host, so the first one an
/// evaluation reaches latches `Instance.vera_status__` = `statusCode(site)`,
/// with up to four numeric arguments in `Instance.vera_status_args__`. While
/// it is latched (until `initState` or `setupInstance`), `eval`, `q` and `evalQ`
/// return all-zero rows and charges (value and every derivative lane) and
/// `updateState` changes nothing, so a host polls the field after a solve
/// and renders it with `formatStatus`. Optional: a device without it has no
/// such site.
pub const StatusSite = struct {
    severity: Severity,
    /// The call's format string, "" when it has none.
    fmt: []const u8,
    /// Where the call is, for the message.
    file: []const u8,
    line: u32,
};

/// Which §9.7.3 task latched a status: the top byte of its code, 1 or 2.
pub const Severity = enum { fatal, @"error" };

/// §9.4 one display task of a device (`D.say_sites`, in source order):
/// a `$strobe`, `$display`, `$write`, `$debug`, `$warning` or `$info` in the
/// analog context. A device cannot print, so its optional `say` entry point,
///
///     pub fn say(comptime S: type, x: *const [n_u]S.V, model: *const Model,
///                inst: InstancePtr, sim: SimState, out: *Say) void
///
/// runs the model's display tasks at `x` and records each one that runs into
/// `out`, as this site's index and `nargs` values; the host renders the
/// records with `formatSay`. A host calls it once per ACCEPTED point, after
/// the solve and before `updateState`, with the `Instance` `eval` saw:
/// §9.4.6, "All the display tasks, except $debug, shall not display output
/// unless an iteration has been accepted", which is also when `$display`
/// prints, since §9.4.1 gives it "the same capabilities as $strobe".
/// `$debug` "displays its arguments for each iteration of the analog solver"
/// (§9.4.1): a host that shows it so also calls `say` after each Newton
/// iteration, at that iterate, with `Say.pass = .iteration`, and then passes
/// `.accepted` at the accepted point (`SayPass`).
/// `$monitor` (it needs change detection a device does not keep) and a task
/// with a string argument that is not a constant are not recorded (W0850).
/// Optional: a host that never calls `say` is unaffected, and a GPU host
/// does not compile it.
pub const SaySite = struct {
    /// The task's text as one C-style format: its constant strings are in
    /// it, and each conversion (`%d %i %c %h %x %o %b %e %f %g %r`, with
    /// flags, width and precision) takes the next recorded value; `%%` is
    /// `%` and `%m` the instance's name, which the host supplies. A
    /// line-ending task's format ends in `\n`, and `$warning`/`$info`'s
    /// begin with `WARNING: `/`INFO: `.
    fmt: []const u8,
    /// Where the call is.
    file: []const u8,
    line: u32,
    /// The values one record of this site carries after its index.
    nargs: u32,
};

/// The buffer a host lends `D.say`: records `site, v0, ..., v(nargs - 1)`
/// back to back as f64. A record that does not fit is counted in `lost` and
/// dropped whole. Fixed storage and no allocation, so `say` compiles
/// wherever `eval` does. Invariant: `len <= buf.len`, and `buf[0..len]` is
/// whole records.
pub const Say = struct {
    /// Borrowed from the host for as long as it renders the records.
    buf: []f64,
    len: usize = 0,
    lost: usize = 0,
    /// Which tasks this call records (§9.4.6).
    pass: SayPass = .all,

    /// Appends one record of site `site`, a task other than `$debug`; a
    /// device's `say` calls it. Asserts the `Say` invariant.
    pub fn put(s: *Say, site: u32, args: []const f64) void {
        if (s.pass != .iteration) s.record(site, args);
    }

    /// Appends one record of `$debug` site `site`; a device's `say` calls it.
    /// Asserts the `Say` invariant.
    pub fn putDebug(s: *Say, site: u32, args: []const f64) void {
        if (s.pass != .accepted) s.record(site, args);
    }

    // ---- private ----

    fn record(s: *Say, site: u32, args: []const f64) void {
        assert(s.len <= s.buf.len);
        if (s.buf.len - s.len < 1 + args.len) {
            s.lost += 1;
            return;
        }
        const len_before = s.len;
        s.buf[s.len] = @floatFromInt(site);
        @memcpy(s.buf[s.len + 1 ..][0..args.len], args);
        s.len += 1 + args.len;
        assert(s.len == len_before + 1 + args.len);
        assert(s.len <= s.buf.len);
    }
};

/// §9.4.6 which display tasks one `say` call records, or one call of a
/// printing device's optional `displayPass` (the same parameters as
/// `display`, then `comptime pass: SayPass`; `display` is its `.all`) runs,
/// `$fdebug` with `$debug` (§9.5.9) and an `analog initial` block's §9.5 calls
/// at the first iterate's `.iteration` pass (§5.2.1). "All the display
/// tasks, except $debug, shall not display output unless an iteration has
/// been accepted", and §9.4.1's `$debug` "displays its arguments for each
/// iteration of the analog solver".
pub const SayPass = enum {
    /// Every task, `$debug` included: a host that calls `say` only at
    /// accepted points, which then shows `$debug` at those alone.
    all,
    /// `$debug` alone: after a Newton iteration, at its iterate.
    iteration,
    /// Every task but `$debug`: the accepted point of a host that runs the
    /// `.iteration` passes, which already showed it there.
    accepted,
};

/// Site 0-based index past which `statusCode` would spill into the severity
/// byte.
const status_sites_max = 0xff_ffff - 1;

/// The `vera_status__` value site index `site` (0-based) of severity `sev`
/// latches: the severity in the top byte (1 fatal, 2 error), `site + 1` below.
/// Asserts that `site + 1` fits the low 24 bits, so the code cannot spill
/// into the severity byte.
pub fn statusCode(sev: Severity, site: usize) u32 {
    assert(site <= status_sites_max);
    const code = (@as(u32, if (sev == .fatal) 1 else 2) << 24) | @as(u32, @intCast(site + 1));
    assert(code & 0xff_ffff != 0); // 0 is "nothing latched".
    return code;
}

/// The site `D`'s latched status names, or null when `inst` reports none
/// (nothing latched, or a code naming no site of `D.status_sites`).
pub fn statusSite(comptime D: type, inst: *const D.Instance) ?StatusSite {
    if (!@hasDecl(D, "status_sites") or inst.vera_status__ == 0) return null;
    // A severity byte over site bits 0 wraps to a huge index: none.
    const k = (inst.vera_status__ & 0xff_ffff) -% 1;
    if (k >= D.status_sites.len) return null;
    assert(k <= status_sites_max);
    return D.status_sites[k];
}

/// Writes `D`'s latched status as `<file>:<line>: fatal|error: <message>`,
/// the message being the site's format rendered by `formatSay`'s rules over
/// its numeric arguments (`%s` writes `?`: a string has no numeric slot).
/// Writes nothing when `inst` reports no status. Fails only as `w` does.
pub fn formatStatus(comptime D: type, inst: *const D.Instance, w: *Writer) Writer.Error!void {
    const s = statusSite(D, inst) orelse return;
    assert(inst.vera_status__ != 0);
    try w.print("{s}:{d}: {s}: ", .{ s.file, s.line, @tagName(s.severity) });
    try c_format.formatC(s.fmt, &inst.vera_status_args__, "", w);
}

/// Writes the records `D.say` put in `s`, each as its site's format renders
/// it (`c_format.formatC`), `name` standing for `%m`; then, if any record did
/// not fit, a line saying how many. Empties `s` for the next accepted point;
/// on an error from `w` it is left as it was. Asserts that every record was put by
/// `D.say`, so its site indexes `D.say_sites` and carries that site's
/// `nargs` values.
pub fn formatSay(comptime D: type, s: *Say, name: []const u8, w: *Writer) Writer.Error!void {
    assert(s.len <= s.buf.len);
    var i: usize = 0;
    while (i < s.len) {
        const site = D.say_sites[@intFromFloat(s.buf[i])];
        assert(i + 1 + site.nargs <= s.len);
        try c_format.formatC(site.fmt, s.buf[i + 1 ..][0..site.nargs], name, w);
        i += 1 + site.nargs;
    }
    assert(i == s.len);
    if (s.lost != 0) try w.print("[{d} display record(s) did not fit the host's buffer]\n", .{s.lost});
    s.len = 0;
    s.lost = 0;
}

test "formatStatus renders the latched site with its numeric arguments" {
    var inst: mocks.MockAll.Instance = .{};
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatStatus(mocks.MockAll, &inst, &w);
    try testing.expectEqualStrings("", w.buffered());
    inst.vera_status__ = statusCode(.@"error", 0);
    inst.vera_status_args__ = .{ 2.5, 7, 0, 0 };
    try formatStatus(mocks.MockAll, &inst, &w);
    try testing.expectEqualStrings("m.va:3: error: g = 2.5% of ?", w.buffered());
    try testing.expectEqual(@as(u32, 0x0200_0001), inst.vera_status__);
}

test "formatSay renders each record with its site's format, then what did not fit" {
    var store: [7]f64 = undefined;
    var s: Say = .{ .buf = &store };
    const x = [2]f64{ 1.25, 0.25 };
    mocks.MockAll.say(f64, &x, undefined, undefined, .{}, &s);
    mocks.MockAll.say(f64, &x, undefined, undefined, .{}, &s);
    mocks.MockAll.say(f64, &x, undefined, undefined, .{}, &s); // 9 values do not fit 7
    try testing.expectEqual(@as(usize, 6), s.len);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatSay(mocks.MockAll, &s, "x1", &w);
    try testing.expectEqualStrings("? v = 1.000 ok=1\n? v = 1.000 ok=1\n[1 display record(s) did not fit the host's buffer]\n", w.buffered());
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "SayPass: `$debug` records on the iteration pass, the rest on the accepted one" {
    var store: [8]f64 = undefined;
    const one = [_]f64{1.0};
    for ([_]SayPass{ .all, .iteration, .accepted }, [_][]const f64{ &.{ 0, 1, 1, 1 }, &.{ 1, 1 }, &.{ 0, 1 } }) |pass, want| {
        var s: Say = .{ .buf = &store, .pass = pass };
        s.put(0, &one);
        s.putDebug(1, &one);
        try testing.expectEqualSlices(f64, want, store[0..s.len]);
    }
}

test "statusCode/statusSite: the severity byte over the 1-based site; a site past the table is none" {
    try testing.expectEqual(@as(u32, 0x0100_0001), statusCode(.fatal, 0));
    try testing.expectEqual(@as(u32, 0x0200_0003), statusCode(.@"error", 2));
    var inst: mocks.MockAll.Instance = .{};
    try testing.expect(statusSite(mocks.MockAll, &inst) == null); // 0: nothing latched
    inst.vera_status__ = statusCode(.fatal, 0);
    try testing.expectEqual(@as(u32, 3), statusSite(mocks.MockAll, &inst).?.line);
    // mocks.MockAll has one site; a code naming a second names none.
    inst.vera_status__ = statusCode(.@"error", 1);
    try testing.expect(statusSite(mocks.MockAll, &inst) == null);
    // A severity byte over site bits 0: the 1-based index wraps, still none.
    inst.vera_status__ = 0x0100_0000;
    try testing.expect(statusSite(mocks.MockAll, &inst) == null);
}

test "Say: a record that fills the buffer exactly is kept; the next is lost whole" {
    var store: [3]f64 = undefined;
    var s: Say = .{ .buf = &store };
    s.put(4, &.{ 1.5, 2.5 });
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqualSlices(f64, &.{ 4, 1.5, 2.5 }, store[0..3]);
    s.put(0, &.{}); // even a bare site index no longer fits
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(@as(usize, 1), s.lost);
    // A zero-length buffer loses every record the pass takes, and only those.
    var empty: [0]f64 = .{};
    var none: Say = .{ .buf = &empty, .pass = .iteration };
    none.putDebug(0, &.{});
    none.put(0, &.{}); // not `$debug`: the iteration pass skips it, uncounted
    try testing.expectEqual(@as(usize, 1), none.lost);
    // formatSay with only losses prints the count and resets it.
    var buf: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatSay(mocks.MockAll, &none, "", &w);
    try testing.expectEqualStrings("[1 display record(s) did not fit the host's buffer]\n", w.buffered());
    try testing.expectEqual(@as(usize, 0), none.lost);
}
