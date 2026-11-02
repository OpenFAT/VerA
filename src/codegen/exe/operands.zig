//! Directive operands: the text after one `//!` keyword in, its value out
//! (a number, a binding list, an unknown's `U` member, one device-table row).
//! Every function fails with the `ParseError` that names what was wrong.
//! Cites: §1.3.1.1, §2.6, §2.9.2, §3.2.1, §3.4.3, §3.6.3, §3.6.3.1, §4.6.3,
//! §4.6.4.3, §4.6.4.4, §4.6.4.6, §5.4.2, §5.4.3, §6.5.2, §9.17.3.
//!
//! Contents:
//! - `pub fn validSection(cite: []const u8) bool`
//! - `pub fn validInherited(s: []const u8) bool`
//! - `pub fn digits(s: []const u8) bool`
//! - `pub fn number(raw: []const u8) ParseError!f64`
//! - `pub fn numbers(arena: Allocator, rest: []const u8) ParseError![]const f64`
//! - `pub fn bindings(arena: Allocator, rest: []const u8, out: *std.ArrayList(Binding)) ParseError!void`
//! - `pub fn unknownName(arena: Allocator, raw: []const u8) ParseError![]const u8`
//! - `pub fn plusargs(arena: Allocator, rest: []const u8, out: *std.ArrayList([]const u8)) ParseError!void`
//! - `pub fn noiseEntry(arena: Allocator, s: []const u8) ParseError!NoiseWant`
//! - `pub fn metaEntry(arena: Allocator, s: []const u8) ParseError![]const u8`
//! - `pub fn acEntry(arena: Allocator, s: []const u8) ParseError!AcWant`
//! - `pub fn acDynEntry(arena: Allocator, s: []const u8) ParseError!AcDynWant`
//! - `pub fn limitCase(arena: Allocator, rest: []const u8) ParseError!LimitCase`

const std = @import("std");
const naming = @import("ir").names;
const token_value = @import("frontend").token_value;
const spec = @import("spec.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const AcDynWant = spec.AcDynWant;
const AcWant = spec.AcWant;
const Binding = spec.Binding;
const LimitCase = spec.LimitCase;
const NoiseWant = spec.NoiseWant;
const ParseError = spec.ParseError;

/// The `key=` fields a `//! noise` row may carry.
const NoiseKey = enum { name, white, flicker, ef, rtol, interp, points, psd, corr };

/// Returns whether `cite` is a `//! lrm` cite: a chapter number or annex letter
/// (A to H), then dotted numbers (`5.8`, `A.8.3`, `B`), then optionally `:<n>`,
/// the n-th normative sentence of that clause (`5.6.1.3:2`), counted from 1.
/// Syntax only: a well-formed section the LRM does not have still passes.
pub fn validSection(cite: []const u8) bool {
    const colon = std.mem.findScalar(u8, cite, ':');
    if (colon) |c| if (!digits(cite[c + 1 ..]) or std.mem.eql(u8, cite[c + 1 ..], "0")) return false;
    const s = cite[0 .. colon orelse cite.len];
    assert(s.len <= cite.len);
    var it = std.mem.splitScalar(u8, s, '.');
    const first = it.first();
    const annex = first.len == 1 and first[0] >= 'A' and first[0] <= 'H';
    if (!annex and !digits(first)) return false;
    while (it.next()) |part| if (!digits(part)) return false;
    assert(s.len != 0); // `first` was a letter or a nonempty digit run.
    return true;
}

/// Returns whether `s` is an `//! inherited` cite (`IEEE 1364-2005 17.2.9`,
/// optionally more clauses or a note). Only the first clause is checked.
pub fn validInherited(s: []const u8) bool {
    const std_name = "IEEE 1364-2005 ";
    if (!std.mem.startsWith(u8, s, std_name)) return false;
    const rest = s[std_name.len..];
    const clause = rest[0 .. std.mem.findAny(u8, rest, " ,") orelse rest.len];
    assert(clause.len <= rest.len);
    return validSection(clause);
}

/// Returns whether `s` is a nonempty run of ASCII decimal digits.
pub fn digits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Parses a directive number, accepting §2.6 scale factors (`1u`): the
/// suffix becomes an exponent and the text is parsed once, as the model's
/// lexer does, so `//! time 200u` equals `200u` written in the model
/// (`200 * 1e-6` is another double).
pub fn number(raw: []const u8) ParseError!f64 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len == 0) return error.BadNumber;
    const exp = token_value.scaleExp(t[t.len - 1]) orelse
        return std.fmt.parseFloat(f64, t) catch error.BadNumber;
    const head = std.mem.trim(u8, t[0 .. t.len - 1], " \t");
    if (head.len == 0) return error.BadNumber;
    var buf: [64]u8 = undefined;
    assert(exp.len < buf.len); // `scaleExp`'s longest is `e-18`.
    if (head.len + exp.len > buf.len) return error.BadNumber;
    @memcpy(buf[0..head.len], head);
    @memcpy(buf[head.len..][0..exp.len], exp);
    return std.fmt.parseFloat(f64, buf[0 .. head.len + exp.len]) catch error.BadNumber;
}

/// Parses a comma list of `number`s into `arena`. Empty items are skipped;
/// a list with no number at all is `error.BadSyntax`. The result is never empty.
pub fn numbers(arena: Allocator, rest: []const u8) ParseError![]const f64 {
    var out: std.ArrayList(f64) = .empty;
    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len == 0) continue;
        try out.append(arena, try number(t));
    }
    if (out.items.len == 0) return error.BadSyntax;
    assert(out.items.len <= rest.len);
    return out.items;
}

/// Appends the `name = value` pairs in `rest` to `out`, split on top-level
/// commas so the comma in §5.4.2's `I(a,b)` stays inside its name. Only `(`
/// nests: a §6.5.2 element `d[1]` holds no comma. Names go through
/// `unknownName`; an empty item is skipped.
pub fn bindings(arena: Allocator, rest: []const u8, out: *std.ArrayList(Binding)) ParseError!void {
    const len_before = out.items.len;
    var depth: u32 = 0;
    var start: usize = 0;
    for (rest, 0..) |ch, i| switch (ch) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        ',' => if (depth == 0) {
            try oneBinding(arena, rest[start..i], out);
            start = i + 1;
        },
        else => {},
    };
    assert(start <= rest.len);
    try oneBinding(arena, rest[start..], out);
    assert(out.items.len >= len_before);
}

/// Returns the emitted `U` enum member a directive name refers to. `V(a)`,
/// `x[a]` and `a` all name node `a`. `I(a)` is the §5.4.2 flow `flow(a,gnd)`
/// (§1.3.1.1: every ground is `gnd`), `I(a,b)` is `flow(a,b)` and `I(<p>)` the
/// §5.4.3 port flow `flow(<p>)`. A name that is not a Zig identifier goes
/// through `naming.sanitize`, as codegen spells `U`; a legal identifier is
/// taken as written, so an escaped member (`flowZ28pZ2cnZ29`) is not escaped
/// twice. Fails with `error.BadUnknownName` for a branch potential `V(a,b)`,
/// which is not an unknown, and with `error.BadSyntax` when the access
/// function names nothing (`V()`, `I()`, `I(a,)`, `x[]`). The result may
/// alias `raw` or be allocated in `arena`.
///
/// A text mapping because `ix()` resolves it against `U` at the runner's
/// compile time. `I(a)` is ambiguous on a module with a net named `gnd`;
/// such a fixture writes the member as `emitTopology` prints it.
pub fn unknownName(arena: Allocator, raw: []const u8) ParseError![]const u8 {
    var s = std.mem.trim(u8, raw, " \t");
    if (std.mem.startsWith(u8, s, "V(") and std.mem.endsWith(u8, s, ")")) {
        s = std.mem.trim(u8, s[2 .. s.len - 1], " \t");
        // §5.4.2's branch potential V(a,c) is derived from two nets and has
        // no row to pin. Refused here: sanitized into an identifier, it would
        // fail the testbench build, which the harness reports as an engine bug.
        if (std.mem.findScalar(u8, s, ',') != null) return error.BadUnknownName;
    }
    if (std.mem.startsWith(u8, s, "I(") and std.mem.endsWith(u8, s, ")")) s = try flowName(arena, s);
    if (std.mem.startsWith(u8, s, "x[") and std.mem.endsWith(u8, s, "]")) s = s[2 .. s.len - 1];
    s = std.mem.trim(u8, s, " \t");
    // `V()`, `x[]`: an access function that names nothing.
    if (s.len == 0) return error.BadSyntax;
    if (std.zig.isValidId(s)) return s;
    // Worst case is three bytes out per byte in (`Z` plus two hex digits),
    // plus the one `Z` a Zig-reserved word picks up.
    const buf = try arena.alloc(u8, s.len * 3 + 1);
    const id = naming.sanitize(buf, s) catch unreachable; // `buf` holds the worst case.
    assert(id.len >= s.len);
    assert(std.zig.isValidId(id));
    return id;
}

/// Appends each `//! plusargs` token of `rest` to `out`: split on ASCII
/// space and tab, each printable ASCII without a quote or backslash, starting
/// with `+` and holding another byte. An empty line is `error.BadSyntax`.
pub fn plusargs(arena: Allocator, rest: []const u8, out: *std.ArrayList([]const u8)) ParseError!void {
    if (rest.len == 0) return error.BadSyntax;
    const len_before = out.items.len;
    var args = std.mem.tokenizeAny(u8, rest, " \t");
    while (args.next()) |arg| {
        if (arg.len < 2 or arg[0] != '+') return error.BadSyntax;
        for (arg) |c| {
            if (c < 0x21 or c > 0x7e or c == '\'' or c == '"' or c == '\\') return error.BadSyntax;
        }
        try out.append(arena, try arena.dupe(u8, arg));
    }
    // `rest` is trimmed and nonempty, so it held at least one token.
    assert(out.items.len > len_before);
}

/// Parses one `//! noise` row:
///
///     <kind>(<row>,<col>)#<src> [name=<s>] [white=<v>] [flicker=<v>] [ef=<v>]
///                               [corr=<j>:<rho>]... [rtol=<v>]
///     table(<row>,<col>)#<src> [name=<s>] interp=linear|log
///                               points=<f>:<p>,... psd=<f>:<S>,...
///
/// The topology ends at the first space after the `#`, because the branch may
/// hold spaces (`thermal(p, n)#0`). An unknown key is `error.BadSyntax`,
/// since nothing would check it.
pub fn noiseEntry(arena: Allocator, s: []const u8) ParseError!NoiseWant {
    const hash = std.mem.findScalar(u8, s, '#') orelse return error.BadSyntax;
    const end = std.mem.findAnyPos(u8, s, hash + 1, " \t") orelse s.len;
    const topo = s[0..end];
    if (!validNoiseTopo(topo)) return error.BadSyntax;
    assert(end > hash);

    var w: NoiseWant = .{ .topo = try arena.dupe(u8, topo) };
    var corrs: std.ArrayList(NoiseWant.Corr) = .empty;
    var fields = std.mem.tokenizeAny(u8, s[end..], " \t");
    while (fields.next()) |f| {
        const at = std.mem.findScalar(u8, f, '=') orelse return error.BadSyntax;
        const key = std.meta.stringToEnum(NoiseKey, f[0..at]) orelse return error.BadSyntax;
        const val = f[at + 1 ..];
        switch (key) {
            .name => w.name = try arena.dupe(u8, val),
            .white => w.white = try number(val),
            .flicker => w.flicker = try number(val),
            .ef => w.ef = try number(val),
            .rtol => w.rtol = try number(val),
            .interp => w.interp = std.meta.stringToEnum(NoiseWant.Interp, val) orelse return error.BadSyntax,
            // Both are `<f>:<v>` pairs: knots, or densities at frequencies.
            .points => w.points = try pairs(arena, val),
            .psd => w.psd = try pairs(arena, val),
            .corr => {
                // `<j>:<rho>`: the other row by its table index, then ρ.
                const colon = std.mem.findScalar(u8, val, ':') orelse return error.BadSyntax;
                if (!digits(val[0..colon])) return error.BadSyntax;
                try corrs.append(arena, .{
                    .with = std.fmt.parseInt(u16, val[0..colon], 10) catch return error.BadNumber,
                    .rho = try number(val[colon + 1 ..]),
                });
            },
        }
    }
    w.corrs = corrs.items;
    return w;
}

/// Parses one `//! meta` row into the text the runner prints: `<kind>
/// <name>`, then ` desc="..."` and ` units="..."` when given, in that order
/// whatever order the line wrote them in. A value is any text without a `"`,
/// so a description may hold spaces; it cannot hold a quote. Allocated in `arena`.
pub fn metaEntry(arena: Allocator, s: []const u8) ParseError![]const u8 {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    const kind = it.next() orelse return error.BadSyntax;
    if (std.meta.stringToEnum(enum { parameter, variable, net }, kind) == null) return error.BadSyntax;
    const name = it.next() orelse return error.BadSyntax;
    var desc: ?[]const u8 = null;
    var units: ?[]const u8 = null;
    var rest = std.mem.trim(u8, it.rest(), " \t");
    // Each pass consumes `key="value"` and at least four bytes.
    var passes: usize = 0;
    while (rest.len != 0) : (passes += 1) {
        assert(passes <= s.len / 4);
        const eq = std.mem.findScalar(u8, rest, '=') orelse return error.BadSyntax;
        const key = rest[0..eq];
        if (eq + 1 >= rest.len or rest[eq + 1] != '"') return error.BadSyntax;
        const close = std.mem.findScalarPos(u8, rest, eq + 2, '"') orelse return error.BadSyntax;
        const slot = if (std.mem.eql(u8, key, "desc")) &desc else if (std.mem.eql(u8, key, "units")) &units else return error.BadSyntax;
        if (slot.* != null) return error.BadSyntax;
        slot.* = rest[eq + 2 .. close];
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
    }
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s} {s}", .{ kind, name });
    if (desc) |v| try out.print(arena, " desc=\"{s}\"", .{v});
    if (units) |v| try out.print(arena, " units=\"{s}\"", .{v});
    return out.items;
}

/// Parses one `//! acstim` row (§4.6.3): the branch, then `name`, `mag`,
/// `phase` and `rtol` fields. A stimulus has no kind tag and no `#source`.
/// The branch is canonicalised to `(p,n)`, the device's spelling.
pub fn acEntry(arena: Allocator, s: []const u8) ParseError!AcWant {
    const pr = try pair(s);
    var w: AcWant = .{ .topo = try arena.print("({s},{s})", .{ pr.row, pr.col }) };
    var fields = std.mem.tokenizeAny(u8, pr.rest, " \t");
    while (fields.next()) |f| {
        const at = std.mem.findScalar(u8, f, '=') orelse return error.BadSyntax;
        const key = std.meta.stringToEnum(enum { name, mag, phase, rtol }, f[0..at]) orelse return error.BadSyntax;
        const val = f[at + 1 ..];
        switch (key) {
            .name => w.name = try arena.dupe(u8, val),
            .mag => w.mag = try number(val),
            .phase => w.phase = try number(val),
            .rtol => w.rtol = try number(val),
        }
    }
    assert(w.topo.len >= "(,)".len + 2);
    return w;
}

/// Parses one `//! acdyn` row: the slot, then `f`, `re` and `im`, all
/// required, and an optional `tol`.
pub fn acDynEntry(arena: Allocator, s: []const u8) ParseError!AcDynWant {
    const pr = try pair(s);
    var f: ?f64 = null;
    var re: ?f64 = null;
    var im: ?f64 = null;
    var tol: f64 = 1e-12;
    var fields = std.mem.tokenizeAny(u8, pr.rest, " \t");
    while (fields.next()) |fd| {
        const at = std.mem.findScalar(u8, fd, '=') orelse return error.BadSyntax;
        const key = fd[0..at];
        const val = try number(fd[at + 1 ..]);
        const slot = if (std.mem.eql(u8, key, "f")) &f else if (std.mem.eql(u8, key, "re")) &re else if (std.mem.eql(u8, key, "im")) &im else if (std.mem.eql(u8, key, "tol")) {
            tol = val;
            continue;
        } else return error.BadSyntax;
        slot.* = val;
    }
    assert(pr.row.len != 0);
    assert(pr.col.len != 0);
    return .{
        .row = try arena.dupe(u8, pr.row),
        .col = try arena.dupe(u8, pr.col),
        .f_hz = f orelse return error.BadSyntax,
        .re = re orelse return error.BadSyntax,
        .im = im orelse return error.BadSyntax,
        .tol = tol,
    };
}

/// Parses one `//! limit` case, `old bindings -> wanted bindings`, where the
/// wanted side must name at least one lane (or `converged`).
pub fn limitCase(arena: Allocator, rest: []const u8) ParseError!LimitCase {
    const at = std.mem.find(u8, rest, "->") orelse return error.BadSyntax;
    var old: std.ArrayList(Binding) = .empty;
    var want: std.ArrayList(Binding) = .empty;
    try bindings(arena, rest[0..at], &old);
    try bindings(arena, rest[at + 2 ..], &want);
    // No output named is no assertion.
    if (want.items.len == 0) return error.BadSyntax;
    assert(at + 2 <= rest.len);
    return .{ .old = old.items, .want = want.items };
}

// ---- private ----

fn oneBinding(arena: Allocator, item: []const u8, out: *std.ArrayList(Binding)) ParseError!void {
    const t = std.mem.trim(u8, item, " \t");
    if (t.len == 0) return;
    const at = std.mem.findScalar(u8, t, '=') orelse return error.BadSyntax;
    const name = std.mem.trim(u8, t[0..at], " \t");
    if (name.len == 0) return error.BadSyntax;
    try out.append(arena, .{
        .name = try unknownName(arena, name),
        .value = try number(t[at + 1 ..]),
    });
}

/// Returns the `I(...)` access function `s` as its flow member's source
/// spelling: `flow(a,b)`, `flow(<p>)` or, for one terminal, `flow(a,gnd)`.
fn flowName(arena: Allocator, s: []const u8) ParseError![]const u8 {
    assert(std.mem.startsWith(u8, s, "I("));
    assert(std.mem.endsWith(u8, s, ")"));
    const inner = std.mem.trim(u8, s[2 .. s.len - 1], " \t");
    if (std.mem.findScalar(u8, inner, ',')) |comma| {
        // Each terminal trimmed, as codegen spells `flow(a,b)`.
        const a = std.mem.trim(u8, inner[0..comma], " \t");
        const b = std.mem.trim(u8, inner[comma + 1 ..], " \t");
        if (a.len == 0 or b.len == 0) return error.BadSyntax;
        return arena.print("flow({s},{s})", .{ a, b });
    }
    if (inner.len != 0 and inner[0] == '<') {
        if (std.mem.trim(u8, inner, "<> \t").len == 0) return error.BadSyntax;
        return arena.print("flow({s})", .{inner});
    }
    if (inner.len == 0) return error.BadSyntax;
    return arena.print("flow({s},gnd)", .{inner}); // §5.4.2 I(a) ≡ I(a,gnd)
}

/// Returns whether `s` is a `//! noise` topology such as `thermal(p,n)#0`.
/// The kind is checked; node names are not, since directives are parsed before
/// the unknowns exist and a misspelled node fails the assertion anyway.
fn validNoiseTopo(s: []const u8) bool {
    const open = std.mem.findScalar(u8, s, '(') orelse return false;
    // `#<source>` after the branch is §4.6.4.6's correlation id; `#null` is
    // a row with no identity declared.
    const hash = std.mem.findScalarPos(u8, s, open, '#') orelse return false;
    if (hash == 0 or s[hash - 1] != ')') return false;
    // `s[open]` is `(` and `s[hash - 1]` is `)`, so the branch sits between.
    assert(hash > open + 1);
    const src = s[hash + 1 ..];
    // ponytail: reuse the nonempty decimal check; source IDs have no numeric bound.
    if (!std.mem.eql(u8, src, "null") and !digits(src)) return false;
    const kind = std.mem.trim(u8, s[0..open], " \t");
    // `table` is §4.6.4.3 AND §4.6.4.4: both export one kind, and which
    // interpolation applies is `noise_tables[k].interp`, not the row's tag.
    if (std.meta.stringToEnum(enum { thermal, shot, flicker, table }, kind) == null) return false;
    const inner = s[open + 1 .. hash - 1];
    const comma = std.mem.findScalar(u8, inner, ',') orelse return false;
    return std.mem.trim(u8, inner[0..comma], " \t").len != 0 and
        std.mem.trim(u8, inner[comma + 1 ..], " \t").len != 0;
}

/// Parses `<f>:<v>,<f>:<v>,...` into `arena`; an empty list is refused.
fn pairs(arena: Allocator, val: []const u8) ParseError![]const [2]f64 {
    var pts: std.ArrayList([2]f64) = .empty;
    var it = std.mem.tokenizeScalar(u8, val, ',');
    while (it.next()) |p| {
        const colon = std.mem.findScalar(u8, p, ':') orelse return error.BadSyntax;
        try pts.append(arena, .{ try number(p[0..colon]), try number(p[colon + 1 ..]) });
    }
    if (pts.items.len == 0) return error.BadSyntax;
    assert(pts.items.len <= val.len);
    return pts.items;
}

/// Splits a leading `(<row>,<col>)` off `s`: both names trimmed, and the text
/// after the `)`.
fn pair(s: []const u8) ParseError!struct { row: []const u8, col: []const u8, rest: []const u8 } {
    if (s.len == 0 or s[0] != '(') return error.BadSyntax;
    const close = std.mem.findScalar(u8, s, ')') orelse return error.BadSyntax;
    assert(close != 0); // `s[0]` is `(`.
    const inner = s[1..close];
    const comma = std.mem.findScalar(u8, inner, ',') orelse return error.BadSyntax;
    const row = std.mem.trim(u8, inner[0..comma], " \t");
    const col = std.mem.trim(u8, inner[comma + 1 ..], " \t");
    if (row.len == 0 or col.len == 0) return error.BadSyntax;
    return .{ .row = row, .col = col, .rest = s[close + 1 ..] };
}

test number {
    // §2.6 every scale factor, against the Zig literal with the same
    // exponent: the suffix becomes an exponent before the one parse, as
    // `token_value.scaleExp` makes the model's lexer do.
    const cases = [_]struct { []const u8, f64 }{
        .{ "1T", 1e12 },
        .{ "1G", 1e9 },
        .{ "1M", 1e6 },
        .{ "1K", 1e3 },
        .{ "1k", 1e3 },
        .{ "1m", 1e-3 },
        .{ "1u", 1e-6 },
        .{ "1n", 1e-9 },
        .{ "1p", 1e-12 },
        .{ "1f", 1e-15 },
        .{ "1a", 1e-18 },
        .{ "-3k", -3e3 },
        .{ "2.5m", 2.5e-3 },
        .{ " 7u ", 7e-6 },
        .{ "300.15", 300.15 },
    };
    for (cases) |c| try std.testing.expectEqual(c[1], try number(c[0]));
    // Every other letter is not a scale factor, and a suffix needs a mantissa.
    for ("ABCDEFHIJLNOPQRSUVWXYZbcdeghijloqrstvwxyz") |letter| {
        const text = [2]u8{ '1', letter };
        try std.testing.expectError(error.BadNumber, number(&text));
    }
    try std.testing.expectError(error.BadNumber, number("u"));
    try std.testing.expectError(error.BadNumber, number(""));
    try std.testing.expectError(error.BadNumber, number("1e3k"));
}

test unknownName {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Each spelling lands on the member codegen prints: `naming.sanitize` of
    // `flow(a,b)` or `d[1]`, and a legal identifier as written.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "a", "a" },
        .{ "V(a)", "a" },
        .{ "V( a )", "a" },
        .{ "x[a]", "a" },
        .{ "I(a)", "flowZ28aZ2cgndZ29" },
        .{ "I(a,b)", "flowZ28aZ2cbZ29" },
        // Whitespace inside the access function is not part of the name.
        .{ "I(a, b)", "flowZ28aZ2cbZ29" },
        .{ "I(<p>)", "flowZ28Z3cpZ3eZ29" },
        .{ "d[1]", "dZ5b1Z5d" },
        .{ "flowZ28pZ2cnZ29", "flowZ28pZ2cnZ29" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], try unknownName(arena, c[0]));
    // §5.4.2 a branch potential is no unknown.
    try std.testing.expectError(error.BadUnknownName, unknownName(arena, "V(a,b)"));
    // An access function that names nothing is a typo, refused here rather
    // than as a testbench that does not build.
    for ([_][]const u8{ "V()", "V( )", "I()", "I(a,)", "I(,b)", "I(<>)", "x[]" }) |bad| {
        try std.testing.expectError(error.BadSyntax, unknownName(arena, bad));
    }
}
