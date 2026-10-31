//! §5.10 held variables: the module's analog blocks in, the set of
//! variables whose value another evaluation can observe out (event writes,
//! reads before writes), decided before any declaration lowers; and §3.2.2's
//! memory-backed arrays (a subscript known only at run time).
//!
//! Cites: §3.2, §3.2.2, §3.4, §3.5, §4.7.2.3, §5.2.1, §5.3.2, §5.6.1.3, §5.9,
//! §5.9.2, §5.10, §5.11, §7.3.2, A.8.1, §8.5, §9.4.
//!
//! Contents:
//! - `pub const HeldFrame = struct`
//! - `pub fn markHeldVars(self: *Lower, module: *const Ast.ModuleDecl) Oom!void`
//! - private `Exposed` (`expr`, `stmt`)
//! - private `Held` (`expr`, `stmt`)
//! - `pub fn markMemArrays(self: *Lower, module: *const Ast.ModuleDecl) Oom!void`
//! - `pub fn dropHeld(lowered: *Lower.Lowered, keep: []const bool) void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_shape = @import("shape.zig");
const lower_expr_select = @import("expr_select.zig");
const Oom = Lower.Oom;
const none_u32 = Lower.none_u32;

/// One enclosing §5.3.2 named block, as `scanHeld` sees it: the dotted prefix
/// its locals are keyed under, and the declarations that say which names those
/// are.
pub const HeldFrame = struct { prefix: []const u8, vars: []const Ast.VarDecl };

/// §3.2: "Real variables are initialized to zero (0) at the start of a
/// simulation" — once, not per evaluation — and §5.6.1.3: "Unlike variables,
/// the contributed value for a branch is only valid for the current
/// iteration." A variable keeps its value from one evaluation to the next.
///
/// Only a READ that some path reaches before any WRITE of the same evaluation
/// can observe that (an upward-exposed use), so those variables, if the analog
/// block writes them at all, get a §5.10 slot; one assigned before every read
/// on every path needs none. §7.3.2's `avar = avar; // hold value` is the case.
///
/// Two of those always observe the held value, so they are `.retained`: a
/// variable an `analog initial` body writes (§5.2.1, read on later
/// evaluations), and an exposed read that REACHES a later write of the same
/// evaluation (`avar = avar`: what it reads is what the last evaluation
/// wrote). The rest are `.unless_invariant`: no read precedes a write, so the
/// held value is seen only if whether a write runs changes between
/// evaluations, which `pruneHeld` (prove/setup.zig) decides and `dropHeld`
/// applies.
///
/// §3.2.2 an array is its scalarized elements, so a write whose subscripts
/// are literals assigns that element, and an array read with a subscript that does not
/// fold (or of the whole array) needs every element assigned.
///
/// ponytail: a definite-assignment walk over the AST, conservative where it is
/// cheap to be — any other subscript assigns nothing, a loop or
/// event body may not run, and after a §5.11 `disable` nothing counts. Each is
/// a slot that might not be needed, never a hold that is missed.
const Exposed = struct {
    l: *Lower,
    /// The module's array variables by name, for `declOf`; a named block's
    /// declarations are in `held_frames`.
    arrays: std.AutoHashMapUnmanaged(Ast.StrId, *const Ast.VarDecl) = .empty,
    /// Every key the walk has met, with the sets it is in (`Marks`). One map
    /// and a byte per key, where six sets over the same keys stored each key
    /// six times.
    marks: std.StringHashMapUnmanaged(Marks) = .empty,
    /// The keys with `def` set, in the order set, so a branch is undone by
    /// truncating it.
    list: std.ArrayList([]const u8) = .empty,
    disabled: bool = false,
    /// The keys with `pend` set, in the order set, undone per arm like `list`.
    pend_list: std.ArrayList([]const u8) = .empty,
    in_initial: bool = false,
    /// One statement's write targets, refilled per statement: `stmt` reads it
    /// to the end before it recurses, so one buffer serves the whole walk.
    ws: std.ArrayList(Ast.ExprId) = .empty,

    /// Which of the walk's sets a key is in.
    const Marks = packed struct(u8) {
        /// Assigned on every path to here.
        def: bool = false,
        /// Read where `def` was not set.
        read: bool = false,
        /// Written anywhere.
        write: bool = false,
        /// An exposed read on SOME path to here (a may-set); a write of the
        /// key is reached by that read.
        pend: bool = false,
        /// A write reached by an exposed read (`pend` at the write).
        reach: bool = false,
        /// Written by an `analog initial` body.
        initial: bool = false,
        _: u2 = 0,
    };

    fn has(x: *const Exposed, k: []const u8, comptime set: std.meta.FieldEnum(Marks)) bool {
        const m = x.marks.get(k) orelse return false;
        return @field(m, @tagName(set));
    }

    fn marksOf(x: *Exposed, k: []const u8) Oom!*Marks {
        const gop = try x.marks.getOrPut(x.l.arena, k);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    fn def(x: *Exposed, k: []const u8) Oom!void {
        if (x.disabled or x.has(k, .def)) return;
        (try x.marksOf(k)).def = true;
        try x.list.append(x.l.arena, k);
    }

    fn undo(x: *Exposed, at: usize) void {
        std.debug.assert(at <= x.list.items.len);
        for (x.list.items[at..]) |k| x.marks.getPtr(k).?.def = false;
        x.list.shrinkRetainingCapacity(at);
    }

    fn exposed(x: *Exposed, k: []const u8) Oom!void {
        const m = try x.marksOf(k);
        m.read = true;
        if (m.pend) return;
        m.pend = true;
        try x.pend_list.append(x.l.arena, k);
    }

    fn write(x: *Exposed, k: []const u8) Oom!void {
        const m = try x.marksOf(k);
        m.write = true;
        if (m.pend) m.reach = true;
        if (x.in_initial) m.initial = true;
    }

    /// §5.9 a loop body may run again after itself, so it is walked twice:
    /// a read in one iteration reaches a write in the next.
    fn loop(x: *Exposed, body: Ast.StmtId, step: Ast.StmtId) Oom!void {
        const mark = x.list.items.len;
        for (0..2) |_| {
            try x.stmt(body);
            try x.stmt(step);
        }
        x.undo(mark);
    }

    /// `a` then `b` on a path that may not take them (§5.10, §5.2.1).
    fn maybe(x: *Exposed, a: Ast.StmtId, b: Ast.StmtId) Oom!void {
        const mark = x.list.items.len;
        try x.stmt(a);
        try x.stmt(b);
        x.undo(mark);
    }

    /// One of `arms` runs; `.none` is the empty arm. Keeps what all assign.
    fn alts(x: *Exposed, arms: []const Ast.StmtId) Oom!void {
        const mark = x.list.items.len;
        const pmark = x.pend_list.items.len;
        var pended: std.ArrayList([]const u8) = .empty;
        var common: ?[]const []const u8 = null;
        for (arms) |arm| {
            try x.stmt(arm);
            // The arms exclude each other: one's reads reach no write of another.
            try pended.appendSlice(x.l.arena, x.pend_list.items[pmark..]);
            for (x.pend_list.items[pmark..]) |k| x.marks.getPtr(k).?.pend = false;
            x.pend_list.shrinkRetainingCapacity(pmark);
            const got = x.list.items[mark..];
            if (common) |c| {
                var keep: std.ArrayList([]const u8) = .empty;
                for (c) |k| for (got) |g| if (std.mem.eql(u8, k, g)) {
                    try keep.append(x.l.arena, k);
                    break;
                };
                common = keep.items;
            } else common = try x.l.arena.dupe([]const u8, got);
            x.undo(mark);
        }
        for (common orelse &.{}) |k| try x.def(k);
        for (pended.items) |k| if (!x.has(k, .pend)) {
            (try x.marksOf(k)).pend = true;
            try x.pend_list.append(x.l.arena, k);
        };
    }

    fn stmt(x: *Exposed, id: Ast.StmtId) Oom!void {
        if (id == .none) return;
        const self = x.l;
        const s = self.file.stmt(id);
        // §5.9.2 the init assignment runs once, before the condition is read.
        if (s == .for_stmt) try x.stmt(s.for_stmt.init);
        // §9.4 a print the device drops reads nothing in the device.
        const dropped = s == .sys_task and self.opts.displays_dropped and
            Mir.callee.family(.fromName(self.file.str(s.sys_task.name))) == .display;
        if (!dropped) try self.file.stmtEdges(id, Own{ .x = x });
        const funcs: []const Ast.FuncDecl = if (self.module) |m| m.functions else &.{};
        x.ws.clearRetainingCapacity();
        try self.file.stmtWrites(funcs, id, self.arena, &x.ws);
        for (x.ws.items) |w| {
            const t = self.file.lvalueBase(w);
            if (t == .none) continue;
            const k = try heldKey(self, self.file.exprs.strOf(t));
            try x.write(k);
            if (t == w) try x.def(k) else if (try x.elem(k, w)) |ek| try x.def(ek);
        }
        switch (s) {
            .block => |b| {
                // The same frames `scanHeld` keeps, so the keys agree.
                const named = try pushHeldFrame(self, b);
                for (b.body) |c| try x.stmt(c);
                if (named) _ = self.var_state.held_frames.pop();
            },
            .if_stmt => |c| try x.alts(&.{ c.then_s, c.else_s }),
            .case_stmt => |c| {
                var arms: std.ArrayList(Ast.StmtId) = .empty;
                var dflt = false;
                for (c.arms) |arm| {
                    try arms.append(self.arena, arm.body);
                    dflt = dflt or arm.labels.len == 0;
                }
                if (!dflt) try arms.append(self.arena, .none);
                try x.alts(arms.items);
            },
            .for_stmt => |c| try x.loop(c.body, c.step),
            .while_stmt => |c| try x.loop(c.body, .none),
            .repeat_stmt => |c| try x.loop(c.body, .none),
            .event_control => |c| try x.maybe(c.body, .none),
            .disable => x.disabled = true,
            // A `break`/`continue` leaves a loop body, whose assignments never
            // count past the loop anyway; `return` ends a function, not this.
            .jump, .empty, .event_trigger, .assign, .contribute, .indirect, .sys_task => {},
        }
    }

    /// `stmtEdges` visitor: the statement's own expressions, children skipped.
    const Own = struct {
        x: *Exposed,
        pub fn expr(o: Own, e: Ast.ExprId, edge: Ast.SourceFile.Edge) Oom!void {
            switch (edge) {
                .read, .branch => try o.x.read(e),
                .write => try o.x.subscripts(e),
            }
        }
        pub fn stmt(_: Own, _: Ast.StmtId) Oom!void {}
    };

    fn read(x: *Exposed, e: Ast.ExprId) Oom!void {
        if (e == .none) return;
        const file = x.l.file;
        const ex = &file.exprs;
        const t = file.lvalueBase(e);
        if (t != .none) {
            // Subscripts first; they are reads of their own.
            var i = e;
            while (i != t) : (i = ex.lhs(i)) try x.read(ex.rhs(i));
            const k = try heldKey(x.l, ex.strOf(t));
            if (x.has(k, .def)) return;
            if (t != e) if (try x.elem(k, e)) |ek| {
                if (!x.has(ek, .def)) try x.exposed(k);
                return;
            };
            // The whole variable, or an element nobody can name statically.
            if (!x.allCells(k, ex.strOf(t))) try x.exposed(k);
            return;
        }
        // §4.7.2.3 an `output` actual is written by the call, not read.
        if (ex.tag(e) == .call) {
            const funcs: []const Ast.FuncDecl = if (x.l.module) |m| m.functions else &.{};
            for (funcs) |fd| if (fd.name == ex.strOf(e)) {
                for (ex.args(e), 0..) |a, i| {
                    if (i < fd.args.len and fd.args[i].direction == .output) try x.subscripts(a) else try x.read(a);
                }
                return;
            };
        }
        var buf: [3]Ast.ExprId = undefined;
        for (ex.children(e, &buf)) |c| try x.read(c);
    }

    /// What writing lvalue `e` reads: only its subscripts, and an A.8.1
    /// assignment pattern's elements' (§4.7.2.3).
    fn subscripts(x: *Exposed, e: Ast.ExprId) Oom!void {
        if (e == .none) return;
        const ex = &x.l.file.exprs;
        if (ex.tag(e) == .assign_pattern) {
            for (ex.args(e)) |a| try x.subscripts(a);
            return;
        }
        var t = e;
        while (ex.tag(t) == .index) : (t = ex.lhs(t)) try x.read(ex.rhs(t));
    }

    /// `k[i][j]` when every subscript of `e` is a literal, else null.
    fn elem(x: *Exposed, k: []const u8, e: Ast.ExprId) Oom!?[]const u8 {
        const ex = &x.l.file.exprs;
        var idx: std.ArrayList(i64) = .empty;
        var i = e;
        while (ex.tag(i) == .index) : (i = ex.lhs(i)) {
            if (ex.tag(ex.rhs(i)) == .range) return null;
            // Not through a parameter: a model card may override it (§3.4).
            const c = lower_constfold.foldExpr(x.l, ex.rhs(i), false) orelse return null;
            // A subscript with no integer names no element (E0310 when lowered).
            try idx.insert(x.l.arena, 0, c.asIntExact() orelse return null);
        }
        return try lower_shape.elemName(x.l, k, idx.items);
    }

    /// Is every §3.2.2 element of array `k` (declared `name`) assigned?
    /// False for a scalar, whose own key `read` has already tried.
    fn allCells(x: *Exposed, k: []const u8, name: Ast.StrId) bool {
        const decl = x.declOf(name) orelse return false;
        if (decl.dims.len == 0) return false;
        // This walk runs before `dimsBounds` has refused a shape (E0308,
        // E1016), so a bound may be anything a fold gives: one with no
        // integer, or a count no `usize` holds, can have no cell left
        // unassigned that the walk could name, so the answer is "not all".
        var cells: usize = 1;
        for (decl.dims) |d| {
            const a = (lower_constfold.constEval(x.l, d.msb) orelse return false).asIntExact() orelse return false;
            const b = (lower_constfold.constEval(x.l, d.lsb) orelse return false).asIntExact() orelse return false;
            const n = std.math.cast(usize, @abs(@as(i128, a) - b) + 1) orelse return false;
            cells = std.math.mul(usize, cells, n) catch return false;
        }
        var have: usize = 0;
        for (x.list.items) |d| have += @intFromBool(d.len > k.len and std.mem.startsWith(u8, d, k) and d[k.len] == '[');
        return have == cells;
    }

    /// The nearest declaration of `name`, as `heldKey` resolves it, or null
    /// when that is a module scalar or nothing.
    fn declOf(x: *Exposed, name: Ast.StrId) ?*const Ast.VarDecl {
        const frames = x.l.var_state.held_frames.items;
        var i = frames.len;
        while (i > 0) {
            i -= 1;
            for (frames[i].vars) |*v| if (v.name == name) return v;
        }
        return x.arrays.get(name);
    }
};

/// Where `scanHeld` is: outside any event body, or in one whose terms are all
/// explicit D2A events (§8.5), or in any other.
const Body = enum { none, d2a, analog };

const Held = struct {
    l: *Lower,
    in_event: Body,
    pub fn expr(_: Held, _: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {}
    pub fn stmt(h: Held, s: Ast.StmtId) Oom!void {
        try scanHeld(h.l, s, h.in_event);
    }
};

/// §5.10. Collect the variables assigned inside an `@(<event>)` body, before
/// any of them is declared.
pub fn markHeldVars(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(module.name != .none);
    for (module.analog) |blk| try scanHeld(self, blk.body, .none);
    self.var_state.held_frames.clearRetainingCapacity();
    // §3.2 retention, beside the §5.10 rule above: see `Exposed`.
    var x: Exposed = .{ .l = self };
    for (module.vars) |*v| if (v.dims.len != 0) try x.arrays.put(self.arena, v.name, v);
    for (module.analog) |blk| {
        // §5.2.1 an `analog initial` body runs on the first evaluation only,
        // so what it assigns is not assigned on the later ones.
        x.in_initial = blk.is_initial;
        if (blk.is_initial) try x.maybe(blk.body, .none) else try x.stmt(blk.body);
    }
    self.var_state.held_frames.clearRetainingCapacity();
    // `held_names` and `carried` are only probed, never walked, so the order
    // these loops visit the keys in does not reach the output.
    var it = x.marks.iterator();
    while (it.next()) |e| if (e.value_ptr.read and e.value_ptr.write) {
        const gop = try self.var_state.held_names.getOrPut(self.arena, e.key_ptr.*);
        if (gop.found_existing) continue;
        // Otherwise the held value is observable only when a write's
        // placement varies from one evaluation to the next, which only
        // codegen's solve-invariance can say.
        gop.value_ptr.* = if (e.value_ptr.reach or e.value_ptr.initial) .retained else .unless_invariant;
    };
    it = x.marks.iterator();
    while (it.next()) |e| if (e.value_ptr.read and
        (e.value_ptr.initial or self.var_state.held_names.get(e.key_ptr.*) == .event))
        try self.var_state.carried.put(self.arena, e.key_ptr.*, {});
    for (self.out.discrete_reads.keys()) |name| {
        const gop = try self.var_state.held_names.getOrPut(self.arena, name);
        if (!gop.found_existing or gop.value_ptr.* == .unless_invariant) gop.value_ptr.* = .a2d;
    }
}

/// §3.2.2 which arrays does some subscript index at run time? Lowering decides
/// that per reference (`lower_expr_select.lowerIndex`: a subscript `foldExpr(.., false)`
/// cannot fold), after the declaration has already chosen a representation, so
/// this answers it ahead of time, by NAME and over the whole source, with the
/// same rule: a subscript reading a variable, a parameter (a model card can
/// override it) or a call is runtime; a literal, a genvar (§3.5: an unrolled
/// loop binds it) and a local constant are not.
///
/// The answer only picks a representation (both lower every access), so a
/// wrong guess costs speed, never meaning: a runtime-indexed array kept scalar
/// reads through a `$idx` switch and writes one masked select per element.
pub fn markMemArrays(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(module.name != .none);
    var vars: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty;
    defer vars.deinit(self.arena);
    for (module.vars) |v| try vars.put(self.arena, v.name, {});
    for (module.functions) |f| {
        for (f.vars) |v| try vars.put(self.arena, v.name, {});
        for (f.args) |a| try vars.put(self.arena, a.name, {});
    }
    var blocks = self.file.seqBlocks();
    while (blocks.next()) |b| for (b.vars) |v| try vars.put(self.arena, v.name, {});
    const ex = &self.file.exprs;
    for (0..ex.len()) |i| {
        const e: Ast.ExprId = @fromBackingInt(@intCast(i));
        if (ex.tag(e) != .index or !runtimeSub(self, &vars, module.genvars, ex.rhs(e))) continue;
        var base = ex.lhs(e);
        while (ex.tag(base) == .index) base = ex.lhs(base);
        if (ex.tag(base) == .ident) try self.var_state.mem_names.put(self.arena, ex.strOf(base), {});
    }
}

/// §3.2 applies `prove.setup.pruneHeld`'s mask: drops every `held_vars` row
/// whose `keep` flag is false and renumbers the `mem_arrays` rows that point
/// at a kept one. The MIR side (the seeds' row arguments) is already
/// renumbered the same way, densely over the kept rows in order. Asserts the
/// mask has one flag per row and no dropped row is an array's.
pub fn dropHeld(lowered: *Lower.Lowered, keep: []const bool) void {
    const held = &lowered.held_vars;
    assert(keep.len == held.items.len);
    var kept: usize = 0;
    for (held.items, keep) |h, k| {
        if (!k) {
            std.debug.assert(h.array == none_u32);
            continue;
        }
        if (h.array != none_u32) lowered.mem_arrays.items[h.array].held = @intCast(kept);
        held.items[kept] = h;
        kept += 1;
    }
    held.shrinkRetainingCapacity(kept);
}

// ---- private ----

/// Opens block `b`'s `held_frames` frame and returns true, or returns false
/// for an unnamed block: §5.3.2 makes only a NAMED block's locals static, so
/// only a label opens a frame; an unnamed `begin`'s declarations are ordinary.
/// The caller pops the frame after the block's body.
fn pushHeldFrame(self: *Lower, b: Ast.SeqBlock) Oom!bool {
    if (b.name == .none) return false;
    const outer = if (self.var_state.held_frames.last()) |f| f.prefix else "";
    try self.var_state.held_frames.append(self.arena, .{
        .prefix = try self.arena.print("{s}{s}.", .{ outer, self.file.str(b.name) }),
        .vars = b.vars,
    });
    return true;
}

/// §5.3.2: "The block names give a means of uniquely identifying all variables
/// at any simulation time." Which location an assignment target names is
/// decided by the NEAREST declaration of it, so the walk looks outward from the
/// innermost named block and falls back to the bare (module-scope) name — a
/// module variable assigned from inside a block is still the module's.
fn heldKey(self: *Lower, id: Ast.StrId) Oom![]const u8 {
    const name = self.file.str(id);
    var i = self.var_state.held_frames.items.len;
    while (i > 0) {
        i -= 1;
        const f = self.var_state.held_frames.items[i];
        for (f.vars) |v| {
            if (v.name != id) continue; // interned: identity is name equality
            var buf: [lower_shape.elem_key_len]u8 = undefined;
            const key = std.mem.print(&buf, "{s}{s}", .{ f.prefix, name }) catch
                return self.arena.print("{s}{s}", .{ f.prefix, name });
            const gop = try self.var_state.held_keys.getOrPut(self.arena, key);
            if (!gop.found_existing) gop.key_ptr.* = try self.arena.dupe(u8, key);
            return gop.key_ptr.*;
        }
    }
    return name;
}

/// One walk, two modes: outside an event body we are only looking for the
/// `@(...)`; inside one, every variable a statement WRITES has to survive to
/// the next evaluation. "Writes" is `Ast.SourceFile.stmtWrites`, not only the
/// assignment target: an output actual or a `$random` seed counts too.
fn scanHeld(self: *Lower, id: Ast.StmtId, in_event: Body) Oom!void {
    assert(id == .none or @backingInt(id) < self.stmtCount());
    if (id == .none) return;
    if (in_event != .none) {
        const funcs: []const Ast.FuncDecl = if (self.module) |m| m.functions else &.{};
        var writes: std.ArrayList(Ast.ExprId) = .empty;
        defer writes.deinit(self.arena);
        try self.file.stmtWrites(funcs, id, self.arena, &writes);
        // §3.2 `x[i] = …` holds the ARRAY; `declareVarDecl` scalarizes it.
        for (writes.items) |w| {
            const t = self.file.lvalueBase(w);
            if (t == .none) continue;
            const key = try heldKey(self, self.file.exprs.strOf(t));
            try self.var_state.held_names.put(self.arena, key, .event);
            const only = try self.var_state.d2a_only.getOrPutValue(self.arena, key, true);
            only.value_ptr.* = only.value_ptr.* and in_event == .d2a;
        }
    }
    switch (self.file.stmt(id)) {
        .block => |b| {
            const named = try pushHeldFrame(self, b);
            for (b.body) |s| try scanHeld(self, s, in_event);
            if (named) _ = self.var_state.held_frames.pop();
        },
        // §5.10 forbids nesting, so `true` is never re-entered; lowering
        // diagnoses that (E0703) and this walk does not need to.
        .event_control => |s| try scanHeld(self, s.body, if (s.kind == .event and d2aOnly(self, s.event)) .d2a else .analog),
        // The rest: only their child statements, whose writes the walk collects.
        else => try self.file.stmtEdges(id, Held{ .l = self, .in_event = in_event }), // else: stmtEdges is exhaustive
    }
}

/// Is every term of event expression `e` an explicit D2A event?
fn d2aOnly(self: *const Lower, e: Ast.ExprId) bool {
    assert(e == .none or self.exprValid(e));
    const ex = &self.file.exprs;
    if (e == .none) return false;
    if (ex.tag(e) == .event_or) return d2aOnly(self, ex.lhs(e)) and d2aOnly(self, ex.rhs(e));
    return self.out.discrete_events.contains(e);
}

fn runtimeSub(self: *const Lower, vars: *const std.AutoHashMapUnmanaged(Ast.StrId, void), genvars: []const Ast.StrId, e: Ast.ExprId) bool {
    assert(e == .none or self.exprValid(e));
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            const n = ex.strOf(e);
            if (std.mem.findScalar(Ast.StrId, genvars, n) != null) return false;
            return vars.contains(n) or self.param_index.contains(self.file.str(n));
        },
        .call, .sys_call, .hier_ident, .branch_access, .port_access, .filter_call, .noise_call => return true,
        else => { // else: every other node is runtime exactly when an operand is
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (runtimeSub(self, vars, genvars, c)) return true;
            return false;
        },
    }
}

test "markHeldVars: an array too large to count is judged by its declaration, not by a crash" {
    // The read `x[i]...` makes the walk ask whether every cell is assigned,
    // which counts the cells before `dimsBounds` has refused the shape. The
    // count overflows a 64-bit integer in both declarations; E1016 is the
    // answer either way.
    const decls = [_][]const u8{
        "  real x[0:2000000000][0:2000000000][0:2000000000];\n  integer i;\n  real y;",
        "  real x[-9223372036854775807:9223372036854775807][0:0][0:0];\n  integer i;\n  real y;",
    };
    for (decls) |d| try Lower.expectBodyVerdict(d, "    i = 0;\n    y = x[i][0][0];", .E1016);
}
