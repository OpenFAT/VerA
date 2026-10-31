//! A generate construct in, its iterations' scopes, genvars and nets out.
//! Cites: IEEE 1364-2005 §12.4.
//!
//! Contents:
//! - `pub fn isGenerate(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, s: Ast.StmtId) bool`
//! - `pub fn generate(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, s: Ast.StmtId, depth: u32) Error!void`
//! - `pub fn declareNet(r: *Run, e: *Elab, scope: u32, n: Ast.NetDecl) Error!void`
//! - `pub fn selectable(r: *Run, scope: u32, name: Ast.StrId, k: i64, at: u32) Error!void`
//! - `pub fn generatedModules(file: *const Ast.SourceFile, s: Ast.StmtId, out: *std.ArrayList(Ast.StrId), a: std.mem.Allocator) std.mem.Allocator.Error!void`
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
const max_depth = elab.max_depth;
const elab_declare = @import("elab_declare.zig");
const elab_defparams = @import("elab_defparams.zig");
const elab_drivers = @import("elab_drivers.zig");
const elab_params = @import("elab_params.zig");
const elab_ports = @import("elab_ports.zig");
const elab_slots = @import("elab_slots.zig");
const Elab = elab.Elab;
const bindDefparam = elab_defparams.bindDefparam;
const blockScopes = elab_declare.blockScopes;
const continuous = elab_drivers.continuous;
const declareArray = elab_slots.declareArray;
const declareDrivers = elab_drivers.declareDrivers;
const declareEvents = elab_declare.declareEvents;
const declareParams = elab_params.declareParams;
const defOf = elab.defOf;
const frame = elab_slots.frame;
const instantiate = elab.instantiate;
const mintNet = elab_slots.mintNet;
const mintVar = elab_slots.mintVar;
const newScope = elab.newScope;
const putRange = elab_ports.putRange;

/// IEEE 1364-2005 §12.4 a generate construct as a digital parse leaves it:
/// an `if` or `case` whose arms are blocks, or a `for` over a genvar (§12.4.1:
/// what tells a loop generate from a loop statement is its genvar).
pub fn isGenerate(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, s: Ast.StmtId) bool {
    assert(s != .none);
    return switch (file.stmt(s)) {
        .if_stmt => |i| i.is_generate,
        .case_stmt => |c| c.is_generate,
        .for_stmt => |f| genvarOf(file, m, f) != null,
        else => false, // else: every other analog-block body is analog behaviour
    };
}

/// §12.4: the scheme's constant expressions select at most one arm of an
/// `if` or `case` (§12.4.2) and unroll a `for` once per genvar value
/// (§12.4.1), and only the selected blocks' instances come into existence
/// (§12.1.1: an instance in an unselected arm still makes its module no
/// top-level one).
/// A block's events, drivers and processes are declared in the scope it is
/// elaborated in (`Ast.GenItems`), which is the block's own (`armScope`).
pub fn generate(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, s: Ast.StmtId, depth: u32) Error!void {
    assert(scope < r.hier.scopes.items.len);
    // A digital parse keeps a generate block's nets on the block
    // (`parseGenerateBlock`), so the `.block` arm declares one set per loop
    // iteration, in that iteration's scope. ponytail: a part-select bound
    // written with a genvar is folded once, with the first iteration's value;
    // a bit-select is read per iteration.
    if (s == .none) return;
    assert(depth < max_depth);
    const tok = r.file.stmtTok(s);
    switch (r.file.stmt(s)) {
        .empty => {},
        .if_stmt => |i| {
            r.scope = scope;
            const cond = (try r.constant(i.cond, tok)).truth();
            const arm = if (cond == .one) i.then_s else i.else_s;
            try generate(r, e, m, try armScope(r, scope, arm, tok), arm, depth);
        },
        // §12.4.2: "the case_generate_item selected is the one whose
        // expression matches the case expression", the default otherwise.
        .case_stmt => |c| {
            r.scope = scope;
            const value = try r.constant(c.scrutinee, tok);
            var chosen: ?Ast.StmtId = null;
            var fallback: Ast.StmtId = .none;
            for (c.arms) |arm| {
                if (arm.labels.len == 0) fallback = arm.body;
                for (arm.labels) |label| {
                    if (chosen != null) break;
                    const l = try r.constant(label, tok);
                    const ty: Type = .{ .width = @max(l.width, value.width), .signed = l.signed and value.signed };
                    if ((try evaluate.convert(r.arena, value, ty)).equality(.case_equal, try evaluate.convert(r.arena, l, ty)) == .one) chosen = arm.body;
                }
            }
            const arm = chosen orelse fallback;
            try generate(r, e, m, try armScope(r, scope, arm, tok), arm, depth);
        },
        // §12.4.1: the genvar steps through its values in the module's scope,
        // and each iteration's block is a scope of its own, `name[value]`, in
        // which the genvar is a local parameter holding that value.
        .for_stmt => |f| {
            const gv = genvarOf(r.file, m, f) orelse return r.fail(tok, "§12.4.1: a loop generate's index is a genvar", .{});
            const step = switch (r.file.stmt(f.step)) {
                .assign => |a| a,
                else => return r.fail(tok, "§12.4.1: a loop generate's iteration assigns its genvar", .{}), // else: A.4.2 genvar_iteration is an assignment
            };
            if (r.file.exprs.tag(step.target) != .ident or r.file.exprs.strOf(step.target) != gv)
                return r.fail(tok, "§12.4.1: a loop generate's iteration assigns its genvar", .{});
            r.scope = scope;
            if (r.hier.scopes.items[scope].index != null and r.hier.names.contains(.{ .scope = scope, .str = gv }))
                return r.fail(tok, "§12.4.1: two nested loop generate constructs cannot use the same genvar", .{});
            const at = r.hier.names.get(.{ .scope = scope, .str = gv }) orelse try genvarSlot(r, e, gv, tok);
            try setGenvar(r, e, at, try r.constant(r.file.stmt(f.init).assign.value, tok));
            // §12.4.3 an unnamed block's external name, genblk<n>.
            const name: Ast.StrId, const implicit = switch (r.file.stmt(f.body)) {
                .block => |b| .{ b.gen_name, b.name == .none },
                else => .{ .none, true }, // else: a lone item is an unnamed generate block
            };
            // §12.4.1: "It shall be an error if a genvar value is repeated".
            // A genvar holds 32 bits, so a loop that does not terminate
            // repeats one within 2^32 iterations: this set is the loop's
            // non-termination test, and no count bounds a loop that ends.
            var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
            while ((try r.constant(f.cond, tok)).truth() == .one) {
                const value = e.values.items[at].asInt() orelse return r.fail(tok, "§12.4.1: a genvar shall not be x or z", .{});
                if ((try seen.fetchPut(r.arena, value, {})) != null) return r.fail(tok, "§12.4.1: a genvar value is repeated, so this loop generate does not terminate", .{});
                const iter = try newScope(r, tok);
                try r.hier.scopes.append(r.arena, .{ .parent = scope, .name = name, .def = defOf(r, m), .lexical = true, .index = value, .implicit = implicit });
                try selectable(r, scope, name, value, iter);
                r.scope = iter;
                try setGenvar(r, e, try genvarSlot(r, e, gv, tok), e.values.items[at]);
                try generate(r, e, m, iter, f.body, depth);
                r.scope = scope;
                try setGenvar(r, e, at, try r.constant(step.value, tok));
            }
        },
        .block => |b| {
            r.scope = scope;
            // §12.4.1: so are its parameters, first, as its nets' ranges and
            // nested generate conditions may read them.
            try declareParams(r, scope, b.params, &.{});
            // A.1.4: its tasks and functions too, named and framed in its
            // scope (`sub_by_name` keyed by the generate scope).
            const sub_first = r.routines.rows.items.len;
            for (b.gen.tasks) |*t| {
                const entry = try r.routines.by_name.getOrPut(r.arena, .{ .scope = scope, .str = t.name });
                if (entry.found_existing) return r.fail(t.main_tok, "duplicate task or function", .{});
                entry.value_ptr.* = @intCast(r.routines.rows.items.len);
                try r.routines.rows.append(r.arena, .{ .decl = t, .inst = scope, .frame = undefined });
            }
            for (r.routines.rows.items[sub_first..]) |*sub| {
                sub.frame = try frame(r, sub.decl, scope);
                sub.framed = true;
                if (!sub.decl.automatic) try r.hier.instances.put(r.arena, .{ .scope = scope, .str = sub.decl.name }, sub.frame.scope);
                try blockScopes(r, sub.frame.scope, sub.decl.body);
            }
            r.scope = scope;
            // §12.4: a generate block's nets are its scope's, one set per
            // loop iteration.
            for (b.gen.nets) |n| try declareNet(r, e, scope, n);
            if (b.gen.nets.len != 0) try r.decls.gen_nets.put(r.arena, scope, b.gen.nets);
            for (b.gen.defparams) |d| try bindDefparam(r, scope, d, b.instances);
            try declareEvents(r, b.gen.events);
            try declareDrivers(r, e, scope, b.gen.*, &.{});
            // §12.4: so are its variables, which §12.5 names reach as
            // `blk[i].v` (#56). A mixed design's are the analog block's
            // (§7.2.2), as `declare` leaves a module's.
            // ponytail: a mixed design's generate-block variables stay
            // undeclared here; give them `declare`'s domain test when a
            // digital process there needs to write one.
            const vars: []const Ast.VarDecl = if (r.analog.mixed) &.{} else b.vars;
            for (vars) |v| {
                if (v.init != .none and v.dims.len != 0) return r.fail(v.main_tok, "an unpacked array declaration takes no initializer", .{});
                _ = try mintVar(r, v);
            }
            if (b.gen.discrete.len != 0 or vars.len != 0) try e.procs.append(r.arena, .{ .scope = scope, .blocks = b.gen.discrete, .vars = vars });
            for (b.gen.discrete) |d| try blockScopes(r, scope, d.body);
            for (b.instances) |*inst| try instantiate(r, e, scope, inst, depth);
            // A mixed design's generate block also holds its analog blocks,
            // which are the analog compile's.
            for (b.body) |inner| if (!r.analog.mixed or isGenerate(r.file, m, inner)) try generate(r, e, m, scope, inner, depth);
        },
        else => return r.fail(tok, "only generate constructs of instances are implemented by digital execution", .{}), // else: analog behaviour inside a generate block
    }
}

/// One A.2.1.3 net declaration of `scope`: the net, or a §4.9.1 net
/// array's elements, and a net_decl_assignment's driver.
pub fn declareNet(r: *Run, e: *Elab, scope: u32, n: Ast.NetDecl) Error!void {
    assert(scope < r.hier.scopes.items.len);
    const arena = r.arena;
    // §7.2.1: a disciplined net is continuous, the analog solver's.
    if (r.analog.mixed and (n.is_ground or continuous(r.file, n.discipline))) return;
    if (!r.analog.mixed and (n.discipline != .none or n.is_ground))
        return r.fail(n.main_tok, "disciplined and ground nets are not implemented by digital execution", .{});
    const width = if (n.range) |range| try r.declaredWidth(range, n.main_tok) else 1;
    // A.2.4 `net_decl_assignment` names no dimension.
    if (n.dims.len != 0 and n.init != .none) return r.fail(n.main_tok, "a net array declaration takes no assignment", .{});
    // §4.9.1 a net array is one net per element, on consecutive slots,
    // the layout a variable array's elements have.
    const base: u32 = @intCast(e.values.items.len);
    const nets = e.nets.items.len;
    const count = try declareArray(r, base, n.dims, n.main_tok);
    defer assert(e.nets.items.len >= nets); // `defer`: an error leaves the nets minted so far.
    for (0..count) |k| {
        const at = try mintNet(r, e, n.kind, width, n.is_signed, if (k == 0) n.name else .none, n.main_tok);
        if (n.range) |range| try putRange(r, e.nets.items[at].slot, range, n.main_tok);
        var net = &e.nets.items[at];
        // §6.1.3: beside a net_decl_assignment the `delay3` "is part of the
        // continuous assignment and is not a net delay", so it times that one
        // driver (below) and never the net's other drivers.
        const net_delay: Ast.Delay3 = if (n.init == .none) n.delay else .{};
        var cold: NetCold = .{ .delay = try r.declaredDelay3(net_delay, n.main_tok) };
        // A.2.1.3 gives `trireg` its own alternatives, and in them the third
        // `delay3` value is the CHARGE DECAY TIME. It is not a turn-off delay:
        // a trireg in the capacitive state does not turn off, it holds, so the
        // net's own turn-off falls back to §7.14's "smallest of the delays".
        if (n.kind == .trireg and net_delay.off != .none) {
            cold.decay = cold.delay.off;
            cold.delay.off = @min(cold.delay.rise, cold.delay.fall);
        }
        if (cold.delay.present or cold.decay != null) {
            net.cold = @intCast(e.net_cold.items.len);
            try e.net_cold.append(arena, cold);
        }
        net.charge = n.charge;
        // A.2.4 `net_decl_assignment` is a continuous assignment written on the
        // declaration: one more driver of that net, timed by the declaration's
        // `delay3` exactly as `assign #d` would be.
        if (n.init != .none)
            try e.wires.append(arena, .{ .net = at, .scope = scope, .source = .{ .expr = .{ .e = n.init } }, .s0 = n.strength0, .s1 = n.strength1, .delay = n.delay, .tok = n.main_tok });
    }
}

/// §12.5 element `k` of the instance array or loop generate `name` in
/// `scope`, reachable as `name[k]` (the spelling the parser gives an
/// instance select) when the source writes one.
pub fn selectable(r: *Run, scope: u32, name: Ast.StrId, k: i64, at: u32) Error!void {
    assert(scope < r.hier.scopes.items.len);
    if (name == .none) return;
    var buf: [256]u8 = undefined;
    assert(at < r.hier.scopes.items.len);
    const text = std.mem.print(&buf, "{s}[{d}]", .{ r.file.str(name), k }) catch return;
    if (r.file.strings.find(text)) |str| try r.hier.instances.put(r.arena, .{ .scope = scope, .str = str }, at);
}

/// Every module a generate construct instantiates, in either arm.
pub fn generatedModules(file: *const Ast.SourceFile, s: Ast.StmtId, out: *std.ArrayList(Ast.StrId), a: std.mem.Allocator) std.mem.Allocator.Error!void {
    if (s == .none) return;
    const before = out.items.len;
    defer assert(out.items.len >= before);
    switch (file.stmt(s)) {
        .if_stmt => |i| {
            try generatedModules(file, i.then_s, out, a);
            try generatedModules(file, i.else_s, out, a);
        },
        .case_stmt => |c| for (c.arms) |arm| try generatedModules(file, arm.body, out, a),
        .for_stmt => |f| try generatedModules(file, f.body, out, a),
        .block => |b| {
            for (b.instances) |inst| try out.append(a, inst.module);
            for (b.body) |inner| try generatedModules(file, inner, out, a);
        },
        else => {}, // else: no other statement holds an instance
    }
    assert(s != .none);
}

// ---- private ----

/// §12.4.1 the genvar a loop generate's `genvar_initialization` assigns, or
/// null when the loop's index is no genvar of `m`.
fn genvarOf(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, f: anytype) ?Ast.StrId {
    if (f.init == .none) return null;
    assert(f.init != .none);
    const init = switch (file.stmt(f.init)) {
        .assign => |a| a,
        else => return null, // else: A.4.2 genvar_initialization is an assignment
    };
    if (file.exprs.tag(init.target) != .ident) return null;
    const name = file.exprs.strOf(init.target);
    assert(name != .none);
    return if (std.mem.findScalar(Ast.StrId, m.genvars, name) != null) name else null;
}

/// IEEE 1364-2005 §12.4.2/§12.4.3 the scope a conditional generate's chosen
/// block `s` is elaborated in: a new one under `scope`, named as the block or
/// `genblk<n>`, unless `s` is no block or a directly nested construct (the
/// parser leaves those unnamed), which is not a scope.
fn armScope(r: *Run, scope: u32, s: Ast.StmtId, tok: u32) Error!u32 {
    assert(scope < r.hier.scopes.items.len);
    assert(tok < r.starts.len);
    if (s == .none) return scope;
    const name = switch (r.file.stmt(s)) {
        .block => |b| b.gen_name,
        else => return scope, // else: an empty arm declares nothing
    };
    if (name == .none) return scope;
    const at = try newScope(r, tok);
    try r.hier.scopes.append(r.arena, .{ .parent = scope, .name = name, .def = r.hier.scopes.items[scope].def, .lexical = true });
    // §12.4.3: "an unnamed generate block has no name that can be used in a
    // hierarchical name".
    if (r.file.stmt(s).block.name != .none) try r.hier.instances.put(r.arena, .{ .scope = scope, .str = name }, at);
    return at;
}

/// A genvar's storage in the current scope: a 32-bit signed constant
/// (§3.5 "an integer"), which `constant` folds like any parameter.
fn genvarSlot(r: *Run, e: *Elab, name: Ast.StrId, tok: u32) Error!u32 {
    assert(tok < r.starts.len);
    const at: u32 = @intCast(e.values.items.len);
    try r.bind(name, at, tok);
    try e.values.append(r.arena, try filled(r.arena, 32, true, .x));
    r.values = e.values.items;
    try r.decls.params.put(r.arena, at, {});
    assert(r.values.len > at);
    assert(e.values.items[at].width == 32); // §12.4.1: a genvar is an integer.
    return at;
}

fn setGenvar(r: *Run, e: *Elab, at: u32, value: Int.Literal) Error!void {
    assert(at < e.values.items.len);
    assert(r.decls.params.contains(at)); // `genvarSlot` made it.
    @memcpy(e.values.items[at].planes, (try evaluate.convert(r.arena, value, .{ .width = 32, .signed = true })).planes);
}
