//! The design's `defparam`s in, each bound to the instance and parameter it names, checked against the hierarchy out.
//! Cites: IEEE 1364-2005 §12.2.1, §12.4.
//!
//! Contents:
//! - `pub fn bindDefparam(r: *Run, decl: u32, d: Ast.Defparam, children: []const Ast.Instance) Error!void`
//! - `pub fn checkDefparams(r: *Run) Error!void`
//! Pass one of elaboration: the parsed design and its root definitions ->
//! the slot space, the nets and the driver rows (`Elab`), the scope tree
//! (`Run.hier.scopes`) and every name bound in it, before any expression is
//! compiled. §6.2.2's walk of the instance tree is parent-first, so a port
//! connection always resolves against a parent that is fully declared.
//! `elaborate` (root.zig) runs it, then compiles what it built.
//! Clauses: IEEE 1364-2005 §4.5 implicit nets, §4.9 arrays, §4.10 and §12.2
//! parameters and defparams, §6.5/§6.5.7.1 ports, §7.1, §7.6 and §7.8 gates,
//! switches and pulls, §8 UDPs, §10 subroutine frames, §12.1.2 instance
//! arrays, §12.1.3 recursive instantiation, §12.3 port connections, §12.4
//! generate, §12.5 named blocks, §12.8.2, §19.9 unconnected_drive; VAMS §3.7
//! wreal, §6.3 the host's parameters, §7.2 continuous and discrete, §7.8.4
//! inserted connect modules.
const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const root = @import("root.zig");
const Run = root.Run;
const Error = root.Error;
const Frame = root.Frame;
const VecRange = root.VecRange;
const Span = root.Span;
const isRoot = root.isRoot;
const expectRun = root.expectRun;
const expectRejected = root.expectRejected;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const deep = @import("base").deep_stack;
const binding = @import("bind.zig");
const Type = compile.Type;
const net_mod = @import("net.zig");
const Net = net_mod.Net;
const NetCold = net_mod.NetCold;
const Udp = net_mod.Udp;
const Slice = net_mod.Slice;
const Tran = net_mod.Tran;
const Signal = net_mod.Signal;
const Source = net_mod.Source;
const filled = net_mod.filled;
const undriven = net_mod.undriven;
const elab = @import("elab.zig");
const elab_generate = @import("elab_generate.zig");
const elab_params = @import("elab_params.zig");
const generate = elab_generate.generate;
const isScope = elab.isScope;
const names = elab_params.names;
const PathSeg = root.PathSeg;

/// IEEE 1364-2005 §12.2.1 registers defparam `d`, declared in `decl`: its
/// unfolded instance selects folded there, then its first segment resolved
/// as §12.6 resolves a hierarchical name. It names a child of `decl` when
/// one of `children` (the instances the declaring text writes) has that
/// name, else `decl` or a scope above it by name, else a child that
/// elaboration mints later.
pub fn bindDefparam(r: *Run, decl: u32, d: Ast.Defparam, children: []const Ast.Instance) Error!void {
    assert(decl < r.hier.scopes.items.len);
    const bound = r.decls.bound_defparams.items.len;
    const p = try pathSegments(r, d);
    const b = try defparamBase(r, decl, p.segs, children, d.main_tok);
    const rest = p.path[p.segs[b.skip].start..];
    try r.decls.defparams.put(r.arena, .{ .scope = b.at, .path = rest }, .{ .d = d, .decl = decl });
    try r.decls.bound_defparams.append(r.arena, .{ .decl = decl, .path = p.path, .segs = p.segs, .at = b.at, .skip = b.skip, .tok = d.main_tok });
    assert(r.decls.bound_defparams.items.len == bound + 1);
    assert(b.at < r.hier.scopes.items.len);
}

/// IEEE 1364-2005 §12.8.2: "It shall be an error if a hierarchical name in a
/// defparam is resolved before the hierarchy is completely elaborated and
/// that name would resolve differently once the model is completely
/// elaborated."
pub fn checkDefparams(r: *Run) Error!void {
    assert(r.hier.roots.len > 0); // The hierarchy is complete.
    for (r.decls.bound_defparams.items) |b| {
        assert(b.decl < r.hier.scopes.items.len);
        const now = try defparamBase(r, b.decl, b.segs, null, b.tok);
        if (now.at != b.at or now.skip != b.skip)
            return r.fail(b.tok, "§12.8.2: this defparam's hierarchical name was resolved before the hierarchy was complete and would resolve differently once it is", .{});
        // §12.2.1: "a defparam statement in a hierarchy in or under a
        // generate block instance ... or an array of instances ... shall not
        // change a parameter value outside that hierarchy", however its path
        // is spelled (`defparamBase` refuses the upward relative form early).
        // §12.2.1: the hierarchical name names a parameter: E0901 when no
        // scope holds it, E0907 when a named instance has no such parameter.
        // A mixed design's defparam may name a VAMS §7.8.5 inserted connect
        // module, which only the analog elaboration builds.
        const rest = b.segs[b.skip..];
        const target = defparamScope(r, b.at, rest) orelse if (r.analog.mixed)
            continue
        else
            return r.failWith(.E0901, b.tok, "§12.2.1: this defparam's hierarchical name `{s}` names nothing in the design", .{b.path});
        const leaf = rest[rest.len - 1].name;
        const slot = if (r.file.strings.find(leaf)) |str| r.hier.names.get(.{ .scope = target, .str = str }) else null;
        // A mixed design leaves the analog block's parameters unbound here.
        if (!r.analog.mixed and (slot == null or !r.decls.params.contains(slot.?))) {
            if (slot == null and target == b.at and rest.len == 1)
                return r.failWith(.E0901, b.tok, "§12.2.1: this defparam's hierarchical name `{s}` names nothing in the design", .{b.path});
            return r.failWith(.E0907, b.tok, "§12.2.1: this defparam names `{s}`, which is no parameter of its module", .{leaf});
        }
        var s = b.decl;
        while (true) : (s = r.hier.scopes.items[s].parent) {
            const info = r.hier.scopes.items[s];
            if ((info.index != null or info.lexical) and !within(r, target, s)) {
                var name: std.ArrayList(u8) = .empty;
                try name.appendSlice(r.arena, r.file.str(info.name));
                if (info.index) |k| try name.print(r.arena, "[{d}]", .{k});
                return r.fail(b.tok, "§12.2.1: a defparam inside `{s}` cannot change a parameter outside the generate block instance or array element it is in", .{name.items});
            }
            if (isRoot(r, s)) break;
        }
        assert(target < r.hier.scopes.items.len);
    }
}

// ---- private ----

/// Defparam `d`'s path, its unfolded selects folded in the current scope,
/// and its segments as the parser read them: the tokens from `d.main_tok`
/// give each name's length in `d.path`, so a `[`, `]`, `.` or `$` inside an
/// escaped name is the name's, never a select or a separator (IEEE 1364-2005
/// §3.7.1). `parse_hier.parseDottedPath` spells the path: each name as
/// `internTok` interns it, `[k]` (or `[]`, unfolded) after a selected one,
/// `.` between.
fn pathSegments(r: *Run, d: Ast.Defparam) Error!struct { path: []const u8, segs: []const PathSeg } {
    assert(d.main_tok < r.starts.len);
    const spelled = r.file.str(d.path);
    var path: std.ArrayList(u8) = .empty;
    var segs: std.ArrayList(PathSeg) = .empty;
    var tok = d.main_tok;
    var at: usize = 0; // into `spelled`
    var unfolded: usize = 0; // into `d.indices`
    while (true) {
        // A name: an identifier, escaped (`\` dropped, but `\$...` kept
        // whole, §3.7.3), or a system name (`$root`, `u.$xposition`).
        const raw = Front.lexer.tokenText(r.text, r.starts[tok]);
        const len = if (raw[0] == '\\' and raw[1] != '$') raw.len - 1 else raw.len;
        assert(len >= 1); // The lexer makes no empty name.
        assert(at + len <= spelled.len); // The parser spelled this token here.
        const start: u32 = @intCast(path.items.len);
        try path.appendSlice(r.arena, spelled[at .. at + len]);
        at += len;
        tok += 1;
        var index: ?i64 = null;
        if (at < spelled.len and spelled[at] == '[') {
            const close = at + std.mem.findScalar(u8, spelled[at..], ']').?;
            index = if (close == at + 1) blk: {
                const x = d.indices[unfolded];
                unfolded += 1;
                break :blk (try r.constant(x, d.main_tok)).asInt() orelse return r.exprFail(x, "§12.2.1: a defparam's instance select is x or z");
            } else std.fmt.parseInt(i64, spelled[at + 1 .. close], 10) catch
                return r.fail(d.main_tok, "§12.2.1: a defparam's instance select is outside the 64-bit range", .{});
            try path.print(r.arena, "[{d}]", .{index.?});
            at = close + 1;
            // Past the select's tokens: its `]` is the first to close it.
            var depth: u32 = 0;
            while (true) : (tok += 1) switch (r.text[r.starts[tok]]) {
                '[' => depth += 1,
                ']' => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            };
            tok += 1;
        }
        try segs.append(r.arena, .{ .name = path.items[start .. start + len], .index = index, .start = start });
        if (at == spelled.len) break;
        assert(spelled[at] == '.');
        try path.append(r.arena, '.');
        at += 1;
        tok += 1; // the `.`
    }
    assert(unfolded == d.indices.len);
    assert(segs.items.len >= 1);
    // `name` slices were taken while `path` grew: re-point them at its final bytes.
    for (segs.items) |*g| g.name = path.items[g.start .. g.start + g.name.len];
    return .{ .path = path.items, .segs = segs.items };
}

/// The scope defparam `segs` (declared in `decl`) is relative to once its
/// first segment is resolved, and how many segments that took (`skip`, 0
/// when the path is relative to `decl` itself). `children` is pass one's
/// static view of `decl`'s children; null reads the complete hierarchy.
fn defparamBase(r: *Run, decl: u32, segs: []const PathSeg, children: ?[]const Ast.Instance, tok: u32) Error!struct { at: u32, skip: u1 } {
    assert(tok < r.starts.len);
    assert(decl < r.hier.scopes.items.len);
    assert(segs.len >= 1);
    if (segs.len == 1) return .{ .at = decl, .skip = 0 };
    const name = segs[0].name;
    const index = segs[0].index;
    if (children) |list| {
        for (list) |c| if (c.name != .none and std.mem.eql(u8, r.file.str(c.name), name)) return .{ .at = decl, .skip = 0 };
    } else for (r.hier.scopes.items, 0..) |info, s| if (s != decl and info.parent == decl and isScope(r, @intCast(s), name, index)) return .{ .at = decl, .skip = 0 };
    var s = decl;
    while (true) {
        if (isScope(r, s, name, index)) return .{ .at = s, .skip = 1 };
        const info = r.hier.scopes.items[s];
        // §12.2.1: "a defparam statement in a hierarchy in or under a
        // generate block instance ... or an array of instances ... shall
        // not change a parameter value outside that hierarchy."
        if (index != null and info.index != null and info.name != .none and std.mem.eql(u8, r.file.str(info.name), name))
            return r.fail(tok, "§12.2.1: a defparam inside `{s}[{d}]` cannot change a parameter outside the generate block instance or array element it is in", .{ name, info.index.? });
        if (isRoot(r, s)) break;
        s = info.parent;
    }
    for (r.hier.roots) |t| if (isScope(r, t, name, index)) return .{ .at = t, .skip = 1 };
    return .{ .at = decl, .skip = 0 };
}

/// The scope defparam path `rest` names below `at` (its last segment, the
/// parameter, dropped), in the complete hierarchy; null when a segment
/// names no scope.
fn defparamScope(r: *const Run, at: u32, rest: []const PathSeg) ?u32 {
    assert(at < r.hier.scopes.items.len);
    assert(rest.len > 0);
    var s = at;
    // ponytail: a scan of every scope per segment; elaboration runs it once
    // per defparam. A (parent, name, index) map if designs grow huge.
    next: for (rest[0 .. rest.len - 1]) |seg| {
        for (r.hier.scopes.items, 0..) |info, c| if (c != s and info.parent == s and isScope(r, @intCast(c), seg.name, seg.index)) {
            s = @intCast(c);
            continue :next;
        };
        return null;
    }
    assert(s < r.hier.scopes.items.len);
    return s;
}

/// Whether scope `s` is `outer` or lies under it.
fn within(r: *const Run, s: u32, outer: u32) bool {
    assert(s < r.hier.scopes.items.len);
    assert(outer < r.hier.scopes.items.len);
    var at = s;
    while (at != outer) : (at = r.hier.scopes.items[at].parent) if (isRoot(r, at)) return false;
    return true;
}
