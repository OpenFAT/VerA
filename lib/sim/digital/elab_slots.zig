//! A variable, array, net or subroutine frame in, the slots it occupies out (`Run.values`), with VAMS's wreal promotion.
//! Cites: IEEE 1364-2005 §4.9, §10.2.3, §12.3.3; VAMS §3.7.
//!
//! Contents:
//! - `pub fn mintVar(r: *Run, v: Ast.VarDecl) Error!u32`
//! - `pub fn declareArray(r: *Run, base: u32, dims: []const Ast.Dim, tok: u32) Error!u32`
//! - `pub fn netSlot(r: *Run, e: Ast.ExprId, tok: u32) Error!u32`
//! - `pub fn usesReal(t: *const Ast.Subroutine) bool`
//! - `pub fn frame(r: *Run, t: *const Ast.Subroutine, inst: u32) Error!Frame`
//! - `pub fn earlyFrame(r: *Run, idx: u32, tok: u32) Error!void`
//! - `pub fn promoteWreal(r: *Run, e: *Elab, net: u32) Error!void`
//! - `pub fn mintNet(r: *Run, e: *Elab, kind: Ast.NetKind, width: u32, signed: bool, name: Ast.StrId, tok: u32) Error!u32`
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
const elab = @import("elab.zig");
const elab_declare = @import("elab_declare.zig");
const elab_params = @import("elab_params.zig");
const elab_ports = @import("elab_ports.zig");
const Elab = elab.Elab;
const declareEvents = elab_declare.declareEvents;
const declareParams = elab_params.declareParams;
const newScope = elab.newScope;
const putRange = elab_ports.putRange;
const sameRange = elab_declare.sameRange;

/// One variable's storage in the current scope (a whole value, or §3.9's
/// array of them), bound to its name. Works in both passes: an automatic
/// task inlined at a call site gets fresh storage while pass two compiles it.
pub fn mintVar(r: *Run, v: Ast.VarDecl) Error!u32 {
    const g = r.growing.?;
    if (v.ty == .string) return r.fail(v.main_tok, "string variables are not implemented", .{});
    const real = v.ty == .real;
    // §4.8: `integer` is 32 signed bits and `time` 64 unsigned ones.
    // §4.8: a real is a double, held as its 64 bits.
    const width: u32 = if (real) 64 else if (v.packed_range) |range| try r.declaredWidth(range, v.main_tok) else switch (v.storage) {
        .reg => 1,
        .variable => 32,
        .time => 64,
    };
    const base: u32 = @intCast(g.items.len);
    try r.bind(v.name, base, v.main_tok);
    if (v.packed_range) |range| try putRange(r, base, range, v.main_tok);
    const count = try declareArray(r, base, v.dims, v.main_tok);
    if (count > std.math.maxInt(u32) - g.items.len) return r.fail(v.main_tok, "too many digital storage slots", .{});
    const signed = switch (v.storage) {
        .reg => v.is_signed,
        .variable => true,
        .time => false,
    };
    // §4.8: "the default initial value for real ... shall be 0.0"; every
    // other variable starts at x (§3.2).
    for (0..count) |i| {
        try g.append(r.arena, try filled(r.arena, width, signed or real, if (real) .zero else .x));
        if (real) try r.reals.put(r.arena, base + @as(u32, @intCast(i)), {});
    }
    r.values = g.items;
    return base;
}

/// §4.9 the `arrays` row of the array whose first element is `base`, declared
/// with `dims`, and its element count; 1, and no row, for no dimensions.
pub fn declareArray(r: *Run, base: u32, dims: []const Ast.Dim, tok: u32) Error!u32 {
    assert(tok < r.starts.len);
    if (dims.len == 0) return 1;
    var count: u32 = 1;
    const spans = try r.arena.alloc(Span, dims.len);
    var left: i64 = 0;
    var right: i64 = 0;
    for (dims, spans, 0..) |d, *s, k| {
        const lo = try r.declaredBound(d.lsb, tok);
        const hi = try r.declaredBound(d.msb, tok);
        if (k == 0) {
            left = hi;
            right = lo;
        }
        s.* = .{ .low = @min(lo, hi), .high = @max(lo, hi), .descending = hi > lo };
        const size = std.math.cast(u32, @as(i128, s.high) - s.low + 1) orelse return r.fail(tok, "unpacked array size is outside the supported u32 range", .{});
        count = std.math.mul(u32, count, size) catch return r.fail(tok, "unpacked array size is outside the supported u32 range", .{});
    }
    try r.arrays.put(r.arena, base, .{ .count = count, .low = spans[0].low, .high = spans[0].high, .left = left, .right = right, .rest = spans[1..] });
    return count;
}

/// §4.9.1 the slot a driver, a port connection or a §9.3.2 `force` drives: a whole net, or one
/// element of a net array named with a constant index per dimension.
pub fn netSlot(r: *Run, e: Ast.ExprId, tok: u32) Error!u32 {
    assert(e != .none);
    assert(tok < r.starts.len);
    const arr = (try r.indexedArray(e)) orelse return r.scalarSlot(e);
    const ex = &r.file.exprs;
    const c = r.chainBase(e);
    var offset: evaluate.Offset = .{};
    var inside = true;
    var x = e;
    var k = c.depth;
    while (k != 0) : (x = ex.lhs(x)) {
        k -= 1;
        inside = offset.add(arr, k, try r.declaredBound(ex.rhs(x), tok)) and inside;
    }
    if (!inside) return r.fail(tok, "§4.9: an array index is outside its declared range", .{});
    return try r.slot(c.base) + offset.at;
}

pub fn usesReal(t: *const Ast.Subroutine) bool {
    if (t.is_function and t.result.ty != .integer) return true;
    for (t.ports) |p| if (p.v.ty != .integer) return true;
    for (t.vars) |v| if (v.ty != .integer) return true;
    return false;
}

/// A fresh frame for `t` inside instance `inst`: its static one in pass one,
/// an automatic task's per-call-site one in pass two.
pub fn frame(r: *Run, t: *const Ast.Subroutine, inst: u32) Error!Frame {
    const g = r.growing.?;
    // §10.4.4 c) and d): at least one input, and no output or inout.
    if (t.is_function) {
        for (t.ports) |p| if (p.direction != .input)
            return r.fail(p.v.main_tok, "§10.4.4: a function argument is an input, not an output or inout", .{});
        if (t.ports.len == 0) return r.fail(t.main_tok, "§10.4.1: a function shall have at least one input declared", .{});
    }
    const scope = try newScope(r, t.main_tok);
    try r.hier.scopes.append(r.arena, .{ .parent = inst, .name = t.name, .def = r.hier.scopes.items[inst].def, .lexical = true });
    const saved = r.scope;
    r.scope = scope;
    defer r.scope = saved;
    // §4.10: parameters are constants, not automatic variables. Keep their
    // slots outside the activation's saved/reset range on both execution
    // paths. Declaring them first also lets formal ranges read them.
    try declareParams(r, scope, t.params, &.{});
    const first: u32 = @intCast(g.items.len);
    const ports = try r.arena.alloc(u32, t.ports.len);
    // §10.2.1/§10.4.1: a non-ANSI port's type may come from a following
    // declaration of its name (`input x; real x;`), which declares the port.
    // `redeclaredPort` has judged the pair by §12.3.3.
    // ponytail: an ANSI port redeclared in the body is taken the same way,
    // not refused.
    for (t.ports) |p| try redeclaredPort(r, p);
    for (t.ports, ports) |p, *slot| slot.* = try mintVar(r, for (t.vars) |v| {
        if (v.name == p.v.name) break v;
    } else p.v);
    const result = if (t.is_function) try mintVar(r, t.result) else 0;
    try declareEvents(r, t.events);
    vars: for (t.vars) |v| {
        for (t.ports) |p| if (p.v.name == v.name) continue :vars;
        if (v.init != .none) return r.fail(v.main_tok, "an initialized task or function variable is not implemented", .{});
        _ = try mintVar(r, v);
    }
    if (t.automatic) {
        try r.routines.auto_scopes.put(r.arena, scope, {});
        for (first..g.items.len) |at| try r.routines.auto_slots.put(r.arena, @intCast(at), {});
    }
    return .{ .scope = scope, .ports = ports, .result = result, .first = first, .count = @as(u32, @intCast(g.items.len)) - first };
}

/// §10.4.5: function `idx`, called by a constant function call before its
/// instance's frames exist (a parameter's value), framed, judged a constant
/// function and compiled now, so `exec.callSync` can run it during
/// elaboration.
pub fn earlyFrame(r: *Run, idx: u32, tok: u32) Error!void {
    assert(tok < r.starts.len);
    const sub = &r.routines.rows.items[idx];
    sub.frame = try frame(r, sub.decl, sub.inst);
    sub.framed = true;
    if (try compile.notConstant(r, idx)) |why|
        return r.fail(tok, "§10.4.5: a function called during elaboration is a constant function, and {s}", .{why});
    const saved = r.scope;
    defer r.scope = saved;
    const first = r.disables.items.len;
    try compile.compileSub(r, idx);
    try root.bindDisables(r, first);
}

/// VAMS §3.7's port merge: a wire or tri joined to a wreal port becomes one
/// wreal net, for every other connection to it too. `Front.wreal.check` has
/// already refused the net types §3.7 does not call compatible.
pub fn promoteWreal(r: *Run, e: *Elab, net: u32) Error!void {
    const n = &e.nets.items[net];
    if (n.kind == .wreal) return;
    n.kind = .wreal;
    n.resolved = try filled(r.arena, 64, false, .z);
    e.values.items[n.slot] = try filled(r.arena, 64, true, .zero);
    r.values = e.values.items;
    try r.reals.put(r.arena, n.slot, {});
}

/// One new net and its slot, `name` (unless `.none`) bound to it in the
/// current scope; returns the net's index. Invalidates pointers into
/// `e.values`, `e.nets` and `e.signals`.
pub fn mintNet(r: *Run, e: *Elab, kind: Ast.NetKind, width: u32, signed: bool, name: Ast.StrId, tok: u32) Error!u32 {
    assert(tok < r.starts.len);
    if (e.values.items.len == std.math.maxInt(u32)) return r.fail(tok, "too many digital storage slots", .{});
    const slot: u32 = @intCast(e.values.items.len);
    const at: u32 = @intCast(e.nets.items.len);
    if (name != .none) try r.bind(name, slot, tok);
    // §3.7: a net with no driver is z, not x, except where the net type itself
    // supplies a value. VAMS §3.7:
    // a wreal carries a real and "shall have an initial value of zero".
    const wreal = kind == .wreal;
    try e.values.append(r.arena, try filled(r.arena, if (wreal) 64 else width, signed or wreal, if (wreal) .zero else undriven(kind)));
    if (wreal) try r.reals.put(r.arena, slot, {});
    if (e.signals.items.len > std.math.maxInt(u32) - width) return r.fail(tok, "too many digital net bits", .{});
    const signal: u32 = @intCast(e.signals.items.len);
    try e.signals.appendNTimes(r.arena, .{}, width);
    try e.nets.append(r.arena, .{ .kind = kind, .slot = slot, .resolved = try filled(r.arena, if (wreal) 64 else width, false, .z), .signal = signal, .tok = tok });
    try r.net_of.put(r.arena, slot, at);
    return at;
}

// ---- private ----

/// IEEE 1364-2005 §12.3.3's port rules, which a task's or function's body
/// port follows as a module's does (iverilog refuses the same): "If a port
/// declaration includes a net or variable type, then the port is considered
/// completely declared, and it is an error for the port to be declared
/// again"; otherwise "If the net or variable is declared as a vector, the
/// range specification between the two declarations of a port shall be
/// identical. Once a name is used in a port declaration, it shall not be
/// declared again". An `integer`, `time` or `real` redeclaration has a
/// range of its own, so it may only follow a port declared without one.
fn redeclaredPort(r: *Run, p: Ast.TfPort) Error!void {
    const d = p.redecl;
    if (d.count == 0) return;
    if (d.typed) return r.fail(d.tok, "§12.3.3: a port declared with a type is completely declared; this is a duplicate declaration of it", .{});
    if (d.count > 1) return r.fail(d.tok, "§12.3.3: a duplicate declaration of a port's variable; a port is declared again at most once", .{});
    if (p.v.storage != .reg) {
        if (d.port_range != null) return r.fail(d.tok, "§12.3.3: this variable's range differs from its port declaration's: a port with a range is declared again only as a reg of the same range", .{});
        return;
    }
    const same = if (d.port_range) |a| if (d.var_range) |b| try sameRange(r, a, b, d.tok) else false else d.var_range == null;
    if (!same) return r.fail(d.tok, "§12.3.3: this variable's range differs from its port declaration's; the two shall be identical", .{});
}
