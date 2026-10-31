//! The design's `defparam`s in, each bound to the instance and parameter it names, checked against the hierarchy out.
//! Cites: IEEE 1364-2005 §12.2.1, §12.4.
//!
//! Contents:
//! - `pub fn bindDefparam(r: *Run, decl: u32, d: Ast.Defparam, children: []const Ast.Instance) Error!void`
//! - `pub fn checkDefparams(r: *Run) Error!void`
//! Pass one of elaboration: the parsed design and its root definitions ->
//! the slot space, the nets and the driver rows (`Elab`), the scope tree
//! (`Run.scope_info`) and every name bound in it, before any expression is
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

/// IEEE 1364-2005 §12.2.1 registers defparam `d`, declared in `decl`: its
/// unfolded instance selects folded there, then its first segment resolved
/// as §12.6 resolves a hierarchical name. It names a child of `decl` when
/// one of `children` (the instances the declaring text writes) has that
/// name, else `decl` or a scope above it by name, else a child that
/// elaboration mints later.
pub fn bindDefparam(r: *Run, decl: u32, d: Ast.Defparam, children: []const Ast.Instance) Error!void {
    var path: []const u8 = r.file.str(d.path);
    if (d.indices.len != 0) {
        var out: std.ArrayList(u8) = .empty;
        var rest = path;
        for (d.indices) |x| {
            const at = std.mem.find(u8, rest, "[]").?; // the parser spelled one per index
            const k = (try r.constant(x, d.main_tok)).asInt() orelse return r.exprFail(x, "§12.2.1: a defparam's instance select is x or z");
            try out.print(r.arena, "{s}[{d}]", .{ rest[0..at], k });
            rest = rest[at + 2 ..];
        }
        try out.appendSlice(r.arena, rest);
        path = out.items;
    }
    const b = try defparamBase(r, decl, path, children, d.main_tok);
    try r.defparams.put(r.arena, .{ .scope = b.at, .path = b.rest }, .{ .d = d, .decl = decl });
    try r.bound_defparams.append(r.arena, .{ .decl = decl, .path = path, .at = b.at, .rest = b.rest, .tok = d.main_tok });
}

/// IEEE 1364-2005 §12.8.2: "It shall be an error if a hierarchical name in a
/// defparam is resolved before the hierarchy is completely elaborated and
/// that name would resolve differently once the model is completely
/// elaborated."
pub fn checkDefparams(r: *Run) Error!void {
    for (r.bound_defparams.items) |b| {
        const now = try defparamBase(r, b.decl, b.path, null, b.tok);
        if (now.at != b.at or !std.mem.eql(u8, now.rest, b.rest))
            return r.fail(b.tok, "§12.8.2: this defparam's hierarchical name was resolved before the hierarchy was complete and would resolve differently once it is", .{});
        // §12.2.1: "a defparam statement in a hierarchy in or under a
        // generate block instance ... or an array of instances ... shall not
        // change a parameter value outside that hierarchy", however its path
        // is spelled (`defparamBase` refuses the upward relative form early).
        // §12.2.1: the hierarchical name names a parameter: E0901 when no
        // scope holds it, E0907 when a named instance has no such parameter.
        // A mixed design's defparam may name a VAMS §7.8.5 inserted connect
        // module, which only the analog elaboration builds.
        const target = defparamScope(r, b.at, b.rest) orelse if (r.mixed)
            continue
        else
            return r.failWith(.E0901, b.tok, "§12.2.1: this defparam's hierarchical name `{s}` names nothing in the design", .{b.path});
        const leaf = b.rest[if (std.mem.findScalarLast(u8, b.rest, '.')) |d| d + 1 else 0..];
        const slot = if (r.file.strings.find(leaf)) |str| r.names.get(.{ .scope = target, .str = str }) else null;
        // A mixed design leaves the analog block's parameters unbound here.
        if (!r.mixed and (slot == null or !r.params.contains(slot.?))) {
            if (slot == null and target == b.at and std.mem.findScalar(u8, b.rest, '.') == null)
                return r.failWith(.E0901, b.tok, "§12.2.1: this defparam's hierarchical name `{s}` names nothing in the design", .{b.path});
            return r.failWith(.E0907, b.tok, "§12.2.1: this defparam names `{s}`, which is no parameter of its module", .{leaf});
        }
        var s = b.decl;
        while (true) : (s = r.scope_info.items[s].parent) {
            const info = r.scope_info.items[s];
            if ((info.index != null or info.lexical) and !within(r, target, s)) {
                var name: std.ArrayList(u8) = .empty;
                try name.appendSlice(r.arena, r.file.str(info.name));
                if (info.index) |k| try name.print(r.arena, "[{d}]", .{k});
                return r.fail(b.tok, "§12.2.1: a defparam inside `{s}` cannot change a parameter outside the generate block instance or array element it is in", .{name.items});
            }
            if (isRoot(r, s)) break;
        }
    }
}

// ---- private ----

/// The scope defparam `path` (declared in `decl`) is relative to once its
/// first segment is resolved, and the rest of it. `children` is pass one's
/// static view of `decl`'s children; null reads the complete hierarchy.
fn defparamBase(r: *Run, decl: u32, path: []const u8, children: ?[]const Ast.Instance, tok: u32) Error!struct { at: u32, rest: []const u8 } {
    const dot = std.mem.findScalar(u8, path, '.') orelse return .{ .at = decl, .rest = path };
    const name, const index = segment(path[0..dot]);
    if (children) |list| {
        for (list) |c| if (c.name != .none and std.mem.eql(u8, r.file.str(c.name), name)) return .{ .at = decl, .rest = path };
    } else for (r.scope_info.items, 0..) |info, s| if (s != decl and info.parent == decl and isScope(r, @intCast(s), name, index)) return .{ .at = decl, .rest = path };
    var s = decl;
    while (true) {
        if (isScope(r, s, name, index)) return .{ .at = s, .rest = path[dot + 1 ..] };
        const info = r.scope_info.items[s];
        // §12.2.1: "a defparam statement in a hierarchy in or under a
        // generate block instance ... or an array of instances ... shall
        // not change a parameter value outside that hierarchy."
        if (index != null and info.index != null and info.name != .none and std.mem.eql(u8, r.file.str(info.name), name))
            return r.fail(tok, "§12.2.1: a defparam inside `{s}[{d}]` cannot change a parameter outside the generate block instance or array element it is in", .{ name, info.index.? });
        if (isRoot(r, s)) break;
        s = info.parent;
    }
    for (r.roots) |t| if (isScope(r, t, name, index)) return .{ .at = t, .rest = path[dot + 1 ..] };
    return .{ .at = decl, .rest = path };
}

/// A hierarchical name segment `name` or `name[k]`; a `k` that is not a
/// decimal integer reads as no index.
fn segment(seg: []const u8) struct { []const u8, ?i64 } {
    const bracket = std.mem.findScalar(u8, seg, '[') orelse return .{ seg, null };
    return .{ seg[0..bracket], std.fmt.parseInt(i64, seg[bracket + 1 .. seg.len - 1], 10) catch null };
}

/// The scope defparam path `rest` names below `at` (its last segment, the
/// parameter, dropped), in the complete hierarchy; null when a segment
/// names no scope.
fn defparamScope(r: *const Run, at: u32, rest: []const u8) ?u32 {
    var s = at;
    var it = std.mem.splitScalar(u8, rest[0 .. std.mem.findScalarLast(u8, rest, '.') orelse return s], '.');
    // ponytail: a scan of every scope per segment; elaboration runs it once
    // per defparam. A (parent, name, index) map if designs grow huge.
    next: while (it.next()) |seg| {
        const name, const index = segment(seg);
        for (r.scope_info.items, 0..) |info, c| if (c != s and info.parent == s and isScope(r, @intCast(c), name, index)) {
            s = @intCast(c);
            continue :next;
        };
        return null;
    }
    return s;
}

/// Whether scope `s` is `outer` or lies under it.
fn within(r: *const Run, s: u32, outer: u32) bool {
    var at = s;
    while (at != outer) : (at = r.scope_info.items[at].parent) if (isRoot(r, at)) return false;
    return true;
}
