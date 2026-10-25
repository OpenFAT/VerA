//! IEEE 1364-2005 §17.2.10 `$sdf_annotate` and the §16 SDF annotator: the
//! file read as OVI SDF 3.0 S-expressions (`parse`), then each CELL's
//! constructs mapped onto the instances it names (`annotate`), as §16.2's
//! tables map them:
//!
//!   IOPATH        the module paths from the input to the output port
//!                 (Table 16-1), 1, 2, 3, 6 or 12 values (Table 16-4, §16.6),
//!                 an empty `()` keeping the path's own value
//!   INTERCONNECT  the load port's input delay (§16.2.4), applied to the
//!                 continuous drivers of the load instance that read it
//!   LABEL         a specparam (§16.2.3), with every path of the instance
//!                 whose delay reads one re-folded
//!   TIMINGCHECK   the limits of the matching §15 checks (Table 16-2)
//!   PATHPULSE     the reject and error limits of the matching paths
//!                 (§16.5, §14.6.3)
//!
//! ABSOLUTE replaces, INCREMENT adds (§16.3), in file order across files
//! (§16.4). A value is in the file's TIMESCALE (1 ns when it gives none),
//! converted to the instance's own unit and rounded to its precision as a
//! real delay is (§19.8). The mtm_spec argument picks a triple's member
//! (§16.6: TYPICAL by default, TOOL_CONTROL included).
//!
//! A construct the annotator does not apply (COND, PORT, DEVICE, a skew
//! check, an INSTANCE that names no instance) is reported (W1105) and the
//! rest of the file still applies. A file that cannot be read or is not
//! S-expressions ends the run (E1102): carrying on would simulate timing the
//! file was meant to set.

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const root = @import("root.zig");
const Run = root.Run;
const Error = root.Error;
const evaluate = @import("evaluate.zig");
const elab = @import("elab.zig");
const system = @import("system.zig");
const display = @import("display.zig");
const net_mod = @import("net.zig");
const tchk = @import("tchk.zig");

// ---- S-expressions ---------------------------------------------------------

/// One node: an atom (a word or a quoted string, its text as written) or a
/// parenthesized list; `line` is where it starts, 1-based.
pub const Node = struct {
    atom: ?[]const u8 = null,
    string: bool = false,
    kids: []const Node = &.{},
    line: u32,

    /// The keyword a list starts with, or "".
    pub fn head(n: Node) []const u8 {
        if (n.kids.len == 0) return "";
        return n.kids[0].atom orelse "";
    }

    fn is(n: Node, kw: []const u8) bool {
        return std.ascii.eqlIgnoreCase(n.head(), kw);
    }
};

pub const ParseError = error{ OutOfMemory, Syntax };

/// Parses `text` into its one top-level list. `line` is set to where a
/// syntax error was found.
pub fn parse(a: std.mem.Allocator, text: []const u8, line: *u32) ParseError!Node {
    var p: Parser = .{ .a = a, .text = text };
    p.skip();
    if (p.at >= text.len or text[p.at] != '(') {
        line.* = p.line;
        return error.Syntax;
    }
    const n = p.node() catch |e| {
        line.* = p.line;
        return e;
    };
    p.skip();
    if (p.at != text.len) {
        line.* = p.line;
        return error.Syntax;
    }
    return n;
}

const Parser = struct {
    a: std.mem.Allocator,
    text: []const u8,
    at: usize = 0,
    line: u32 = 1,

    /// Skips white space and `//` and `/* */` comments.
    fn skip(p: *Parser) void {
        while (p.at < p.text.len) {
            const c = p.text[p.at];
            if (c == '\n') p.line += 1;
            if (std.ascii.isWhitespace(c)) {
                p.at += 1;
            } else if (std.mem.startsWith(u8, p.text[p.at..], "//")) {
                while (p.at < p.text.len and p.text[p.at] != '\n') p.at += 1;
            } else if (std.mem.startsWith(u8, p.text[p.at..], "/*")) {
                p.at += 2;
                while (p.at < p.text.len and !std.mem.startsWith(u8, p.text[p.at..], "*/")) : (p.at += 1) {
                    if (p.text[p.at] == '\n') p.line += 1;
                }
                p.at = @min(p.at + 2, p.text.len);
            } else return;
        }
    }

    fn node(p: *Parser) ParseError!Node {
        const line = p.line;
        const c = p.text[p.at];
        if (c == '(') {
            p.at += 1;
            var kids: std.ArrayList(Node) = .empty;
            while (true) {
                p.skip();
                if (p.at >= p.text.len) return error.Syntax;
                if (p.text[p.at] == ')') break;
                try kids.append(p.a, try p.node());
            }
            p.at += 1;
            return .{ .kids = kids.items, .line = line };
        }
        if (c == ')') return error.Syntax;
        if (c == '"') {
            const start = p.at + 1;
            p.at = start;
            while (p.at < p.text.len and p.text[p.at] != '"') : (p.at += 1) {
                if (p.text[p.at] == '\n') p.line += 1;
            }
            if (p.at >= p.text.len) return error.Syntax;
            p.at += 1;
            return .{ .atom = p.text[start .. p.at - 1], .string = true, .line = line };
        }
        // A word: up to white space, a parenthesis or a quote; a backslash
        // escapes the next character (an SDF identifier's `\[`), kept as
        // written for `name` to undo.
        const start = p.at;
        while (p.at < p.text.len) : (p.at += 1) {
            const w = p.text[p.at];
            if (w == '\\') {
                p.at += 1;
                continue;
            }
            if (std.ascii.isWhitespace(w) or w == '(' or w == ')' or w == '"') break;
        }
        return .{ .atom = p.text[start..@min(p.at, p.text.len)], .line = line };
    }
};

/// An SDF identifier's text without its escapes (`\&dut\[0\]` is `&dut[0]`).
fn unescape(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) i += 1;
        try out.append(a, raw[i]);
    }
    return out.items;
}

/// A hierarchical SDF path split on its unescaped `divider`, each part
/// unescaped.
fn splitPath(a: std.mem.Allocator, raw: []const u8, divider: u8) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') {
            i += 1;
            continue;
        }
        if (raw[i] == divider) {
            try parts.append(a, try unescape(a, raw[start..i]));
            start = i + 1;
        }
    }
    try parts.append(a, try unescape(a, raw[start..]));
    return parts.items;
}

/// §16.6 one rvalue: `()` is null, `(v)` is v, `(min:typ:max)` the member
/// `mtm` picks (0, 1, 2), any of which may be empty.
pub fn rvalue(n: Node, mtm: u2) error{Syntax}!?f64 {
    if (n.atom != null) return error.Syntax;
    if (n.kids.len == 0) return null;
    if (n.kids.len != 1 or n.kids[0].atom == null or n.kids[0].string) return error.Syntax;
    const t = n.kids[0].atom.?;
    var parts = std.mem.splitScalar(u8, t, ':');
    var got: [3][]const u8 = undefined;
    var k: usize = 0;
    while (parts.next()) |s| : (k += 1) {
        if (k == 3) return error.Syntax;
        got[k] = s;
    }
    const pick = if (k == 1) got[0] else if (k == 3) got[mtm] else return error.Syntax;
    if (pick.len == 0) return null;
    return std.fmt.parseFloat(f64, pick) catch error.Syntax;
}

test rvalue {
    const one: Node = .{ .kids = &.{.{ .atom = "3.0:7:11", .line = 1 }}, .line = 1 };
    try std.testing.expectEqual(@as(?f64, 3), try rvalue(one, 0));
    try std.testing.expectEqual(@as(?f64, 7), try rvalue(one, 1));
    try std.testing.expectEqual(@as(?f64, 11), try rvalue(one, 2));
    const gap: Node = .{ .kids = &.{.{ .atom = "1::3", .line = 1 }}, .line = 1 };
    try std.testing.expectEqual(@as(?f64, null), try rvalue(gap, 1));
    try std.testing.expectEqual(@as(?f64, null), try rvalue(.{ .line = 1 }, 1));
    const bad: Node = .{ .kids = &.{.{ .atom = "1:2", .line = 1 }}, .line = 1 };
    try std.testing.expectError(error.Syntax, rvalue(bad, 1));
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var line: u32 = 0;
    const n = try parse(arena.allocator(),
        \\ /* c */ (DELAYFILE // x
        \\  (DIVIDER /) (CELL (CELLTYPE "a b") (INSTANCE \&d\[0\]/u)))
    , &line);
    try std.testing.expect(n.is("delayfile"));
    try std.testing.expectEqualStrings("a b", n.kids[2].kids[1].kids[1].atom.?);
    const parts = try splitPath(arena.allocator(), n.kids[2].kids[2].kids[1].atom.?, '/');
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("&d[0]", parts[0]);
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "(A (B)", &line));
    try std.testing.expectEqual(@as(u32, 1), line);
}

// ---- the annotator ---------------------------------------------------------

/// One `$sdf_annotate` call's settings and where it reports.
const Ctx = struct {
    r: *Run,
    a: std.mem.Allocator,
    file: []const u8,
    tok: u32,
    mtm: u2 = 1,
    divider: u8 = '.',
    /// The file's TIMESCALE, as a multiplier (1, 10 or 100) and a decade.
    ts_mult: f64 = 1,
    ts_exp: i32 = -9,

    fn warn(c: *Ctx, line: u32, comptime fmt: []const u8, args: anytype) Error!void {
        const r = c.r;
        const at = r.starts[@min(c.tok, r.starts.len - 1)];
        try r.bag.add(r.stage(), .W1105, .{ .start = at, .end = at }, "{s}:{d}: " ++ fmt, .{ c.file, line } ++ args);
    }

    /// `v` in the file's unit as instance `scope`'s ticks, signed; null
    /// when the value names no tick count.
    fn ticks(c: *Ctx, scope: u32, v: f64) ?i128 {
        const mt = c.r.timeOf(scope);
        const k = c.ts_exp - mt.unit_exp;
        const p = std.math.pow(f64, 10, @floatFromInt(@abs(k)));
        const units = @abs(v) * c.ts_mult;
        const scaled = if (k >= 0) units * p else units / p;
        const t = mt.scale.realDelay(scaled) catch return null;
        return if (v < 0) -@as(i128, t) else t;
    }
};

/// §17.2.10 `$sdf_annotate ( "sdf_file" [, module_instance [, "config_file"
/// [, "log_file" [, "mtm_spec" [, "scale_factors" [, "scale_type" ]]]]]] )`.
/// The config file, log file and scale arguments are read and not applied
/// (W1105 for a scale factor other than 1).
pub fn annotate(r: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, tok: u32) Error!void {
    const name = (try system.text(a, try evaluate.eval(r, a, args[0], 0))) orelse return r.failWith(.E1102, tok, "$sdf_annotate's file name has x or z bits", .{});
    var c: Ctx = .{ .r = r, .a = a, .file = name, .tok = tok };
    const scope = if (args.len > 1 and args[1] != .none) switch (try @import("vcd.zig").target(r, args[1])) {
        .scope => |s| s,
        .slot => return r.exprFail(args[1], "§17.2.10: $sdf_annotate's second argument names a module instance"),
    } else r.instanceOf(r.scope);
    if (args.len > 4 and args[4] != .none) {
        const m = (try system.text(a, try evaluate.eval(r, a, args[4], 0))) orelse "";
        c.mtm = if (std.ascii.eqlIgnoreCase(m, "MINIMUM")) 0 else if (std.ascii.eqlIgnoreCase(m, "MAXIMUM")) 2 else if (std.ascii.eqlIgnoreCase(m, "TYPICAL") or std.ascii.eqlIgnoreCase(m, "TOOL_CONTROL")) 1 else return r.exprFail(args[4], "§17.2.10: mtm_spec is \"MINIMUM\", \"TYPICAL\", \"MAXIMUM\" or \"TOOL_CONTROL\"");
    }
    const io = r.io orelse return r.failWith(.E1102, tok, "{s}: the SDF file cannot be read", .{name});
    const file = display.sideFile(io, a, r.file_name, name) catch return r.failWith(.E1102, tok, "{s}: the SDF file cannot be read", .{name});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var in = file.reader(io, &buf);
    const text = in.interface.allocRemaining(a, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return r.failWith(.E1102, tok, "{s}: the SDF file cannot be read", .{name}),
    };
    var line: u32 = 0;
    const top = parse(a, text, &line) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return r.failWith(.E1102, tok, "{s}:{d}: not an SDF file: unbalanced parentheses or a stray token", .{ name, line }),
    };
    if (!top.is("DELAYFILE")) return r.failWith(.E1102, tok, "{s}:{d}: an SDF file is one (DELAYFILE ...)", .{ name, top.line });
    const saved = r.scope;
    defer r.scope = saved;
    for (top.kids[1..]) |h| {
        if (h.is("TIMESCALE")) try timescale(&c, h) else if (h.is("DIVIDER")) {
            const d = if (h.kids.len == 2) h.kids[1].atom orelse "" else "";
            if (d.len != 1 or (d[0] != '.' and d[0] != '/')) return r.failWith(.E1102, tok, "{s}:{d}: DIVIDER is . or /", .{ name, h.line });
            c.divider = d[0];
        } else if (h.is("CELL")) try cell(&c, h, scope);
        // else: SDFVERSION, DESIGN, DATE, VENDOR, PROGRAM, VERSION, VOLTAGE,
        // PROCESS and TEMPERATURE inform and set nothing.
    }
}

/// `(TIMESCALE 1ns)` or `(TIMESCALE 100 ps)`.
fn timescale(c: *Ctx, h: Node) Error!void {
    var text: std.ArrayList(u8) = .empty;
    for (h.kids[1..]) |k| try text.appendSlice(c.a, k.atom orelse "");
    const t = text.items;
    var i: usize = 0;
    while (i < t.len and (std.ascii.isDigit(t[i]) or t[i] == '.')) i += 1;
    const mult = std.fmt.parseFloat(f64, t[0..i]) catch 0;
    const units = [_]struct { []const u8, i32 }{ .{ "s", 0 }, .{ "ms", -3 }, .{ "us", -6 }, .{ "ns", -9 }, .{ "ps", -12 }, .{ "fs", -15 } };
    for (units) |u| if (std.ascii.eqlIgnoreCase(t[i..], u[0]) and (mult == 1 or mult == 10 or mult == 100)) {
        c.ts_mult = mult;
        c.ts_exp = u[1];
        return;
    };
    return c.r.failWith(.E1102, c.tok, "{s}:{d}: TIMESCALE is 1, 10 or 100 of s, ms, us, ns, ps or fs", .{ c.file, h.line });
}

/// The instances one CELL names under `scope`: INSTANCE's path, the scope
/// itself for an empty one, every instance of CELLTYPE below it for `*`.
fn cell(c: *Ctx, h: Node, scope: u32) Error!void {
    const r = c.r;
    var celltype: []const u8 = "";
    var targets: std.ArrayList(u32) = .empty;
    var named = false;
    for (h.kids[1..]) |k| {
        if (k.is("CELLTYPE")) {
            celltype = if (k.kids.len == 2) k.kids[1].atom orelse "" else "";
        } else if (k.is("INSTANCE")) {
            named = true;
            if (k.kids.len == 1) {
                try targets.append(c.a, scope);
            } else if (std.mem.eql(u8, k.kids[1].atom orelse "", "*")) {
                for (r.scope_info.items, 0..) |info, s| {
                    if (info.lexical or s == scope or !below(r, @intCast(s), scope)) continue;
                    if (std.mem.eql(u8, r.file.str(r.file.modules[info.def].name), celltype)) try targets.append(c.a, @intCast(s));
                }
            } else {
                const parts = try splitPath(c.a, k.kids[1].atom orelse "", c.divider);
                if (child(r, scope, parts)) |s| try targets.append(c.a, s) else try c.warn(k.line, "INSTANCE {s} names no instance below the annotation scope; the cell is not applied", .{k.kids[1].atom.?});
            }
        }
    }
    if (!named) try targets.append(c.a, scope);
    for (targets.items) |s| for (h.kids[1..]) |k| {
        if (k.is("DELAY")) {
            for (k.kids[1..]) |d| {
                if (d.is("ABSOLUTE") or d.is("INCREMENT")) {
                    for (d.kids[1..]) |e| try delayEntry(c, s, e, d.is("INCREMENT"));
                } else if (d.is("PATHPULSE")) try pathPulse(c, s, d) else try c.warn(d.line, "DELAY's {s} is not applied", .{d.head()});
            }
        } else if (k.is("TIMINGCHECK")) {
            for (k.kids[1..]) |t| try timingCheck(c, s, t);
        } else if (k.is("LABEL")) {
            for (k.kids[1..]) |d| {
                if (!(d.is("ABSOLUTE") or d.is("INCREMENT"))) {
                    try c.warn(d.line, "LABEL's {s} is not applied", .{d.head()});
                    continue;
                }
                for (d.kids[1..]) |e| try label(c, s, e, d.is("INCREMENT"));
            }
        } else if (!(k.is("CELLTYPE") or k.is("INSTANCE"))) try c.warn(k.line, "CELL's {s} is not applied", .{k.head()});
    };
}

/// Whether instance scope `s` lies below `top` (a root is its own parent).
fn below(r: *const Run, s: u32, top: u32) bool {
    var at = s;
    while (at != top) {
        const p = r.scope_info.items[at].parent;
        if (p == at) return false;
        at = p;
    }
    return true;
}

/// The instance `parts` names from `scope` down, one instance per part.
fn child(r: *const Run, scope: u32, parts: []const []const u8) ?u32 {
    var at = scope;
    for (parts) |p| {
        at = for (r.scope_info.items, 0..) |info, s| {
            if (s != at and info.parent == at and !info.lexical and std.mem.eql(u8, r.file.str(info.name), p)) break @intCast(s);
        } else return null;
    }
    return at;
}

/// The slot port `name` of instance `scope` is bound to.
fn portSlot(r: *const Run, scope: u32, name: []const u8) ?u32 {
    const m = r.file.modules[r.scope_info.items[scope].def];
    for (m.ports) |p| if (std.mem.eql(u8, r.file.str(p.name), name)) return r.names.get(.{ .scope = scope, .str = p.name });
    return null;
}

/// A `port_spec`: a port, or `(posedge port)` / `(negedge port)`; a bit
/// select is read as its whole port.
// ponytail: `a[3]` matches every path from `a`.
const PortSpec = struct { name: []const u8, edge: Ast.SpecEdge = .none };

fn portSpec(c: *Ctx, n: Node) Error!?PortSpec {
    var edge: Ast.SpecEdge = .none;
    var raw = n.atom;
    if (raw == null) {
        if (n.kids.len != 2 or n.kids[1].atom == null) return null;
        edge = if (n.is("posedge")) .posedge else if (n.is("negedge")) .negedge else return null;
        raw = n.kids[1].atom;
    }
    var name = try unescape(c.a, raw.?);
    if (std.mem.indexOfScalar(u8, name, '[')) |b| name = name[0..b];
    return .{ .name = name, .edge = edge };
}

/// The rvalues of `kids`, `n` of them at most; error.Syntax names a
/// malformed one.
fn rvalues(c: *Ctx, kids: []const Node) error{ Syntax, OutOfMemory }![]const ?f64 {
    const out = try c.a.alloc(?f64, kids.len);
    for (kids, out) |k, *o| o.* = try rvalue(k, c.mtm);
    return out;
}

/// The nets a module path into output `slot` of instance `scope` times: its
/// own net, or, for a variable port, the nets its bridge drives (as
/// `elab.pathDelays` found them).
fn destNets(c: *Ctx, slot: u32) Error![]const u32 {
    const r = c.r;
    if (r.net_of.get(slot)) |net| return c.a.dupe(u32, &.{net});
    var out: std.ArrayList(u32) = .empty;
    for (r.drivers) |d| if (d.source == .bridge and d.source.bridge.src == slot) try out.append(c.a, d.net);
    return out.items;
}

/// Table 16-4's transitions of the 12 positions, in `net.pathTable`'s order.
const positions = [12][2]Int.Bit{
    .{ .zero, .one }, .{ .one, .zero }, .{ .zero, .z }, .{ .z, .one }, .{ .one, .z }, .{ .z, .zero },
    .{ .zero, .x },   .{ .x, .one },    .{ .one, .x },  .{ .x, .zero }, .{ .x, .z },  .{ .z, .x },
};

/// One ABSOLUTE or INCREMENT entry on instance `s`.
fn delayEntry(c: *Ctx, s: u32, e: Node, increment: bool) Error!void {
    if (e.is("IOPATH")) return ioPath(c, s, e, increment);
    if (e.is("INTERCONNECT")) return interconnect(c, s, e, increment);
    try c.warn(e.line, "{s} is not applied", .{e.head()});
}

/// §16.2.1 Table 16-1 `(IOPATH port_spec port_instance rvalue...)`: every
/// module path of `s` from the input (on its edge, when the file gives one)
/// to the output.
fn ioPath(c: *Ctx, s: u32, e: Node, increment: bool) Error!void {
    const r = c.r;
    if (e.kids.len < 4) return c.warn(e.line, "IOPATH names an input, an output and its values", .{});
    const in = (try portSpec(c, e.kids[1])) orelse return c.warn(e.line, "IOPATH's input is a port or (posedge|negedge port)", .{});
    const out = (try portSpec(c, e.kids[2])) orelse return c.warn(e.line, "IOPATH's output is a port", .{});
    var kids = e.kids[3..];
    // RETAIN (§16.2.1 ignores it) comes before the delays.
    if (kids.len != 0 and kids[0].is("RETAIN")) kids = kids[1..];
    const vals = rvalues(c, kids) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return c.warn(e.line, "IOPATH has a malformed value", .{}),
    };
    if (!(vals.len == 1 or vals.len == 2 or vals.len == 3 or vals.len == 6 or vals.len == 12)) return c.warn(e.line, "IOPATH has 1, 2, 3, 6 or 12 values, not {d}", .{vals.len});
    const src = portSlot(r, s, in.name) orelse return c.warn(e.line, "IOPATH input {s} is no port of this instance", .{in.name});
    const dst = portSlot(r, s, out.name) orelse return c.warn(e.line, "IOPATH output {s} is no port of this instance", .{out.name});
    var hit = false;
    for (try destNets(c, dst)) |net| {
        const cold = try r.netColdMut(net);
        for (cold.paths) |*p| {
            if (p.scope != s or p.src != src) continue;
            if (in.edge != .none and p.edge != .none and p.edge != in.edge) continue;
            hit = true;
            var d: [12]u64 = undefined;
            for (vals, 0..) |v, k| {
                const old = p.table[@backingInt(positions[k][0])][@backingInt(positions[k][1])];
                const t = if (v) |x| c.ticks(s, x) orelse return c.warn(e.line, "IOPATH value {d} is no delay", .{x}) else null;
                d[k] = if (t) |x| @intCast(std.math.clamp(if (increment) @as(i128, old) + x else x, 0, std.math.maxInt(u64))) else old;
            }
            p.table = net_mod.pathTable(d[0..vals.len]);
        }
    }
    if (!hit) try c.warn(e.line, "IOPATH {s} {s} names no module path of this instance", .{ in.name, out.name });
}

/// §16.2.4 `(INTERCONNECT source load rvalue...)`: the delay of the load
/// port, an input of an instance below `s`. The annotation scope's ports
/// are one net with the source's, so the delay is added to the continuous
/// drivers (assignments, gates, UDPs) of the load instance that read the
/// port.
// ponytail: a process or a path in the load instance still sees the port
// undelayed; a per-load copy of the net is the upgrade.
fn interconnect(c: *Ctx, s: u32, e: Node, increment: bool) Error!void {
    _ = increment; // either way the delay adds to the driver's own
    const r = c.r;
    if (e.kids.len < 4 or e.kids[2].atom == null) return c.warn(e.line, "INTERCONNECT names a source, a load and its values", .{});
    const parts = try splitPath(c.a, e.kids[2].atom.?, c.divider);
    const inst = child(r, s, parts[0 .. parts.len - 1]) orelse return c.warn(e.line, "INTERCONNECT load {s} names no instance port", .{e.kids[2].atom.?});
    var port = parts[parts.len - 1];
    if (std.mem.indexOfScalar(u8, port, '[')) |b| port = port[0..b];
    const slot = portSlot(r, inst, port) orelse return c.warn(e.line, "INTERCONNECT load {s} names no instance port", .{e.kids[2].atom.?});
    const vals = rvalues(c, e.kids[3..]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return c.warn(e.line, "INTERCONNECT has a malformed value", .{}),
    };
    if (vals.len == 0 or vals.len > 3) return c.warn(e.line, "INTERCONNECT has 1, 2 or 3 values", .{});
    var t: [3]u64 = .{ 0, 0, 0 };
    for (vals, 0..) |v, k| t[k] = @intCast(@max(0, if (v) |x| c.ticks(inst, x) orelse 0 else 0));
    if (vals.len < 2) t[1] = t[0];
    if (vals.len < 3) t[2] = @min(t[0], t[1]);
    var hit = false;
    for (r.drivers) |*d| {
        if (d.scope != inst or std.mem.indexOfScalar(u32, d.sensitivity, slot) == null) continue;
        hit = true;
        d.delay = .{ .present = true, .rise = d.delay.rise + t[0], .fall = d.delay.fall + t[1], .off = d.delay.off + t[2] };
    }
    if (!hit) try c.warn(e.line, "INTERCONNECT load {s} feeds no continuous driver, so no delay applies", .{e.kids[2].atom.?});
}

/// §16.2.3 a LABEL entry `(name rvalue)`: the specparam `name` of `s` takes
/// the value, in the instance's unit, and every module path of `s` is
/// re-folded from its delay expressions.
fn label(c: *Ctx, s: u32, e: Node, increment: bool) Error!void {
    const r = c.r;
    if (e.kids.len != 2 or e.kids[0].atom == null) return c.warn(e.line, "a LABEL entry is (specparam value)", .{});
    const name = try unescape(c.a, e.kids[0].atom.?);
    const slot = for (r.file.modules[r.scope_info.items[s].def].params) |p| {
        if (p.is_spec and std.mem.eql(u8, r.file.str(p.name), name)) break r.names.get(.{ .scope = s, .str = p.name });
    } else null;
    const at = slot orelse return c.warn(e.line, "LABEL {s} is no specparam of this instance", .{name});
    const v = (rvalue(e.kids[1], c.mtm) catch return c.warn(e.line, "LABEL {s} has a malformed value", .{name})) orelse return;
    const mt = r.timeOf(s);
    const k = c.ts_exp - mt.unit_exp;
    const p = std.math.pow(f64, 10, @floatFromInt(@abs(k)));
    var units = v * c.ts_mult;
    units = if (k >= 0) units * p else units / p;
    const dst = r.values[at];
    if (r.reals.contains(at)) {
        const old: f64 = @bitCast(dst.values()[0]);
        dst.values()[0] = @bitCast(if (increment) old + units else units);
    } else {
        const old: f64 = @floatFromInt(dst.asInt() orelse 0);
        const n = try evaluate.intOfReal(c.a, if (increment) old + units else units);
        @memset(dst.planes, 0);
        for (dst.values(), 0..) |*w, i| w.* = if (i < n.values().len) n.values()[i] else if (n.values()[n.values().len - 1] >> 63 != 0) std.math.maxInt(u64) else 0;
        if (dst.width % 64 != 0) dst.values()[dst.values().len - 1] &= (@as(u64, 1) << @intCast(dst.width % 64)) - 1;
    }
    r.scope = s;
    for (r.net_cold.items) |*cold| for (cold.paths) |*q| {
        if (q.scope == s and q.delays.len != 0) q.table = try elab.pathTable(r, q.delays, q.tok);
    };
}

/// §16.2.2 Table 16-2 a TIMINGCHECK entry: the limits of every check of `s`
/// of the matching family whose events read the named ports.
fn timingCheck(c: *Ctx, s: u32, e: Node) Error!void {
    const r = c.r;
    const Fam = struct { []const u8, []const tchk.Kind, u2, u2 };
    // The kinds a keyword annotates, how many ports it names, and how many
    // values; SETUPHOLD's and RECREM's two land in both limits.
    const fams = [_]Fam{
        .{ "SETUP", &.{ .setup, .setuphold }, 2, 1 },
        .{ "HOLD", &.{ .hold, .setuphold }, 2, 1 },
        .{ "SETUPHOLD", &.{.setuphold}, 2, 2 },
        .{ "RECOVERY", &.{ .recovery, .recrem }, 2, 1 },
        .{ "REMOVAL", &.{ .removal, .recrem }, 2, 1 },
        .{ "RECREM", &.{.recrem}, 2, 2 },
        .{ "WIDTH", &.{.width}, 1, 1 },
        .{ "PERIOD", &.{.period}, 1, 1 },
    };
    const fam = for (fams) |f| {
        if (e.is(f[0])) break f;
    } else return c.warn(e.line, "TIMINGCHECK's {s} is not applied", .{e.head()});
    if (e.kids.len < 1 + @as(usize, fam[2]) + fam[3]) return c.warn(e.line, "{s} names {d} ports and {d} values", .{ fam[0], fam[2], fam[3] });
    var slots: [2]u32 = undefined;
    for (0..fam[2]) |k| {
        const ps = (try portSpec(c, e.kids[1 + k])) orelse return c.warn(e.line, "{s}'s port is a port or (posedge|negedge port)", .{fam[0]});
        slots[k] = portSlot(r, s, ps.name) orelse return c.warn(e.line, "{s} port {s} is no port of this instance", .{ fam[0], ps.name });
    }
    const vals = rvalues(c, e.kids[1 + fam[2] ..][0..fam[3]]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return c.warn(e.line, "{s} has a malformed value", .{fam[0]}),
    };
    var hit = false;
    for (r.tchks.items) |*t| {
        if (t.scope != s or std.mem.indexOfScalar(tchk.Kind, fam[1], t.kind) == null) continue;
        const ok = if (fam[2] == 1) t.ev[0].slot == slots[0] else (t.ev[0].slot == slots[0] and t.ev[1].slot == slots[1]) or (t.ev[0].slot == slots[1] and t.ev[1].slot == slots[0]);
        if (!ok) continue;
        hit = true;
        for (vals, 0..) |v, k| {
            const x = v orelse continue;
            const ticks: u64 = @intCast(@max(0, c.ticks(s, x) orelse 0));
            // Which limit: setup/removal/width/period [0], hold/recovery [1];
            // the two-valued keywords (setup, hold) and (recovery, removal).
            const slot: usize = if (fam[3] == 2) (if (std.mem.eql(u8, fam[0], "SETUPHOLD")) k else 1 - k) else if (std.mem.eql(u8, fam[0], "HOLD") or std.mem.eql(u8, fam[0], "RECOVERY")) 1 else 0;
            t.lim[slot] = ticks;
        }
    }
    if (!hit) try c.warn(e.line, "{s} names no timing check of this instance", .{fam[0]});
}

/// §16.5 `(PATHPULSE [input output] rvalue [rvalue])`.
fn pathPulse(c: *Ctx, s: u32, e: Node) Error!void {
    _ = s;
    try c.warn(e.line, "PATHPULSE is not applied", .{});
}
