//! §7.2.2 the discrete context: which statements and nets are digital.
//!
//! In: the module AST. Out: per-net and per-statement access/context marks on `Lower`,
//! and a diagnostic for every analog construct used in a discrete context.
//!
//! LRM clauses this file's code cites: §1.1, §3.2.2, §3.4, §3.6.2.2, §3.7,
//! §4.3, §4.4, §4.5.15, §4.7.1, §4.7.3, §5.2.1, §5.10, §5.10.3, §5.10.4,
//! §5.10.5, §6.3.4, §6.5.3, §6.6.1, §6.8, §7.2, §7.2.2, §7.3, §7.3.1, §7.3.2,
//! §7.3.3, §7.3.4, §7.3.5, §7.3.6.1, §7.3.6.2, §7.3.6.3, §7.3.6.4, §7.3.6.5,
//! §7.3.7, §7.6, §8.4.3.2, §8.5, §8.5.1, §8.5.3.2, §8.5.3.4, §8.5.3.5,
//! §8.5.3.6, §9.2, §9.4.3, §9.4.7, §9.5.1.2, §9.7.
//! IEEE 1364-2005 clauses cited: §6.1, §9.9.1, §10.2, §17.8.

const std = @import("std");
const Lower = @import("lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_param = @import("param.zig");
const discipline_rules = @import("elab").discipline_rules;
const lower_event = @import("event.zig");
const lower_sysfunc = @import("sysfunc.zig");
const lower_systask = @import("systask.zig");
const lower_contrib = @import("contrib.zig");
const lower_shape = @import("shape.zig");
const lower_expr = @import("expr.zig");
const Ast = @import("frontend").Ast;
const diag = @import("diag");
const Mir = @import("ir").Mir;
const naming = @import("ir").names;
const Oom = Lower.Oom;

// ---- §7.2.2 the discrete context -------------------------------------------

/// §7.2.2's two contexts, and the four rules the LRM states across them.
///
/// A `Ast.DiscreteBlock` is not lowered as code: an `initial` block of constant
/// assignments contributes its results (`collectInitialState`), and anything
/// that needs an event queue makes the module mixed, its digital half running
/// on the mixed-signal kernel (`declareDiscreteInputs`). This scan enforces the
/// rules the LRM states about a discrete context, all decidable from the AST:
///
///   §4.5.15  an analog operator "can not be used inside an initial or always
///            block"                                                  → E0422
///   §4.7.3   an analog function "shall only be called within the analog
///            context" (§7.3.7 states the mixed-signal half)           → E0430
///   §5.2.1   "digital values cannot be accessed from the analog initial
///            block"                                                   → E0431
///   §7.2.2   "It shall be an error to assign to a given variable in both
///            contexts"                                                → E0432
///
/// §7.2.2's first sentence is what makes the last two computable without a
/// digital engine: "The domain of a variable is that of the context from which
/// its value is assigned." So the assignment targets in the discrete blocks are
/// the digital-owned variables, with no driver state or scheduler needed.
const DiscreteCtx = struct {
    /// Module-level variables assigned by a statement in an `initial` or
    /// `always` block → the token of the block that assigns it. Insertion
    /// ordered: two errors in one module must be reported in source order.
    assigned: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// This module's §4.7.1 analog function names.
    funcs: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// Which block the scan is inside, for the E0422 wording (§4.5.15 names
    /// both spellings).
    where: []const u8 = "",
    /// The module's discrete half runs on the mixed-signal kernel
    /// (`Lower.mixed_signal`), so what that kernel cannot do yet is E0437.
    mixed: bool = false,
};

/// §8.5: does this module's discrete half need the event queue? An `always`
/// block and a continuous assignment are processes: each re-runs whenever
/// what it reads changes. Every `initial` block is a process too (IEEE
/// 1364-2005 §9.9.1, via VAMS §1.1: it executes once, with or without a
/// timing control), and one runs on the kernel unless it is
/// `collectInitialState`'s constant shape (`constantShape`), the one body
/// whose whole effect is a value fixed before the analysis, which keeps its
/// fast path. So an untimed `initial $display(...)` runs exactly as
/// `initial #0 $display(...)` does. A block written in a generate block
/// (`DiscreteBlock.generated`) is the kernel's as well: whether it exists at
/// all is the kernel's scheme to decide (§6.6).
///
/// Takes the file rather than the `Lower`: it is a question about the AST.
fn isMixed(file: *const Ast.SourceFile, module: *const Ast.ModuleDecl) bool {
    if (module.assigns.len != 0) return true;
    // §3.7 a wreal is a digital net, and only the digital kernel holds its
    // value — 0.0 undriven, or its single driver's.
    for (module.nets) |n| if (n.kind == .wreal) return true;
    // §8.5.3.5 a switch on a discrete net is processed in the discrete cycle.
    for (module.switches) |sw| for (sw.terms) |t| if (discreteNet(file, module, t) != null) return true;
    for (module.discrete) |blk| if (blk.is_always or blk.generated or suspends(file, blk.body) or writesFourState(file, blk.body) or usesFiles(file, blk.body) or !constantShape(file, module, blk.body)) return true;
    // §7.3.2's `a2d` reads `input dnet; wire dnet;` with nothing in the
    // module driving it: a discrete net's value, driven or not (§3.7: an
    // undriven wire is z), is the kernel's.
    // Without a list the walk allocates nothing.
    for (module.analog) |blk| if (analogDiscreteNets(file, module, blk.body, null) catch unreachable) return true;
    return false;
}

/// A.6.2 / §7.2.2: is an untimed `initial` body `collectInitialState`'s
/// constant shape? Blocking writes, to scalar module variables, of what
/// `lower_constfold.constEval` folds (`constantExpr`), in blocks with no local
/// declarations. Only that body means "this variable holds this constant for
/// the whole analysis" with no kernel; §7.3.3 lets any other discrete
/// statement read the continuous side, so it is a process like any other.
/// A target that is not a module variable keeps the fast path, where it is
/// E0313 or E0482 (`lowerModule`, `checkDiscreteContext`).
fn constantShape(file: *const Ast.SourceFile, module: *const Ast.ModuleDecl, id: Ast.StmtId) bool {
    if (id == .none) return true;
    const ex = &file.exprs;
    switch (file.stmt(id)) {
        .empty => return true,
        .block => |b| {
            if (b.vars.len != 0 or b.params.len != 0) return false;
            for (b.body) |s| if (!constantShape(file, module, s)) return false;
            return true;
        },
        .assign => |a| {
            if (a.target == .none or ex.tag(a.target) != .ident) return false;
            const name = ex.strOf(a.target);
            for (module.vars) |v| if (v.name == name and v.dims.len != 0) return false;
            return constantExpr(file, module, a.value);
        },
        // An analog-only task is §9.2's E0821 in either context (`scanContext`).
        .sys_task => |s| return lower_sysfunc.isAnalogOnlySysFunc(file.str(s.name)),
        else => return false, // else: every other statement is a process's to run, a new one included
    }
}

/// Whether `e` is built only from what `lower_constfold.constEval` folds:
/// literals, module parameters (§3.4), operators, §4.3 math, and the
/// IEEE 1364-2005 §17.8 conversions `$rtoi`/`$itor` and `$clog2`.
fn constantExpr(file: *const Ast.SourceFile, module: *const Ast.ModuleDecl, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &file.exprs;
    switch (ex.tag(e)) {
        .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf => return true,
        .ident => {
            for (module.params) |p| if (p.name == ex.strOf(e)) return true;
            return false;
        },
        .sys_call => {
            const callee = Mir.Callee.fromName(file.str(ex.strOf(e)));
            if (callee != .@"$rtoi" and callee != .@"$itor" and callee != .@"$clog2") return false;
        },
        .unary, .binary, .ternary, .builtin_call => {},
        else => return false, // else: a variable, net, call or access is a value only a run computes
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (!constantExpr(file, module, c)) return false;
    return true;
}

/// Whether the analog statement `id` reads a discrete net by name (§7.3: a
/// net of a discrete discipline, or one with none). With `out`, every such
/// read is appended to it and the walk does not stop at the first. An access
/// function's operands are nodes, not values, and are not reads.
fn analogDiscreteNets(file: *const Ast.SourceFile, module: *const Ast.ModuleDecl, id: Ast.StmtId, out: ?struct { a: std.mem.Allocator, list: *std.ArrayList(Ast.ExprId) }) Oom!bool {
    // Only a net or port of no continuous discipline can be such a read
    // (`discreteName`), and most modules have none: then the walk (13% of a
    // large compact model's lint) is skipped. One pass, not `discreteName`
    // per net, which scans the nets again: quadratic in a flattened design.
    const any = for (module.nets) |n| {
        if (!discipline_rules.isContinuous(file, n.discipline)) break true;
    } else for (module.ports) |p| {
        if (p.kind != .wreal and !discipline_rules.isContinuous(file, p.discipline)) break true;
    } else false;
    if (!any) return false;
    const Walk = struct {
        file: *const Ast.SourceFile,
        module: *const Ast.ModuleDecl,
        out: @TypeOf(out),
        hit: *bool,
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
            if (e == .none or (w.hit.* and w.out == null)) return;
            const ex = &w.file.exprs;
            switch (ex.tag(e)) {
                .branch_access, .port_access => return,
                else => {}, // else: every other expression is walked for reads
            }
            if (ex.tag(e) == .ident and discreteName(w.file, w.module, ex.strOf(e))) {
                w.hit.* = true;
                if (w.out) |o| try o.list.append(o.a, e);
            }
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            if (s != .none) try w.file.stmtEdges(s, w);
        }
    };
    var hit = false;
    try (Walk{ .file = file, .module = module, .out = out, .hit = &hit }).stmt(id);
    return hit;
}

/// VAMS §9.5.1.2 a descriptor either context opens is usable in the other,
/// so a discrete block's file task or function runs on the kernel, against
/// the simulation's one descriptor table — it has no constant reading.
fn usesFiles(file: *const Ast.SourceFile, id: Ast.StmtId) bool {
    const Walk = struct {
        file: *const Ast.SourceFile,
        hit: *bool,
        fn isFile(name: []const u8) bool {
            return Mir.callee.isFileCall(.fromName(name)) or std.mem.eql(u8, name, "$ungetc") or
                (std.mem.startsWith(u8, name, "$f") and lower_sysfunc.isDigitalOnlySysFunc(name));
        }
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) error{}!void {
            if (e == .none) return;
            const ex = &w.file.exprs;
            if (ex.tag(e) == .sys_call and isFile(w.file.str(ex.strOf(e)))) w.hit.* = true;
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) error{}!void {
            if (s == .none) return;
            if (w.file.stmt(s) == .sys_task and isFile(w.file.str(w.file.stmt(s).sys_task.name))) w.hit.* = true;
            try w.file.stmtEdges(s, w);
        }
    };
    var hit = false;
    (Walk{ .file = file, .hit = &hit }).stmt(id) catch unreachable;
    return hit;
}

/// C.3/§7.3.2: an x or z a discrete block writes is a value only the
/// four-state kernel can hold — `collectInitialState` folds into analog
/// variables, where it has nowhere to live — so the block runs on the kernel.
fn writesFourState(file: *const Ast.SourceFile, id: Ast.StmtId) bool {
    const Walk = struct {
        file: *const Ast.SourceFile,
        hit: *bool,
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) error{}!void {
            if (e == .none) return;
            const ex = &w.file.exprs;
            if (ex.tag(e) == .logic_literal and ex.logicValue(e).hasUnknown()) w.hit.* = true;
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) error{}!void {
            if (s != .none) try w.file.stmtEdges(s, w);
        }
    };
    var hit = false;
    (Walk{ .file = file, .hit = &hit }).stmt(id) catch unreachable;
    return hit;
}

fn suspends(file: *const Ast.SourceFile, id: Ast.StmtId) bool {
    if (id == .none) return false;
    switch (file.stmt(id)) {
        .event_control => return true,
        // §8.5.3.2: a procedural continuous assignment "corresponds to a
        // process that is sensitive to the source elements in the expression".
        .assign => |a| if (a.nonblocking or a.timing != .none or a.timing_implicit or a.continuous != .none) return true,
        // A.6.4 `task_enable` (a `sys_task` row with no `$`): IEEE 1364 §10.2's
        // task body is the kernel's to run, delays and all.
        .sys_task => |s| if (file.str(s.name)[0] != '$') return true,
        else => {}, // else: a statement suspends only through its children
    }
    const Walk = struct {
        file: *const Ast.SourceFile,
        hit: *bool,
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) error{}!void {}
        pub fn stmt(w: @This(), s: Ast.StmtId) error{}!void {
            if (suspends(w.file, s)) w.hit.* = true;
        }
    };
    var hit = false;
    file.stmtEdges(id, Walk{ .file = file, .hit = &hit }) catch unreachable;
    return hit;
}

/// §6.5.3 "There can be a maximum of one driver of a real-valued net." A
/// continuous assignment is a driver, and so is a net_decl_assignment
/// (`wreal w = a;`). The digital runner makes the same check for a `.v`
/// design (`lib/sim/digital`); this is the analog compile's copy, so a mixed
/// `.va` is refused before a device is built rather than when its digital
/// half first runs.
fn checkWrealDrivers(self: *Lower, module: *const Ast.ModuleDecl, name: Ast.StrId, declared: bool) Oom!void {
    const ex = &self.file.exprs;
    var count: u32 = @intFromBool(declared);
    for (module.assigns) |a| {
        if (a.target == .none or ex.tag(a.target) != .ident or ex.strOf(a.target) != name) continue;
        count += 1;
        if (count == 2) try self.err(a.main_tok, .E0918, "`{s}` is already driven", .{self.file.str(name)});
    }
}

/// Declares the analog block's view of a mixed module's digital half
/// (§7.3.1, §7.3.6.5, §8.5). Every variable a discrete process writes and every
/// net a continuous assignment drives is digital-owned (§7.2.2), and the analog
/// block reads its value at "the greatest digital time tick which is less than
/// or equal to the analog time" (§7.3.6.5). So each one the analog block reads
/// becomes a host-written input: a hidden §3.4 parameter of the same name (a
/// `Model` field the mixed-signal host writes before every solve), typed per
/// Table 7-1. No-op for a module that is not mixed.
///
/// Must run before the ports and nets are interned, so a digital-owned net
/// never becomes an analog node.
pub fn declareDiscreteInputs(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    // ponytail: a Model field is per model, and a discrete input is per
    // instance. Exact for the testbench (one instance), wrong for a host that
    // instantiates one mixed device twice; the right home is an `Instance`
    // field, which is codegen's to emit.
    if (!isMixed(self.file, module)) return;
    self.out.mixed_signal = true;
    const ex = &self.file.exprs;
    for (module.nets) |n| if (n.kind == .wreal) try checkWrealDrivers(self, module, n.name, n.init != .none);
    for (module.ports) |p| if (p.kind == .wreal) try checkWrealDrivers(self, module, p.name, false);
    var owned: std.ArrayList(Ast.ExprId) = .empty;
    for (module.assigns) |a| {
        const t = self.file.lvalueBase(a.target);
        const n = if (t == .none) null else netOf(module, ex.strOf(t));
        if (n == null) {
            // IEEE 1364-2005 §6.1 (via VAMS §1.1): A.6.1's `net_assignment`
            // drives a `net_lvalue` — a variable has no driver to add.
            try self.err(a.main_tok, .E0438, "", .{});
            continue;
        }
        // The declaration kind decided E0438; the domain decides this one.
        // §7.2: "only digital blocks and primitives can drive a discrete net",
        // and §7.3: "Write operations of nets ... are only allowed from the
        // context of their domain" — and a continuous assignment is the
        // discrete context. A `ddiscrete` net (§3.6.2.2 `domain discrete`) is
        // a net exactly as `wire` is, and legal here.
        if (discipline_rules.isContinuous(self.file, n.?.discipline)) {
            try self.err(a.main_tok, .E0435, "`{s}` is driven by a continuous assignment", .{self.file.str(ex.strOf(t))});
            continue;
        }
        try owned.append(self.arena, t);
    }
    for (module.discrete) |blk| try collectWrites(self, blk.body, &owned);
    // A task (A.2.7) is enabled only from the discrete context, so what its
    // body writes is digital-owned too.
    // ponytail: every task's body, enabled or not, and a formal or local that
    // shadows a module variable counts as that variable; the output actuals
    // of an enable are not collected. Follow the enables when a source needs it.
    for (module.tasks) |t| try collectWrites(self, t.body, &owned);
    // §7.2 "only digital blocks and primitives can drive a discrete net": a
    // discrete net on a switch terminal takes its value from the switch-level
    // resolution of its whole network (§8.5.3.5), which the kernel computes.
    for (module.switches) |sw| for (sw.terms) |t| if (discreteNet(self.file, module, t)) |id| try owned.append(self.arena, id);
    // §7.3.1 "Read operations of nets ... are allowed from both contexts": a
    // discrete net the analog block reads holds the kernel's value, z when
    // nothing drives it.
    for (module.analog) |blk| _ = try analogDiscreteNets(self.file, module, blk.body, .{ .a = self.arena, .list = &owned });
    var owned_names: std.ArrayList(struct { name: Ast.StrId, tok: u32 }) = .empty;
    for (owned.items) |t| try owned_names.append(self.arena, .{ .name = ex.strOf(t), .tok = ex.mainTok(t) });
    // §3.7 "If no driver is connected to a wreal net, its value shall be zero
    // (0.0)": a wreal is digital-owned whether or not anything drives it.
    for (module.nets) |n| if (n.kind == .wreal) try owned_names.append(self.arena, .{ .name = n.name, .tok = n.main_tok });
    // What a digital event term in an analog event control may watch (§7.3.4):
    // a digital-owned value, or a named event the digital context triggers
    // (§5.10.4 / §5.10.5).
    var digital: std.StringHashMapUnmanaged(void) = .empty;
    for (owned_names.items) |t| try digital.put(self.arena, self.file.str(t.name), {});
    var trig: EventRefs = .{ .l = self, .module = module, .triggers_only = true };
    for (module.discrete) |blk| try trig.stmt(blk.body);
    for (trig.names.keys()) |name| try digital.put(self.arena, name, {});
    // Only what the analog block READS crosses: an owned value it never names
    // is the digital engine's alone, and must not make a solve fail on an x
    // (§7.3.2) that nothing analog ever sees.
    var reads: Reads = .{ .l = self, .digital = &digital };
    for (module.analog) |blk| try reads.stmt(blk.body);
    // §7.3.6.4 / §7.3.1, A2D: "Read operations of nets and variables in both
    // domains are allowed from both contexts", so a module variable a digital
    // expression reads and no digital context assigns is the analog block's.
    const DReads = struct {
        l: *Lower,
        module: *const Ast.ModuleDecl,
        digital: *const std.StringHashMapUnmanaged(void),
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
            if (e == .none) return;
            const fx = &w.l.file.exprs;
            if (fx.tag(e) == .ident) for (w.module.params) |p| {
                if (p.name != fx.strOf(e)) continue;
                const name = w.l.file.str(p.name);
                if (!w.l.out.discrete_params.contains(name)) {
                    try w.l.out.discrete_params.put(w.l.arena, name, fx.mainTok(e));
                    // §6.3.4 a later parameter can depend on this one, even
                    // when its name never appears directly in a process.
                    try w.expr(p.default, .read);
                }
                break;
            };
            if (fx.tag(e) == .ident) for (w.module.vars) |v| {
                const name = w.l.file.str(v.name);
                if (v.name != fx.strOf(e) or w.digital.contains(name)) continue;
                if (!w.l.out.discrete_reads.contains(name)) try w.l.out.discrete_reads.put(w.l.arena, name, fx.mainTok(e));
                break;
            };
            var buf: [3]Ast.ExprId = undefined;
            for (fx.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            if (s != .none) try w.l.file.stmtEdges(s, w);
        }
    };
    const dreads: DReads = .{ .l = self, .module = module, .digital = &digital };
    for (module.assigns) |a| try dreads.expr(a.value, .read);
    for (module.discrete) |blk| try dreads.stmt(blk.body);
    // §8.5 each explicit D2A term is a host-set flag.
    for (reads.sites.items, 0..) |site, k| {
        const param = try self.arena.print("__d2a{d}", .{k});
        try self.out.discrete_events.put(self.arena, site.term, .{ .name = site.name, .edge = site.edge, .param = param });
        try lower_param.addParam(self, param, .integer, try self.mir.addIntConst(self.arena, 0), .{ .int = 0 }, &.{}, false, ex.mainTok(site.term));
    }
    for (owned_names.items) |t| {
        const name = self.file.str(t.name);
        if (!reads.guarded.contains(name) and !reads.names.contains(name)) continue;
        const ty: Ast.Type = for (module.vars) |v| {
            if (v.name == t.name) break v.ty;
        } else if (netOf(module, t.name)) |n| (if (n.kind == .wreal) .real else .integer) else for (module.ports) |p| {
            if (p.name == t.name) break if (p.kind == .wreal) .real else .integer;
        } else continue; // an undeclared name is §6.8's, reported elsewhere
        // VAMS Table 7-1: a bit grouping, a net and an `integer` read as an
        // integer, a `real` "with no conversion".
        const real = switch (ty) {
            .integer => false,
            .real => true,
            else => { // else: Table 7-1 has no row for any other type
                try self.err(t.tok, .E0437, "`{s}` is a digital `{t}`, and Table 7-1 converts only integer, bit and real values", .{ name, ty });
                continue;
            },
        };
        const zero = if (real) try self.mir.addFloatConst(self.arena, 0) else try self.mir.addIntConst(self.arena, 0);
        const folded: Lower.Const = if (real) .{ .real = 0 } else .{ .int = 0 };
        if (reads.guarded.contains(name) and !self.out.discrete_snaps.contains(name)) {
            // §8.5.3.6: the guarded read's region-1b snapshot.
            try self.out.discrete_snaps.put(self.arena, name, t.tok);
            const snap = try naming.snapField(self.arena, name);
            try lower_param.addParam(self, snap, ty, zero, folded, &.{}, false, t.tok);
        }
        if (self.out.discrete_inputs.contains(name) or !reads.names.contains(name)) continue;
        try self.out.discrete_inputs.put(self.arena, name, t.tok);
        try lower_param.addParam(self, name, ty, zero, folded, &.{}, false, t.tok);
        // §7.3.1 a `reg` input: its packed range, for a select's bits, and
        // past 32 bits one more `Model` field per 32-bit word, so a select
        // anywhere in it reads exact bits (`lower_expr.lowerRegSelect`).
        if (!real) for (module.vars) |v| {
            if (v.name != t.name or v.storage != .reg or v.dims.len != 0) continue;
            const range = v.packed_range orelse break;
            const width = lower_shape.packedShapeWidth(self, range) orelse break;
            const m = lower_constfold.constEval(self, range.msb) orelse break;
            const l = lower_constfold.constEval(self, range.lsb) orelse break;
            const right = l.asIntExact() orelse 0;
            try self.reg_ranges.put(self.arena, name, .{ .right = right, .asc = (m.asIntExact() orelse 0) < right, .width = width, .signed = v.is_signed });
            if (width <= 32) break;
            const n_words: u32 = (width + 31) / 32;
            try self.out.discrete_words.put(self.arena, name, n_words);
            for (1..n_words) |k| try lower_param.addParam(self, try naming.wordField(self.arena, name, k), .integer, zero, folded, &.{}, false, t.tok);
            break;
        };
        if (!real and reads.fourStateOnly(name)) {
            // §7.3.2 the unknown plane, for `===`/`!==`/`case` (`lower_expr.fourState`).
            // A name also read any other way keeps the x/z error at every
            // solve (the runner's `mixedInput`), and compares two-state.
            try self.out.discrete_xz.put(self.arena, name, {});
            const xz = try naming.xzField(self.arena, name);
            try lower_param.addParam(self, xz, .integer, try self.mir.addIntConst(self.arena, 0), .{ .int = 0 }, &.{}, false, t.tok);
        }
    }
}

/// Marks, in `marks` (indexed by `Ast.ExprId`), every expression §7.2.2's
/// discrete context owns in a mixed module (`isMixed`): the bodies of its
/// `initial`/`always` blocks and continuous assignments, plus every module's
/// task bodies. Those run on the four-state kernel, so an x or z literal there
/// is ordinary IEEE 1364. A non-mixed module's `initial` is not marked:
/// `collectInitialState` folds it into analog initial values, where an x has
/// nowhere to live. Asserts that `marks` has one slot per expression id.
pub fn markDiscreteExprs(file: *const Ast.SourceFile, marks: []bool) void {
    std.debug.assert(marks.len == file.exprs.len());
    const Mark = struct {
        file: *const Ast.SourceFile,
        marks: []bool,
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) error{}!void {
            if (e == .none) return;
            w.marks[@backingInt(e)] = true;
            var buf: [3]Ast.ExprId = undefined;
            for (w.file.exprs.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) error{}!void {
            if (s != .none) try w.file.stmtEdges(s, w);
        }
    };
    // §7.3.2 in an analog block, an x/z literal compared by `===`/`!==` or as a
    // `case`/`casex`/`casez` label is the four-state comparison the clause
    // provides (`lower_expr.caseEquality`); anywhere else it stays E0130. Every
    // module, not only a mixed one: the clause's own `a2d` has no discrete block
    // and reads its input net with `dnet === 1'bx`.
    //
    // §6.6.1 a genvar loop's initialization and iteration values are folded at
    // elaboration, never executed, so an x/z literal there is not E0130's: it
    // is §6.6.1's own error ("any bit of the genvar is set to x or z", E0486,
    // `control.tryUnrollFor`).
    const Cmp = struct {
        file: *const Ast.SourceFile,
        marks: []bool,
        genvars: []const Ast.StrId,
        fn lit(w: @This(), e: Ast.ExprId) void {
            if (e != .none and w.file.exprs.tag(e) == .logic_literal) w.marks[@backingInt(e)] = true;
        }
        fn lits(w: @This(), e: Ast.ExprId) void {
            if (e == .none) return;
            w.lit(e);
            var buf: [3]Ast.ExprId = undefined;
            for (w.file.exprs.children(e, &buf)) |c| w.lits(c);
        }
        fn genvarAssign(w: @This(), s: Ast.StmtId) ?Ast.ExprId {
            if (s == .none or w.file.stmt(s) != .assign) return null;
            const a = w.file.stmt(s).assign;
            if (w.file.exprs.tag(a.target) != .ident) return null;
            for (w.genvars) |g| if (g == w.file.exprs.strOf(a.target)) return a.value;
            return null;
        }
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) error{}!void {
            if (e == .none) return;
            const ex = &w.file.exprs;
            if (ex.tag(e) == .binary and (ex.binOp(e) == .case_eq or ex.binOp(e) == .case_neq)) {
                w.lit(ex.lhs(e));
                w.lit(ex.rhs(e));
            }
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) error{}!void {
            if (s == .none) return;
            switch (w.file.stmt(s)) {
                .case_stmt => |c| for (c.arms) |arm| for (arm.labels) |l| w.lit(l),
                .for_stmt => |f| if (w.genvarAssign(f.init)) |init| {
                    w.lits(init);
                    // The iteration of a genvar loop: whichever name it
                    // assigns, it is folded (or refused as E0419) like init.
                    if (f.step != .none and w.file.stmt(f.step) == .assign) w.lits(w.file.stmt(f.step).assign.value);
                },
                else => {}, // else: only a case statement has labels, a genvar loop a folded scheme
            }
            try w.file.stmtEdges(s, w);
        }
    };
    const w: Mark = .{ .file = file, .marks = marks };
    for (file.modules) |*m| {
        // A task (A.2.7) runs only on the kernel, in any module: the analog
        // backend never executes its body.
        for (m.tasks) |t| w.stmt(t.body) catch unreachable;
        for (m.analog) |blk| (Cmp{ .file = file, .marks = marks, .genvars = m.genvars }).stmt(blk.body) catch unreachable;
        if (!isMixed(file, m)) continue;
        for (m.discrete) |blk| w.stmt(blk.body) catch unreachable;
        for (m.assigns) |a| for ([_]Ast.ExprId{ a.target, a.value, a.delay.rise, a.delay.fall, a.delay.off }) |e|
            w.expr(e, .read) catch unreachable;
    }
}

/// Every identifier an analog statement tree reads, split by §8.4.3.2: a read
/// inside a statement guarded by an explicit D2A event (`guarded`) does not
/// make the block implicitly sensitive, and §8.5.3.6 gives it the region-1b
/// value; every other read (`names`) is a live, implicitly sensitive input.
const Reads = struct {
    l: *Lower,
    /// Digital-owned values and digitally triggered named events.
    digital: *const std.StringHashMapUnmanaged(void),
    /// Unguarded reads, counted.
    names: std.StringHashMapUnmanaged(u32) = .empty,
    guarded: std.StringHashMapUnmanaged(void) = .empty,
    /// §7.3.2 reads as an operand of `===`/`!==` or as a `case` subject,
    /// counted: a name all of whose reads are these is read four-state.
    xz: std.StringHashMapUnmanaged(u32) = .empty,
    sites: std.ArrayList(Site) = .empty,
    in_d2a: bool = false,
    const Site = struct { term: Ast.ExprId, name: []const u8, edge: Edge };

    pub fn stmt(w: *Reads, s: Ast.StmtId) Oom!void {
        if (s == .none) return;
        switch (w.l.file.stmt(s)) {
            .event_control => |c| if (c.kind == .event and c.event != .none) {
                const before = w.sites.items.len;
                try w.eventTerms(c.event);
                const prev = w.in_d2a;
                defer w.in_d2a = prev;
                if (w.sites.items.len != before) w.in_d2a = true;
                return w.stmt(c.body);
            },
            .case_stmt => |c| try w.caseOperand(c.scrutinee),
            else => {}, // else: every other statement is read edge by edge
        }
        try w.l.file.stmtEdges(s, w);
    }

    /// §7.3.4 Syntax 7-2: an `or` list's digital terms are explicit D2A sites;
    /// the rest (cross, timer, an analog named event) are read as expressions.
    fn eventTerms(w: *Reads, e: Ast.ExprId) Oom!void {
        const ex = &w.l.file.exprs;
        if (ex.tag(e) == .event_or) {
            try w.eventTerms(ex.lhs(e));
            return w.eventTerms(ex.rhs(e));
        }
        if (d2aTerm(w.l.file, e, w.digital)) |t|
            return w.sites.append(w.l.arena, .{ .term = e, .name = t.name, .edge = t.edge });
        // A bare name that is not digital is an analog named event, not a read.
        if (ex.tag(e) != .ident) try w.expr(e, .read);
    }

    fn caseOperand(w: *Reads, e: Ast.ExprId) Oom!void {
        const ex = &w.l.file.exprs;
        if (w.in_d2a or e == .none or ex.tag(e) != .ident) return;
        const n = try w.xz.getOrPutValue(w.l.arena, w.l.file.str(ex.strOf(e)), 0);
        n.value_ptr.* += 1;
    }

    /// Every unguarded read of `name` is §7.3.2's four-state comparison, so an
    /// x or z it holds is a value and not the clause's error.
    fn fourStateOnly(w: *const Reads, name: []const u8) bool {
        const n = w.xz.get(name) orelse return false;
        return n == w.names.get(name).?;
    }

    pub fn expr(w: *Reads, e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
        if (e == .none) return;
        const ex = &w.l.file.exprs;
        if (ex.tag(e) == .ident) {
            const name = w.l.file.str(ex.strOf(e));
            if (w.in_d2a) try w.guarded.put(w.l.arena, name, {}) else (try w.names.getOrPutValue(w.l.arena, name, 0)).value_ptr.* += 1;
        }
        if (ex.tag(e) == .binary and (ex.binOp(e) == .case_eq or ex.binOp(e) == .case_neq)) {
            try w.caseOperand(ex.lhs(e));
            try w.caseOperand(ex.rhs(e));
        }
        var buf: [3]Ast.ExprId = undefined;
        for (ex.children(e, &buf)) |c| {
            // §4.4: a bare name in `V(d)` is the net the access function is
            // applied to, not a Table 7-1 read of its digital value. Making it
            // a discrete input would drop the node and turn a ddiscrete net's
            // E0501 ("binds no potential nature") into a false E0337 ("has no
            // discipline"). An index expression inside the argument is a read.
            if (c != .none and ex.tag(e) == .branch_access and ex.tag(c) == .ident) continue;
            try w.expr(c, .read);
        }
    }
};

const Edge = @FieldType(Lower.Lowered.DiscreteEvent, "edge");

/// §7.3.4 a digital event term over one name: `posedge d`, `negedge d`, or a
/// bare `d` (a change of a digital value, or a digitally triggered named
/// event). Null for anything else, which stays an analog event.
fn d2aTerm(file: *const Ast.SourceFile, e: Ast.ExprId, digital: *const std.StringHashMapUnmanaged(void)) ?struct { name: []const u8, edge: Edge } {
    const ex = &file.exprs;
    const tag = ex.tag(e);
    const operand = switch (tag) {
        .event_posedge, .event_negedge => ex.lhs(e),
        else => e, // else: a bare term; only a name qualifies, checked below
    };
    if (operand == .none or ex.tag(operand) != .ident) return null;
    const name = file.str(ex.strOf(operand));
    if (!digital.contains(name)) return null;
    return .{
        .name = name,
        .edge = switch (tag) {
            .event_posedge => .posedge,
            .event_negedge => .negedge,
            else => .any, // else: the bare-name term
        },
    };
}

/// `e` when it names a net of `module` with no continuous discipline, else null.
fn discreteNet(file: *const Ast.SourceFile, module: *const Ast.ModuleDecl, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none or file.exprs.tag(e) != .ident) return null;
    const n = netOf(module, file.exprs.strOf(e)) orelse return null;
    return if (discipline_rules.isContinuous(file, n.discipline)) null else e;
}

/// Whether a read of `name` reads a discrete net: a net of `module` with no
/// continuous discipline, or else a port that is one and no variable
/// re-declares (`input dnet; wire dnet;` declares the port, not a `NetDecl`).
fn discreteName(file: *const Ast.SourceFile, module: *const Ast.ModuleDecl, name: Ast.StrId) bool {
    if (netOf(module, name)) |n| if (!discipline_rules.isContinuous(file, n.discipline)) return true;
    for (module.vars) |v| if (v.name == name) return false;
    for (module.ports) |p| if (p.name == name)
        return p.kind != .wreal and !discipline_rules.isContinuous(file, p.discipline);
    return false;
}

/// Is `name` a net of `module`: a declared net, or a port no variable
/// declaration re-declares (an undeclared port is an implicit wire)? A name
/// declared as both a discipline net and a `reg` (`ddiscrete cm; reg cm;`,
/// §7.6's connect modules) is the variable. Undeclared names are §6.8's.
fn isNetName(module: *const Ast.ModuleDecl, name: Ast.StrId) bool {
    for (module.vars) |v| if (v.name == name) return false;
    if (netOf(module, name) != null) return true;
    for (module.ports) |p| if (p.name == name) return true;
    return false;
}

/// The first branch or port probe in event expression `e` that no analog
/// event function (`cross`, `above`, `timer`, `absdelta`) encloses, or null.
fn probeOutsideEventFn(file: *const Ast.SourceFile, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none) return null;
    const ex = &file.exprs;
    switch (ex.tag(e)) {
        .event_function => return null,
        .branch_access, .port_access => return e,
        else => {}, // else: every other node is searched through its children
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (probeOutsideEventFn(file, c)) |p| return p;
    return null;
}

/// The first analog variable in `e`, outside an analog event function's
/// arguments, that no analog event statement assigns (a `Lowered.discrete_reads`
/// name not held as `.event`), or null.
fn freeVarOutsideEventFn(self: *const Lower, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .event_function => return null,
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.out.discrete_reads.contains(name) and self.var_state.held_names.get(name) != .event) return e;
            return null;
        },
        else => {}, // else: every other node is searched through its children
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (freeVarOutsideEventFn(self, c)) |v| return v;
    return null;
}

/// Whether `name` is a net of `module` (`isNetName` by spelling, for the tables
/// keyed by string).
pub fn isNetSpelling(file: *const Ast.SourceFile, module: *const Ast.ModuleDecl, name: []const u8) bool {
    for (module.vars) |v| if (std.mem.eql(u8, file.str(v.name), name)) return false;
    for (module.nets) |n| if (std.mem.eql(u8, file.str(n.name), name)) return true;
    for (module.ports) |p| if (std.mem.eql(u8, file.str(p.name), name)) return true;
    return false;
}

/// Reports E0483 for a variable in a switch terminal slot. A.3.3
/// `inout_terminal ::= net_lvalue` (both terminals of a pass switch) and
/// `output_terminal ::= net_lvalue` (the first terminal of a MOS/CMOS switch):
/// §8.5.3.5 resolves a switch as a driver of the nets it joins.
pub fn checkSwitchTerminals(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    const ex = &self.file.exprs;
    for (module.switches) |sw| {
        const nets: usize = switch (sw.kind) {
            .tran, .rtran, .tranif0, .tranif1, .rtranif0, .rtranif1 => 2,
            .cmos, .rcmos, .nmos, .pmos, .rnmos, .rpmos => 1,
        };
        for (sw.terms[0..@min(nets, sw.terms.len)]) |t| {
            const base = self.file.lvalueBase(t);
            if (base == .none or ex.tag(base) != .ident) continue;
            for (module.vars) |v| if (v.name == ex.strOf(base)) {
                try self.err(ex.mainTok(base), .E0483, "`{s}` is a variable, on a terminal of `{t}`", .{ self.file.str(v.name), sw.kind });
                break;
            };
        }
    }
}

/// The net `name` declares in `module`, of any discipline, or null (a
/// variable, or undeclared). Its domain is the caller's question.
fn netOf(module: *const Ast.ModuleDecl, name: Ast.StrId) ?*const Ast.NetDecl {
    for (module.nets) |*n| if (n.name == name) return n;
    return null;
}

/// Appends to `out` the base identifier of every lvalue the statement tree
/// `id` writes (`Ast.SourceFile.stmtWrites`: assignment targets, output
/// actuals, inout seeds), child statements included, in walk order with
/// repeats. `out` grows in `self.arena`.
pub fn collectWrites(self: *Lower, id: Ast.StmtId, out: *std.ArrayList(Ast.ExprId)) Oom!void {
    if (id == .none) return;
    const funcs: []const Ast.FuncDecl = if (self.module) |m| m.functions else &.{};
    var writes: std.ArrayList(Ast.ExprId) = .empty;
    try self.file.stmtWrites(funcs, id, self.arena, &writes);
    for (writes.items) |w| {
        const t = self.file.lvalueBase(w);
        if (t != .none) try out.append(self.arena, t);
    }
    const Walk = struct {
        l: *Lower,
        out: *std.ArrayList(Ast.ExprId),
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {}
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            try collectWrites(w.l, s, w.out);
        }
    };
    try self.file.stmtEdges(id, Walk{ .l = self, .out = out });
}

/// Every §5.10.4 named event of `module` a statement tree triggers or waits on,
/// name → first token.
const EventRefs = struct {
    l: *Lower,
    module: *const Ast.ModuleDecl,
    names: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// Only `-> e`, not `@(e)`.
    triggers_only: bool = false,
    /// Skip a trigger the mixed-signal kernel carries to the digital context:
    /// the statement of a `cross`/`above`/`timer` event control, or a
    /// top-level statement of its block (`digital.Run.analogTriggers`).
    skip_carried: bool = false,
    fn isEvent(w: *const EventRefs, s: Ast.StrId) bool {
        for (w.module.events) |ev| if (ev.name == s) return true;
        return false;
    }
    pub fn stmt(w: *EventRefs, s: Ast.StmtId) Oom!void {
        if (s == .none) return;
        const f = w.l.file;
        switch (f.stmt(s)) {
            .event_trigger => |t| if (f.exprs.tag(t.target) == .ident and w.isEvent(f.exprs.strOf(t.target))) try w.names.put(w.l.arena, f.str(f.exprs.strOf(t.target)), f.stmtTok(s)),
            .event_control => |c| if (w.skip_carried and c.event != .none and f.exprs.tag(c.event) == .event_function and
                !std.mem.eql(u8, f.str(f.exprs.strOf(c.event)), "absdelta"))
            {
                const body: []const Ast.StmtId = switch (f.stmt(c.body)) {
                    .block => |b| b.body,
                    else => &.{c.body}, // else: a single statement is its own body
                };
                for (body) |t| if (f.stmt(t) != .event_trigger) try w.stmt(t);
                return;
            },
            else => {}, // else: only a trigger names an event outside an expression
        }
        try f.stmtEdges(s, w);
    }
    pub fn expr(w: *EventRefs, e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
        if (e == .none or w.triggers_only) return;
        const ex = &w.l.file.exprs;
        if (ex.tag(e) == .ident and w.isEvent(ex.strOf(e))) try w.names.put(w.l.arena, w.l.file.str(ex.strOf(e)), ex.mainTok(e));
        var buf: [3]Ast.ExprId = undefined;
        for (ex.children(e, &buf)) |c| try w.expr(c, .read);
    }
};

/// Reports the §7.2.2 discrete-context rules listed on `DiscreteCtx` (E0422,
/// E0430, E0431, E0432) and the A/D boundary cases VerA refuses. No-op for a
/// module with no discrete block.
pub fn checkDiscreteContext(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    if (module.discrete.len == 0) return;
    // §7.3.6.1: a named event triggered in the analog context and named in the
    // digital one crosses the A/D boundary as an A2D event, which the
    // mixed-signal kernel does not carry yet. Refused rather than lowered as
    // two unrelated events that never meet. The other direction, a digital
    // trigger the analog block waits on, is §7.3.6.2's explicit D2A
    // (`Lowered.discrete_events`).
    if (self.out.mixed_signal and module.events.len != 0) {
        var dig: EventRefs = .{ .l = self, .module = module };
        for (module.discrete) |blk| try dig.stmt(blk.body);
        var ana: EventRefs = .{ .l = self, .module = module, .triggers_only = true, .skip_carried = true };
        for (module.analog) |blk| try ana.stmt(blk.body);
        for (ana.names.keys(), ana.names.values()) |name, tok| if (dig.names.contains(name))
            try self.err(tok, .E0437, "named event `{s}` is triggered by the analog block and named by a digital process, and the kernel carries such an A2D event only as a statement of a cross/above/timer event control (§7.3.6.1)", .{name});
    }

    var ctx: DiscreteCtx = .{ .mixed = self.out.mixed_signal };
    // Analog functions only. §4.7.3/§7.3.7's rule is that an analog function
    // may not be called from the discrete context; a digital function called
    // from a digital process is the ordinary case and must not be refused.
    for (module.functions) |f| {
        if (!f.is_analog) continue;
        try ctx.funcs.put(self.arena, self.file.str(f.name), {});
    }

    for (module.discrete) |blk| {
        ctx.where = if (blk.is_always) "an always block" else "an initial block";
        try scanContext(self, blk.body, true, blk.main_tok, &ctx);
    }
    // The continuous side second: §7.2.2's conflict and §5.2.1's read are both
    // "this analog statement, against what the discrete blocks own", so the
    // discrete set has to be complete first. §7.2.2 is symmetric; the conflict
    // is reported at the analog statement.
    for (module.analog) |blk| try scanContext(self, blk.body, false, blk.is_initial, &ctx);
}

/// Collects a non-mixed module's A.6.2 `initial` blocks as constant initial
/// values.
///
/// The one shape accepted is a body of assignments of constant expressions to
/// module variables. §7.2.2 gives such a target to the discrete context and
/// forbids the continuous one to assign it (E0432), so the block runs once
/// before the analysis and the constant is the variable's value throughout.
/// This records the expression and `lowerModule` installs it as the variable's
/// initial value, where an A.2.2.1 declaration assignment lands.
///
/// Every other body made the module mixed (`isMixed`, `constantShape`) and
/// runs on the kernel. E0433 is what is left: a body `constantShape` admits
/// whose value `constEval` still cannot fold.
pub fn collectInitialState(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    // A mixed module's `initial` blocks run on the kernel, with the rest of
    // its digital half: their writes are discrete inputs, not constants.
    if (self.out.mixed_signal) return;
    for (module.discrete) |blk| {
        // `always` is refused at the keyword (E0205, parser): it re-runs on an
        // event, so it has no constant reading to collect. Reporting its body
        // here as well would be a second diagnostic for one decision.
        if (blk.is_always) continue;
        try collectInitialStmt(self, blk.body);
    }
}

fn collectInitialStmt(self: *Lower, id: Ast.StmtId) Oom!void {
    if (id == .none) return;
    const ex = &self.file.exprs;
    switch (self.file.stmt(id)) {
        .empty => {},
        // A.6.3 `seq_block` — transparent. Its own local declarations are not:
        // a name declared inside the block is not the module variable the
        // continuous context reads, so there is nothing to install.
        .block => |b| {
            if (b.vars.len != 0 or b.params.len != 0)
                try self.err(self.file.stmtTok(id), .E0433, "a local declaration inside an initial block", .{});
            for (b.body) |s| try collectInitialStmt(self, s);
        },
        .assign => |a| {
            const tok = self.file.stmtTok(id);
            if (a.target == .none or ex.tag(a.target) != .ident) {
                // §3.2.2 `bus[i] = …`: the element is representable, but which
                // element is a question about a value, and the arrays this ever
                // applies to are the ones a digital kernel would drive.
                try self.err(tok, .E0433, "the assignment target is not a plain variable name", .{});
                return;
            }
            const name = self.file.str(ex.strOf(a.target));
            if (lower_constfold.constEval(self, a.value) == null) {
                var b = self.errWith(tok, .E0433);
                b.msg("`{s}` is assigned a value that is not constant", .{name});
                b.note(
                    "an initial block runs once, before the analysis, so a value it computes " ++
                        "from anything the analysis produces does not exist yet",
                    .{},
                );
                try b.emit();
                return;
            }
            // Last assignment wins — the body is sequential, so a later one
            // overwrites an earlier one, and both overwrite an A.2.2.1
            // declaration assignment (which happens at elaboration, before this
            // block runs).
            try self.initial_state.put(self.arena, name, .{ .value = a.value, .tok = tok });
        },
        // An analog-only task is §9.2's E0821 (`scanContext`), which names the
        // rule; E0433 on top would blame the initial-block model instead.
        .sys_task => |s| if (!lower_sysfunc.isAnalogOnlySysFunc(self.file.str(s.name))) try self.err(
            self.file.stmtTok(id),
            .E0433,
            "only assignments of constant expressions are supported here",
            .{},
        ),
        else => try self.err( // else: E0433 names every other statement; a new one is refused, not dropped
            self.file.stmtTok(id),
            .E0433,
            "only assignments of constant expressions are supported here",
            .{},
        ),
    }
}

/// Collect discrete §7.2.2 assignment targets, then check the continuous side
/// for both-context assignments and §5.2.1 digital reads in `analog initial`.
/// The context is compile-time: each walk keeps its own early exits and visits.
/// Runs only in a module that has a discrete block.
///
/// ponytail: a name declared in a named block inside the discrete body shadows
/// the module-level one, and this scan does not model that; `self.vars.contains`
/// keeps it to names the module declared, but a block-local `integer x`
/// shadowing a module-level `real x` is still recorded. Give `Ast.SeqBlock` a
/// scope walk here if a model needs it.
fn scanContext(self: *Lower, id: Ast.StmtId, comptime discrete: bool, context: if (discrete) u32 else bool, ctx: *DiscreteCtx) Oom!void {
    if (id == .none or (!discrete and ctx.assigned.count() == 0)) return;
    const is_initial = if (discrete) {} else context;
    const ex = &self.file.exprs;
    // Every variable the statement writes, not only an assignment target: an
    // output actual and a `$random` seed assign too (`stmtWrites`). The target
    // of `bus[3] = ...` is the array, so `lvalueBase` walks down to the name —
    // §7.2.2's domain is a property of the declaration.
    const funcs: []const Ast.FuncDecl = if (self.module) |m| m.functions else &.{};
    var writes: std.ArrayList(Ast.ExprId) = .empty;
    defer writes.deinit(self.arena);
    try self.file.stmtWrites(funcs, id, self.arena, &writes);
    for (writes.items) |w| {
        const t = self.file.lvalueBase(w);
        if (t == .none) continue;
        const name = self.file.str(ex.strOf(t));
        if (discrete) {
            if (self.vars.contains(name) or self.out.discrete_inputs.contains(name)) try ctx.assigned.put(self.arena, name, context);
        } else if (ctx.assigned.get(name)) |dtok| {
            var b = self.errWith(self.file.exprs.mainTok(t), .E0432);
            b.msg("`{s}`", .{name});
            b.label(
                self.tokenSpan(dtok),
                "`{s}` is also assigned here, in the discrete context",
                .{name},
            );
            try b.emit();
        }
    }
    // Every edge but the four arms below, which read less than all of them.
    const Walk = struct {
        l: *Lower,
        context: if (discrete) u32 else bool,
        ctx: *DiscreteCtx,
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
            try scanContextExpr(w.l, e, discrete, if (discrete) {} else w.context, w.ctx);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            try scanContext(w.l, s, discrete, w.context, w.ctx);
        }
    };
    // §8.5.1 "Note that A2D events must be analog event controlled statements
    // (e.g., @cross, @timer)": a digital event control that waits on a
    // probe's value (`@(V(a))`, `@(posedge V(a) > 1)`) would be an A2D event
    // no analog event function monitors — §7.3.5's cross/above/absdelta are
    // how the discrete context sees a continuous value change.
    if (discrete and self.file.stmt(id) == .event_control) {
        const c = self.file.stmt(id).event_control;
        if (c.kind == .event and c.event != .none) if (probeOutsideEventFn(self.file, c.event)) |p|
            try self.err(ex.mainTok(p), .E0484, "`{s}(...)` in the event control of {s}", .{ self.file.str(ex.strOf(p)), ctx.where });
        // §7.3.6.1 admits "analog variables that are only assigned values in
        // analog event statements"; one the analog block assigns outside
        // every event statement changes with the solution, as a probe does.
        if (c.kind == .event and c.event != .none) if (freeVarOutsideEventFn(self, c.event)) |v|
            try self.err(ex.mainTok(v), .E0484, "`{s}`, which the analog block assigns outside any event statement, in the event control of {s}", .{ self.file.str(ex.strOf(v)), ctx.where });
    }
    // A.6.2: a blocking, nonblocking or procedural `assign`/`deassign` write
    // is to a `variable_lvalue`; only `force`/`release` also take a net.
    if (discrete and self.file.stmt(id) == .assign) {
        const a = self.file.stmt(id).assign;
        const t = self.file.lvalueBase(a.target);
        if (a.continuous != .force and a.continuous != .release and t != .none) if (self.module) |m| {
            if (isNetName(m, ex.strOf(t)))
                try self.err(ex.mainTok(t), .E0482, "`{s}` is a net, and {s}", .{ self.file.str(ex.strOf(t)), switch (a.continuous) {
                    .assign => "a procedural `assign` (§8.5.3.2) writes a variable",
                    .deassign => "`deassign` (§8.5.3.2) releases a variable",
                    .none, .force, .release => if (a.nonblocking) "a nonblocking assignment (§8.5.3.4) updates a variable" else "a blocking assignment (§8.5.3.3) updates a variable",
                } });
        };
    }
    // §9.2's digital column: a task whose "Supported in digital context" cell
    // is No (§9.7: "$fatal, $error, $warning" are "in the analog context
    // only"). Named by the table's own words, not by what VerA can execute.
    if (discrete) if (self.file.stmt(id) == .sys_task) {
        const st = self.file.stmt(id).sys_task;
        const n = self.file.str(st.name);
        if (lower_sysfunc.isAnalogOnlySysFunc(n)) try self.err(self.file.stmtTok(id), .E0821, "`{s}` in {s}", .{ n, ctx.where })
        // §9.4.3's pairing rule — "For each % character (except %m, %% and
        // %l) that appears in a string, a corresponding expression argument
        // shall be supplied" — is a property of the format text, so it holds in
        // the digital context too, where §9.4.7 adds %r to the letters it
        // counts. Judged here, before the digital kernel would meet the gap at
        // run time.
        else if (Mir.callee.takesFormat(.fromName(n)))
            try lower_systask.checkFormatPairing(self, self.file.stmtTok(id), st.args);
    };
    switch (self.file.stmt(id)) {
        // The target is a write, collected above; only the value is read.
        .assign => |a| try scanContextExpr(self, a.value, discrete, is_initial, ctx),
        // §7.3, the write half: "Read operations of nets and variables in both
        // domains are allowed from both contexts. Write operations of nets and
        // variables are only allowed from the context of their domain." A `<+`
        // here writes a continuous net from the discrete context, so it is
        // refused even when the block itself is already refused (E0205 is
        // about VerA; §7.3 is about the source).
        //
        // Not E0432 (§7.2.2, "assigned in both contexts"): that needs two
        // writers. Here there is one writer, in the wrong domain.
        .contribute => |s| if (discrete) {
            try self.err(self.file.exprs.mainTok(s.lhs), .E0435, "contributed from {s}", .{ctx.where});
        } else try scanContextExpr(self, s.rhs, discrete, is_initial, ctx),
        .indirect => |s| if (discrete) {
            try self.err(self.file.exprs.mainTok(s.lhs), .E0435, "indirectly contributed from {s}", .{ctx.where});
        } else try scanContextExpr(self, s.eqn, discrete, is_initial, ctx),
        .jump => {},
        else => try self.file.stmtEdges(id, Walk{ .l = self, .context = context, .ctx = ctx }), // else: stmtEdges is exhaustive
    }
}

/// Every expression reachable from a context statement (`ExprStore.children`).
/// §5.2.1: "digital values cannot be accessed from the analog initial block as
/// they have not yet been assigned when the analog initial block is executed."
/// Only the read is diagnosed, and only inside an `analog initial`; the same
/// read from the ordinary analog block is what §7.3.1 Table 7-1 is the
/// conversion table for.
fn scanContextExpr(self: *Lower, e: Ast.ExprId, comptime discrete: bool, is_initial: if (discrete) void else bool, ctx: *DiscreteCtx) Oom!void {
    if (e == .none or (!discrete and !is_initial)) return;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (discrete) {
        // §4.5.15, verbatim: analog operators "can not be used inside an initial
        // or always block". Same code as the analog-function-body and
        // analog-initial cases, because it is the same sentence's family of
        // contexts: an operator carries state from one accepted timepoint to the
        // next, and none of these has a timepoint to advance.
        if (tag == .filter_call) try self.err(self.file.exprs.mainTok(e), .E0422, "not allowed in {s}", .{ctx.where});
        if (tag == .sys_call and lower_sysfunc.isAnalogOnlySysFunc(self.file.str(ex.strOf(e))))
            try self.err(ex.mainTok(e), .E0821, "`{s}` in {s}", .{ self.file.str(ex.strOf(e)), ctx.where });
        // §5.10: "The usage of initial_step and final_step analog events are
        // not allowed in the digital context."
        if (tag == .event_initial_step or tag == .event_final_step)
            try self.err(ex.mainTok(e), .E0708, "`{s}` in {s}, the digital context", .{
                if (tag == .event_initial_step) "initial_step" else "final_step", ctx.where,
            });
        // What the mixed-signal kernel cannot do yet, named by the clause that
        // asks for it. Both are legal Verilog-AMS (§7.3.3/§7.3.5).
        // `cross`/`above` are monitored (§7.3.5) and `V(a)`/`V(a, b)` probed
        // (§7.3.6.3) by the mixed-signal kernel.
        if (ctx.mixed) switch (tag) {
            .event_function => {
                const name = self.file.str(ex.strOf(e));
                if (!std.mem.eql(u8, name, "cross") and !std.mem.eql(u8, name, "above") and !std.mem.eql(u8, name, "absdelta"))
                    try self.err(ex.mainTok(e), .E0437, "`{s}` in {s} is §7.3.6.1's A2D event, and the kernel monitors only cross(), above() and absdelta()", .{ name, ctx.where });
            },
            .branch_access => if (!std.mem.eql(u8, self.file.str(ex.strOf(e)), "V") or !probeTerminal(ex, ex.lhs(e)) or
                (ex.rhs(e) != .none and !probeTerminal(ex, ex.rhs(e))))
                try self.err(ex.mainTok(e), .E0437, "an analog probe in {s} is §7.3.6.3's promoted-time read, and the kernel reads only V(net), V(net, net) and V(branch)", .{ctx.where})
            else for ([_]Ast.ExprId{ ex.lhs(e), ex.rhs(e) }) |t| {
                if (t != .none) try recordProbeTerminal(self, t, ex.rhs(e) == .none);
            },
            .port_access => try self.err(ex.mainTok(e), .E0437, "a port flow probe in {s} is §7.3.6.3's promoted-time read, and the kernel reads only V(net) and V(net, net)", .{ctx.where}),
            else => {}, // else: every other tag is executable or judged elsewhere
        };
        // §7.3.5 "The arguments to these events are in the continuous
        // context": a monitored event in a digital event control is the
        // §5.10.3 function itself, so its argument rules hold here as they
        // do in an analog block (E0517), and a call inside its arguments is
        // a call from the continuous context, so §7.3.7's first sentence
        // (E0436) applies to a digital function there.
        if (tag == .event_function) {
            _ = try lower_event.checkEventArgBounds(self, e, self.file.str(ex.strOf(e)));
            for (ex.args(e)) |a| try digitalCallsIn(self, a);
        }
        // §7.3.3 "All probes which are legal in a continuous context of a
        // module are also legal in the discrete context" — and the probe is
        // one "using access functions": the access function has to belong to
        // the net's discipline in either context (§4.4, E0501/E0337). Only a
        // declared net that is an analog node is judged; a digital-owned
        // name never became one (`declareDiscreteInputs`).
        if (tag == .branch_access) if (self.access_kind.get(self.file.str(ex.strOf(e)))) |access| {
            for ([_]Ast.ExprId{ ex.lhs(e), ex.rhs(e) }) |arg| {
                if (arg == .none or ex.tag(arg) != .ident) continue;
                const node = self.node_voltages.get(self.file.str(ex.strOf(arg))) orelse continue;
                try lower_contrib.checkAccessMatch(self, e, self.file.str(ex.strOf(e)), access, node);
            }
        };
        if (tag == .call) {
            const name = self.file.str(ex.strOf(e));
            if (ctx.funcs.contains(name)) {
                var b = self.errWith(self.file.exprs.mainTok(e), .E0430);
                b.msg("`{s}`", .{name});
                b.note(
                    "an analog function shall only be called from an analog block " ++
                        "or from another analog function",
                    .{},
                );
                try b.emit();
            }
        }
    } else if (tag == .ident) {
        const name = self.file.str(ex.strOf(e));
        if (ctx.assigned.get(name)) |dtok| {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0431);
            b.msg("`{s}`", .{name});
            b.label(self.tokenSpan(dtok), "`{s}` is assigned here, in the discrete context", .{name});
            try b.emit();
        }
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| try scanContextExpr(self, c, discrete, is_initial, ctx);
}

/// Whether `e` is a terminal the mixed-signal kernel's digital `V(...)` probe
/// reads: a simple or a §6.7.1 hierarchical name of a net or a named branch.
fn probeTerminal(ex: *const Ast.ExprStore, e: Ast.ExprId) bool {
    return ex.tag(e) == .ident or ex.tag(e) == .hier_ident;
}

/// Records digital probe terminal `t` in `Lowered.discrete_probes`, under the
/// name the digital half spells it (its parts joined by `.`): the node pair
/// of the named branch it names when it is a probe's `only` argument, else
/// its net and ground. §6.7.1 a hierarchical name that names neither is
/// E0901, as in the analog block; a simple one the digital half resolves.
fn recordProbeTerminal(self: *Lower, t: Ast.ExprId, only: bool) Oom!void {
    const ex = &self.file.exprs;
    const key = if (ex.tag(t) == .ident) self.file.str(ex.strOf(t)) else blk: {
        var parts: std.ArrayList([]const u8) = .empty;
        for (ex.nameParts(t)) |p| try parts.append(self.arena, self.file.str(p));
        break :blk try std.mem.join(self.arena, ".", parts.items);
    };
    if (self.out.discrete_probes.contains(key)) return;
    const name = if (ex.tag(t) == .ident) key else try lower_expr.flatName(self, t);
    const branch = if (only) self.branches.get(name) else null;
    const pair: [2]u32 = if (branch) |b| .{ b.hi, b.lo } else if (self.node_voltages.get(name)) |n| .{ n, Lower.ground } else {
        if (ex.tag(t) == .hier_ident) try self.err(ex.mainTok(t), .E0901, "`{s}` names no net or branch in the elaborated design", .{name});
        return;
    };
    var nodes: [2][]const u8 = undefined;
    for (pair, &nodes) |n, *out| out.* = if (n == Lower.ground) "" else self.out.nodeName(n);
    try self.out.discrete_probes.put(self.arena, key, nodes);
}

/// §7.3.7 "Digital functions cannot be called from within the analog
/// context", for an expression the LRM puts in the continuous context while
/// it is written inside a digital process: the arguments of a monitored
/// event (§7.3.5). The same code and wording as `lower_func.lowerUserCall`'s
/// call from an analog block.
fn digitalCallsIn(self: *Lower, e: Ast.ExprId) Oom!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .call) if (self.module) |m| for (m.functions) |*fd| {
        if (fd.name != ex.strOf(e) or fd.is_analog) continue;
        var b = self.errWith(ex.mainTok(e), .E0436);
        b.msg("`{s}`, in the arguments of an analog event, which §7.3.5 puts in the continuous context", .{self.file.str(fd.name)});
        b.label(self.tokenSpan(fd.main_tok), "`{s}` is declared here, without `analog`", .{self.file.str(fd.name)});
        try b.emit();
        break;
    };
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| try digitalCallsIn(self, c);
}

test isMixed {
    // §8.5: the discrete half needs the event queue exactly when it has a
    // process, a value only the four-state kernel holds, or a file task.
    const cases = [_]struct { src: []const u8, want: bool }{
        // A constant `initial` is `collectInitialState`'s fast path.
        .{ .src = "module m; real x; initial x = 1.0; endmodule", .want = false },
        .{ .src = "module m; integer x; initial begin x = 1; x = 2; end endmodule", .want = false },
        // A continuous assignment is a process (§8.5.3.2).
        .{ .src = "module m; wire w; assign w = 1; endmodule", .want = true },
        // §3.7 only the digital kernel holds a wreal's value.
        .{ .src = "module m; wreal w; endmodule", .want = true },
        // C.3/§7.3.2 an x has nowhere to live in an analog variable.
        .{ .src = "module m; integer x; initial x = 1'bx; endmodule", .want = true },
        // A nonblocking write suspends (§8.5.3.4).
        .{ .src = "module m; real x; initial x <= 1.0; endmodule", .want = true },
        // §9.5.1.2 one descriptor table for both contexts.
        .{ .src = "module m; integer fd; initial fd = $fopen(\"f\"); endmodule", .want = true },
        // #57: an untimed initial is a process (IEEE 1364-2005 §9.9.1) and runs
        // on the kernel exactly as the same body behind `#0` does.
        .{ .src = "module m(p); inout p; electrical p; initial $display(\"hi\"); analog I(p) <+ V(p); endmodule", .want = true },
        .{ .src = "module m(p); inout p; electrical p; initial #0 $display(\"hi\"); analog I(p) <+ V(p); endmodule", .want = true },
        // §7.3.3 a discrete context may read a continuous variable: a value
        // only the run computes.
        .{ .src = "module m; real x; integer k; initial x = k + 1.0; endmodule", .want = true },
        .{ .src = "module m; integer q; initial for (q = 0; q < 3; q = q + 1) q = 1; endmodule", .want = true },
        .{ .src = "module m; real a[0:1]; initial a[0] = 1.0; endmodule", .want = true },
        .{ .src = "module m; real x; initial begin : b integer t; t = 1; x = 2.0; end endmodule", .want = true },
        // What `constEval` folds stays on the fast path: a parameter (§3.4),
        // §4.3 math and a §17.8 conversion.
        .{ .src = "module m; parameter real k = 2.5; real r; initial r = sqrt(k) + $rtoi(2.5); endmodule", .want = false },
        // §7.3 an analog read of a discrete net is the kernel's value; of a
        // continuous one, or of a name a variable re-declares, it is not.
        .{ .src = "module m(d, p); input d; wire d; inout p; electrical p; analog I(p) <+ d; endmodule", .want = true },
        .{ .src = "module m(d, p); input d; inout p; electrical d, p; analog I(p) <+ V(d); endmodule", .want = false },
        .{ .src = "module m(d, p); input d; integer d; inout p; electrical p; analog I(p) <+ d; endmodule", .want = false },
    };
    for (cases) |c| {
        var h: Lower.Harness = undefined;
        try h.init(std.testing.allocator, c.src);
        defer h.deinit();
        std.testing.expectEqual(c.want, isMixed(&h.file, &h.file.modules[h.file.builtin_modules])) catch |e| {
            std.debug.print("{s}\n", .{c.src});
            return e;
        };
    }
}

test markDiscreteExprs {
    // §7.3.2: in an analog block an x or z literal is a value only as a
    // `case` label or an operand of `===`/`!==`; anywhere else it stays
    // E0130's. Only literals with an unknown bit are counted, so the
    // prelude's two-state literals do not enter.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  integer k;
        \\  analog begin
        \\    case (k) 1'bx: k = 1; endcase
        \\    k = (k === 1'bz) + 2'bx1;
        \\    I(p) <+ V(p);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    const ex = &h.file.exprs;
    const marks = try std.testing.allocator.alloc(bool, ex.len());
    defer std.testing.allocator.free(marks);
    @memset(marks, false);
    markDiscreteExprs(&h.file, marks);
    var marked: usize = 0;
    var unmarked: usize = 0;
    for (marks, 0..) |m, i| {
        const e: Ast.ExprId = @fromBackingInt(@intCast(i));
        if (ex.tag(e) != .logic_literal) continue;
        if (!ex.logicValue(e).hasUnknown()) continue;
        if (m) marked += 1 else unmarked += 1;
    }
    try std.testing.expectEqual(2, marked);
    try std.testing.expectEqual(1, unmarked);
}

test "collectInitialState: A.6.2 a constant initial installs its value; an undeclared target is E0313" {
    // A body that is not the constant shape is `isMixed`'s (its test, #57).
    const cases = [_]struct { decls: []const u8, want: ?diag.Code }{
        .{ .decls = "  real x;\n  initial x = 2.0;", .want = null },
        // §6.8: a name the module never declared.
        .{ .decls = "  initial zz = 1.0;", .want = .E0313 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(c.decls, "", c.want);
}

test "checkDiscreteContext: §5.2.1 and §7.2.2 judge the analog side against the digital writes" {
    // §5.2.1: "digital values cannot be accessed from the analog initial
    // block" (E0431); the ordinary analog block reads one through §7.3.1.
    try Lower.expectBodyVerdict(
        "  real d, y;\n  initial d = 1.0;\n  analog initial begin\n    y = d;\n  end",
        "",
        .E0431,
    );
    try Lower.expectBodyVerdict("  real d, y;\n  initial d = 1.0;", "    y = d;", null);
    // §7.2.2: "It shall be an error to assign to a given variable in both
    // contexts" (E0432).
    try Lower.expectBodyVerdict("  real x;\n  initial x = 1.0;", "    x = 2.0;", .E0432);
    // §5.10: initial_step "not allowed in the digital context" (E0708).
    try Lower.expectBodyVerdict("  real x;\n  initial @(initial_step) x = 1.0;", "", .E0708);
}

test "§6.3.4 monitored-event parameters retain their dependencies, not unrelated reals" {
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  parameter real base = 0.1, unused = 7.0;
        \\  parameter delta = 2.0 * base;
        \\  localparam real tol = base / 100.0;
        \\  integer n;
        \\  initial n = 0;
        \\  always @(absdelta(V(p), delta, 1p, tol)) n = n + 1;
        \\  analog I(p) <+ 0.0;
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 3), h.low.out.discrete_params.count());
    for ([_][]const u8{ "delta", "base", "tol" }) |name|
        try std.testing.expect(h.low.out.discrete_params.contains(name));
    try std.testing.expect(!h.low.out.discrete_params.contains("unused"));
}

test "lower: A.6.1 an assign target is judged by declaration kind, then by domain" {
    // IEEE 1364-2005 §6.1 (via VAMS §1.1): a continuous assignment drives a
    // NET, so a variable is E0438. Among nets, §7.3's "write operations ... are
    // only allowed from the context of their domain" refuses a continuous one
    // (E0435) and admits a discrete one — `ddiscrete` (§3.6.2.2 `domain
    // discrete`) exactly as an undisciplined `wire`. Pinned here because the
    // positive fixture (ch07/ddiscrete_net_continuously_assigned) is xfail on the
    // digital runner and would not catch a wrong E0438.
    const cases = [_]struct { decl: []const u8, code: ?diag.Code }{
        .{ .decl = "integer t;", .code = .E0438 },
        .{ .decl = "electrical t;", .code = .E0435 },
        .{ .decl = "ddiscrete t;", .code = null },
        .{ .decl = "wire t;", .code = null },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p);
            \\  inout p; electrical p;
            \\  {s}
            \\  assign t = 1'b1;
            \\  analog I(p) <+ V(p) + t;
            \\endmodule
        , .{c.decl});
        defer std.testing.allocator.free(src);

        var h: Lower.Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }
        var first: ?diag.Code = null;
        for (0..h.bag.count()) |i| {
            if (h.bag.at(i).code == .E0438 or h.bag.at(i).code == .E0435) first = first orelse h.bag.at(i).code;
        }
        std.testing.expectEqual(c.code, first) catch |e| {
            std.debug.print("declaration: {s}\n", .{c.decl});
            return e;
        };
    }
}
