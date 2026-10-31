//! A module's parameter declarations and the overrides that reach them in, each parameter's elaborated value out, with §14.3 `specify` ordering.
//! Cites: IEEE 1364-2005 §4.10, §12.2, §14.3; VAMS §6.3.
//!
//! Contents:
//! - `pub fn ieee1364(r: *const Run) bool`
//! - `pub fn declareParams(r: *Run, scope: u32, declared_params: []const Ast.ParamDecl, over: []const Ast.ParamOverride) Error!void`
//! - `pub fn names(r: *Run, e: Ast.ExprId, name: Ast.StrId) bool`
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
const elab_drivers = @import("elab_drivers.zig");
const elab_ports = @import("elab_ports.zig");
const putRange = elab_ports.putRange;
const scopePath = elab_drivers.scopePath;

const ParamValue = struct { v: Int.Literal, real: bool = false };

/// Whether the design is read as IEEE 1364 (`--std=1364-*`), whose §12.3.9.2
/// port connection converts widths, rather than Verilog-AMS, whose §6.5.7.1
/// requires them to match.
pub fn ieee1364(r: *const Run) bool {
    return switch (r.opts.language) {
        .v1364_1995, .v1364_2001, .v1364_2001_noconfig, .v1364_2005 => true,
        .vams_2_3, .vams_2023 => false,
    };
}

/// IEEE 1364-2005 §12.2 the parameters `params` of `scope` (an instance, or a
/// §12.5 named block, which `over` never reaches), in declaration order so a
/// default may name an earlier one.
pub fn declareParams(r: *Run, scope: u32, declared_params: []const Ast.ParamDecl, over: []const Ast.ParamOverride) Error!void {
    assert(scope < r.scope_info.items.len);
    const arena = r.arena;
    const params = try specifyOrder(r, declared_params);
    const g = r.growing.?;
    const path = if (r.real_card.len != 0) try scopePath(r, scope) else "";
    var positional: usize = 0;
    for (params) |p| {
        const pos = positional;
        if (!p.is_local) positional += 1;
        const real_value = for (r.real_card) |c| {
            if (std.mem.startsWith(u8, c.name, path) and std.mem.eql(u8, c.name[path.len..], r.file.str(p.name))) break c.value;
        } else null;
        if (p.dims.len != 0 or p.ty == .string or (r.mixed and p.ty == .real and real_value == null)) {
            if (r.mixed) continue;
            return r.fail(p.main_tok, "only scalar integral and real parameters are implemented by digital execution", .{});
        }
        // The host has applied §6.3 overrides and dependent defaults already;
        // re-evaluating one here could reject a legal analog constant function
        // or silently restore a default instead of this analysis's card.
        // §12.2: a range or a type (`signed` is one) converts the value like
        // an assignment; otherwise the parameter takes the type of its value.
        const declared: ?u32 = if (p.packed_range) |range| try r.declaredWidth(range, p.main_tok) else if (p.ty == .integer) @as(u32, if (p.is_time) 64 else 32) else null;
        const pv: ParamValue = if (real_value) |v| .{ .v = try evaluate.realLiteral(arena, v), .real = true } else (try paramValue(r, p, scope, over, pos, declared orelse 0)) orelse continue;
        const ty: compile.Type = if (p.packed_range != null)
            .{ .width = declared.?, .signed = p.is_signed }
        else if (p.ty == .integer)
            // §4.10.1: `time` is unsigned 64-bit, `integer` signed 32-bit.
            .{ .width = declared.?, .signed = !p.is_time }
        else if (p.ty == .real or (pv.real and !p.is_signed))
            compile.real_type
        else
            .{ .width = if (pv.real) 64 else pv.v.width, .signed = p.is_signed or pv.v.signed };
        const converted = try evaluate.convertValue(arena, pv.v, pv.real, ty);
        const at: u32 = @intCast(g.items.len);
        try r.bind(p.name, at, p.main_tok);
        const slot_value = try filled(arena, ty.width, ty.signed, .zero);
        @memcpy(slot_value.planes, converted.planes);
        try g.append(arena, slot_value);
        try r.params.put(arena, at, {});
        if (ty.real) try r.reals.put(arena, at, {});
        // A specify block's specparam has no declare-before-reference rule
        // (§4.10.3 binds only one outside a block): token 0 never trips it.
        if (p.is_spec) try r.specparams.put(arena, at, if (p.in_specify) 0 else p.main_tok);
        // §4.10.1: a select of a ranged parameter indexes its declared range.
        if (p.packed_range) |range| try putRange(r, at, range, p.main_tok);
    }
    r.values = g.items;
}

/// Whether expression `e` reads the plain name `name`.
pub fn names(r: *Run, e: Ast.ExprId, name: Ast.StrId) bool {
    const ex = &r.file.exprs;
    if (e == .none) return false;
    if (ex.tag(e) == .ident) return ex.strOf(e) == name;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (names(r, c, name)) return true;
    return false;
}

// ---- private ----

/// `params` with each specify-block specparam moved after the specify-block
/// specparams its value names: §4.10.3 binds only one "declared outside a
/// specify block" to be "declared before it is referenced", so inside one a
/// specparam may name a later one (iverilog's
/// specparam_specify_reference_order). A cycle keeps the written order,
/// whose first forward name is then refused as undefined.
fn specifyOrder(r: *Run, params: []const Ast.ParamDecl) Error![]const Ast.ParamDecl {
    for (params) |p| {
        if (p.in_specify) break;
    } else return params;
    const out = try r.arena.alloc(Ast.ParamDecl, params.len);
    const placed = try r.arena.alloc(bool, params.len);
    @memset(placed, false);
    var n: usize = 0;
    while (n < params.len) {
        const before = n;
        for (params, 0..) |p, i| {
            if (placed[i]) continue;
            // Anything else keeps its place after every earlier item.
            const blocked = if (p.in_specify) blk: {
                for (params, 0..) |q, j| if (!placed[j] and j != i and q.in_specify and names(r, p.default, q.name)) break :blk true;
                break :blk false;
            } else for (0..i) |j| {
                if (!placed[j]) break true;
            } else false;
            if (blocked) continue;
            out[n] = p;
            placed[i] = true;
            n += 1;
        }
        if (n == before) for (params, 0..) |p, i| if (!placed[i]) {
            out[n] = p;
            placed[i] = true;
            n += 1;
        };
    }
    return out;
}

/// IEEE 1364-2005 §12.2 the value parameter `p` of the instance `scope`
/// takes, from the first of: a `defparam` naming it (§12.2.1, which "shall
/// take precedence"), the instance's `#( … )` by name or position (§12.2.2),
/// at a mixed design's root the host's card (the `Model` value the analog
/// block reads), and its declared default. Each is a constant expression in
/// the scope that wrote it. null: in a mixed design, a value this engine does
/// not fold (a real, or one naming the analog block's), so the parameter is
/// the analog block's alone. `real`: `v` holds a real's 64 bits.
fn paramValue(r: *Run, p: Ast.ParamDecl, scope: u32, over: []const Ast.ParamOverride, pos: usize, width: u32) Error!?ParamValue {
    const Src = struct { e: Ast.ExprId, scope: u32 };
    const src: Src = blk: {
        // A defparam's path is relative to the scope `bindDefparam` bound
        // it to, so each enclosing scope is asked for the path from it down
        // to `p`.
        var at = scope;
        var path: []const u8 = r.file.str(p.name);
        while (true) {
            if (r.defparams.get(.{ .scope = at, .path = path })) |dp| {
                if (p.is_local) return r.fail(dp.d.main_tok, "§12.2: `{s}` is a local parameter, which a defparam cannot override", .{r.file.str(p.name)});
                break :blk .{ .e = dp.d.value, .scope = dp.decl };
            }
            const info = r.scope_info.items[at];
            if (isRoot(r, at)) {
                // §12.2.1: a defparam in one top-level module may name a
                // parameter under another by its full hierarchical name.
                const full = try r.arena.print("{s}.{s}", .{ r.file.str(info.name), path });
                for (r.roots) |t| {
                    if (t == at) continue;
                    if (r.defparams.get(.{ .scope = t, .path = full })) |dp| break :blk .{ .e = dp.d.value, .scope = dp.decl };
                }
                break;
            }
            path = if (info.index) |k|
                try r.arena.print("{s}[{d}].{s}", .{ r.file.str(info.name), k, path })
            else
                try r.arena.print("{s}.{s}", .{ r.file.str(info.name), path });
            at = info.parent;
        }
        if (!p.is_local) for (over, 0..) |o, i| {
            if (o.value != .none and (o.name == p.name or (o.name == .none and i == pos)))
                break :blk .{ .e = o.value, .scope = r.scope_info.items[scope].parent };
        };
        break :blk .{ .e = p.default, .scope = scope };
    };
    r.scope = src.scope;
    defer r.scope = scope;
    if (r.mixed and !compile.constantExpression(r, src.e)) return null;
    // Parameters bind before any other name of the instance, so a name that
    // does not resolve yet is no previously defined parameter.
    if (unresolved(r, src.e)) |x| return r.exprFail(x, "§4.10.1: a parameter's value is a constant expression of numbers and previously defined parameters, and this name is neither");
    const value = try r.constant(src.e, p.main_tok);
    // §4.10.3: "module parameters shall not be assigned a constant
    // expression that includes any specify parameters".
    if (!p.is_spec and readsSpecparam(r, src.e))
        return r.exprFail(src.e, "§4.10.3: a module parameter cannot be assigned an expression that includes a specify parameter");
    if (r.mixed and compile.typeOf(r, src.e).real) return null;
    if (isRoot(r, scope) and !p.is_local) for (r.opts.params) |o| if (std.mem.eql(u8, o.name, r.file.str(p.name))) {
        // `vera --param`: a string-defaulted parameter takes the text as a
        // §3.6 string; otherwise an integer's text is an integer, a real's a
        // real and any other text a string, as the literal would be.
        if (r.file.exprs.tag(p.default) == .str_literal) return .{ .v = try evaluate.stringLiteral(r.arena, o.text) };
        if (std.fmt.parseInt(i64, o.text, 10)) |n| {
            const w = try filled(r.arena, 64, true, .zero);
            w.values()[0] = @bitCast(n);
            const fits = std.math.cast(i32, n) != null;
            return .{ .v = try evaluate.normalize(r.arena, w, .{ .width = if (fits) 32 else 64, .signed = true }) };
        } else |_| {}
        if (!std.math.isNan(o.value)) return .{ .v = try evaluate.realLiteral(r.arena, o.value), .real = true };
        return .{ .v = try evaluate.stringLiteral(r.arena, o.text) };
    };
    if (scope == 0 and !p.is_local) for (r.card) |c| if (std.mem.eql(u8, c.name, r.file.str(p.name))) {
        // VAMS §6.3: the card sets the root's parameter as a `#( … )` would;
        // an integer one takes the value rounded, as the device's does.
        const w = try filled(r.arena, 64, true, .zero);
        w.values()[0] = @bitCast(std.math.lossyCast(i64, @round(c.value)));
        return .{ .v = try evaluate.normalize(r.arena, w, .{ .width = 32, .signed = true }) };
    };
    if (compile.typeOf(r, src.e).real) return .{ .v = try evaluate.realLiteral(r.arena, try evaluate.evalReal(r, r.arena, src.e)), .real = true };
    // §4.10.1/§5.4.1: a declared range or type is the context the value is
    // evaluated in, as an assignment's left side is.
    if (width > value.width) return .{ .v = try evaluate.eval(r, r.arena, src.e, width) };
    return .{ .v = value };
}

/// The first name in `e` that does not resolve in the current scope.
fn unresolved(r: *Run, e: Ast.ExprId) ?Ast.ExprId {
    assert(e != .none);
    const ex = &r.file.exprs;
    if (ex.tag(e) == .ident) return if (r.lookup(r.scope, ex.strOf(e)) == null) e else null;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (c != .none) if (unresolved(r, c)) |x| return x;
    return null;
}

/// Does `e`, read in the current scope, name a specparam?
fn readsSpecparam(r: *Run, e: Ast.ExprId) bool {
    assert(e != .none);
    const ex = &r.file.exprs;
    if (ex.tag(e) == .ident) return if (r.lookup(r.scope, ex.strOf(e))) |at| r.specparams.contains(at) else false;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (c != .none and readsSpecparam(r, c)) return true;
    return false;
}
