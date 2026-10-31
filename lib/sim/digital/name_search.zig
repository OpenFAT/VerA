//! A name or select in the executing scope in, the slot (and select) it names out: §12.5/§12.6 hierarchical names, §12.7 scope search, §4.9 arrays.
//! Cites: IEEE 1364-2005 §4.9, §5.2.1, §12.5, §12.6, §12.7.
//!
//! Contents:
//! - `pub const Hierarchy = struct`
//! - `pub fn slotOf(self: *const Run, name: []const u8) ?u32`
//! - `pub fn slot(self: *Run, e: Ast.ExprId) Error!u32`
//! - `pub fn resolveSlot(self: *Run, e: Ast.ExprId) Error!u32`
//! - `pub fn foldSelects(self: *Run, tok: u32, text: []const u8, indices: []const Ast.ExprId, used: *usize) Error!Ast.StrId`
//! - `pub fn elementScope(self: *Run, tok: u32, base: []const u8, parent: ?u32, indices: []const Ast.ExprId, used: *usize) Error!u32`
//! - `pub fn termSlot(self: *Run, e: Ast.ExprId) Error!u32`
//! - `pub fn slotType(self: *const Run, at: u32) compile.Type`
//! - `pub fn lookupAt(self: *const Run, scope: u32, str: Ast.StrId, tok: u32) ?u32`
//! - `pub fn instanceHides(self: *const Run, scope: u32, str: Ast.StrId, tok: u32) bool`
//! - `pub fn lookup(self: *const Run, scope: u32, str: Ast.StrId) ?u32`
//! - `pub fn specOf(self: *const Run, scope: u32) u32`
//! - `pub fn instanceOf(self: *const Run, scope: u32) u32`
//! - `pub fn vecRange(self: *const Run, at: u32) VecRange`
//! - `pub fn isScalar(self: *const Run, at: u32) bool`
//! - `pub fn baseSlot(self: *Run, e: Ast.ExprId) Error!u32`
//! - `pub fn chainBase(self: *const Run, e: Ast.ExprId) struct { base: Ast.ExprId, depth: u32 }`
//! - `pub fn scalarSlot(self: *Run, e: Ast.ExprId) Error!u32`
//! - `pub fn indexedArray(self: *Run, e: Ast.ExprId) Error!?Array`
//! - `pub fn bind(self: *Run, name: Ast.StrId, at: u32, tok: u32) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const Scheduler = @import("../scheduler.zig").Scheduler;
/// Scheduler ticks. `Time` below is the timescale module, not this.
const Tick = @import("../scheduler.zig").Time;
const Time = @import("../time.zig");
const deep = @import("base").deep_stack;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const display = @import("display.zig");
/// Public for the VPI (src/vpi/value.zig), which writes a value the way a
/// process does (`waiters.store` now, `exec.enqueue` of a `.write` later), so a
/// §12.30 put wakes waiters and value-change watchers like any other write.
const exec = @import("exec.zig");
/// §17 system tasks.
const system = @import("system.zig");
const driver = @import("driver.zig");
const binding = @import("bind.zig");
const elab = @import("elab.zig");
const waiters = @import("waiters.zig");
const resolution = @import("resolution.zig");
const tchk = @import("tchk.zig");
const vpi = @import("vpi.zig");
const Type = compile.Type;
const Instruction = compile.Instruction;
const Row = exec.Row;
const Delay = @import("net.zig").Delay;
const Net = @import("net.zig").Net;
const NetCold = @import("net.zig").NetCold;
const no_cold = @import("net.zig").no_cold;
const Tran = @import("net.zig").Tran;
const Signal = @import("net.zig").Signal;
const Inertial = @import("net.zig").Inertial;
const no_transition = @import("net.zig").no_transition;
const Driver = @import("net.zig").Driver;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const Show = display.Show;
const TimeFormat = display.TimeFormat;
// ---- the public surface -----------------------------------------------------
const root = @import("root.zig");
const Name = root.Name;
const Run = root.Run;
const Error = root.Error;
const Array = root.Array;
const VecRange = root.VecRange;
const memo_bits = root.memo_bits;
/// The descriptor table a `Run` with no `file_io` opens files through.
const own_files = system.own;

/// A design's elaborated hierarchy: the scope tree (row 0 the first root),
/// every name bound in each scope, the instances, primitives and named
/// blocks, and the §13 library binding each instance came from.
pub const Hierarchy = struct {
    /// §6.2.2 names are per INSTANCE, not per module: two instances of one
    /// definition declare the same identifiers over different storage, so the
    /// key is the scope the name was declared in plus the interned name. The
    /// scope in force is `self.scope`, which the executing process carries.
    names: std.AutoHashMapUnmanaged(Name, u32) = .empty,
    /// Each `names` entry's declaration token, for `lookupAt` (by name, not
    /// slot: a port's slot is its connection's, declared in another module).
    bound_at: std.AutoHashMapUnmanaged(Name, u32) = .empty,
    /// IEEE 1364-2005 §26.6.19(e): the lexical scope of an expression a
    /// VPI application may evaluate later, keyed by (instance, expression).
    /// Populated only for a host with `systf`; obtaining an argument handle
    /// does not evaluate its expression.
    vpi_expr_scopes: std.AutoHashMapUnmanaged([2]u32, u32) = .empty,
    /// The highest scope id handed out; the root is 0.
    scope_count: u32 = 0,
    /// Per scope id: the instance that minted it, its name and its module
    /// (§17.1.1.6's `%m` path and §13.6's `%l` binding). Row 0 is the root,
    /// named after its module.
    /// `lexical` marks a scope nested inside its parent's module, a task or
    /// function (§12.7), whose unresolved names are searched for in the
    /// parent; an instance is a hierarchy boundary and is searched no further.
    /// `index` marks one iteration of a §12.4.1 loop generate, the `[i]` of
    /// its block name; `implicit`, one whose block is unnamed (§12.4.3's
    /// `genblk<n>`, IEEE 1364-2005 §26.6.44's vpiImplicitDecl).
    scopes: std.ArrayList(struct { parent: u32, name: Ast.StrId, def: u32, lexical: bool = false, index: ?i64 = null, implicit: bool = false }) = .empty,
    /// IEEE 1364-2005 §13.2.3 per `file.modules` row, the library its source
    /// file maps into; per `file.configs` row, the same.
    def_lib: []const Ast.StrId = &.{},
    cfg_lib: []const Ast.StrId = &.{},
    /// §13.5.1/§13.7.1 the library search order with no configuration.
    search: []const Ast.StrId = &.{},
    /// Per instance scope, the §13.3 state its children bind under.
    binds: std.AutoHashMapUnmanaged(u32, binding.Ctx) = .empty,
    /// The top-level modules' scopes (`isRoot`), 0 first.
    roots: []const u32 = &.{0},
    /// The token each scope after the root was made at (`elab.newScope`),
    /// which orders a scope's children as the source does (`processOrder`).
    scope_toks: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// §12.4 one instance NAME, keyed by the scope that instantiated it, to the
    /// scope it minted. `names` cannot carry this: an instance is not storage,
    /// and a downward hierarchical reference walks these before it reaches a
    /// slot at all.
    instances: std.AutoHashMapUnmanaged(Name, u32) = .empty,
    /// IEEE 1364-2005 §12.7 the gate, switch and UDP instance names of each
    /// scope, each to its token: no storage, but declared there, so they hide
    /// an outer name of the same spelling from `lookupAt`, `upward` and a call
    /// (iverilog refuses the hidden use the same way); `lookupAt` from the
    /// instance on, a call and `upward` wherever it is.
    prim_names: std.AutoHashMapUnmanaged(Name, u32) = .empty,
    /// §12.5 the scope of each named block that declares something, keyed by
    /// the scope it runs in and its statement (`blockScope`).
    block_scopes: std.AutoHashMapUnmanaged(struct { scope: u32, stmt: Ast.StmtId }, u32) = .empty,
};

/// The slot a name is stored in, or null when the design declares no such
/// variable or net. `name` is a root-scope name or a §6.7 downward path
/// (`u.v.q`: every part but the last an instance), which is the spelling
/// an analog compile's flatten gives a child's name (`elaborate.sep`).
/// `values[slot]` is its current value; this is how a caller outside the
/// engine reads one.
pub fn slotOf(self: *const Run, name: []const u8) ?u32 {
    var scope: u32 = 0;
    var parts = std.mem.splitScalar(u8, name, '.');
    var part = parts.first();
    while (parts.next()) |next| : (part = next) {
        const inst = self.file.strings.find(part) orelse return null;
        scope = self.hier.instances.get(.{ .scope = scope, .str = inst }) orelse return null;
    }
    const str = self.file.strings.find(part) orelse return null;
    return self.hier.names.get(.{ .scope = scope, .str = str });
}

/// §12.5 a hierarchical reference: the first part is a scope `upward`
/// finds, every later part but the last names an instance declared in
/// the scope before it, and the last is a declared name in the scope the
/// final instance minted.
pub fn slot(self: *Run, e: Ast.ExprId) Error!u32 {
    assert(e != .none);
    if (self.slot_memo.len == 0) return self.resolveSlot(e);
    const key = @backingInt(e) *% 0x9e3779b1 ^ self.scope *% 0x85ebca6b;
    const m = &self.slot_memo[key >> (32 - memo_bits)];
    if (m.scope == self.scope and m.e == e) return m.at;
    const at = try self.resolveSlot(e);
    m.* = .{ .scope = self.scope, .e = e, .at = at };
    return at;
}

/// Returns the slot name `e` resolves to in the executing scope, or an E-coded refusal.
pub fn resolveSlot(self: *Run, e: Ast.ExprId) Error!u32 {
    assert(e != .none);
    const ex = &self.file.exprs;
    if (ex.tag(e) == .hier_ident) {
        const parts = ex.nameParts(e);
        var scope: u32 = 0;
        // §12.4.1 a select the parser could not fold (`target[i]`, `i` a
        // genvar) is spelled `name[]`, its index expressions in order.
        const indices = self.file.hierIndices(ex.mainTok(e));
        var used: usize = 0;
        for (parts[0 .. parts.len - 1], 0..) |spelled, k| {
            const text = self.file.str(spelled);
            // One `name[]`: the element's scope row, whether or not the
            // source spells `name[<v>]` anywhere.
            if (std.mem.endsWith(u8, text, "[]") and std.mem.findScalar(u8, text, '[').? == text.len - 2) {
                scope = try self.elementScope(ex.mainTok(e), text[0 .. text.len - 2], if (k == 0) null else scope, indices, &used);
                continue;
            }
            const part = if (std.mem.find(u8, text, "[]") == null) spelled else try self.foldSelects(ex.mainTok(e), text, indices, &used);
            const next = if (k == 0) self.upward(part) else self.hier.instances.get(.{ .scope = scope, .str = part });
            scope = next orelse return if (std.mem.findScalar(u8, self.file.str(part), '[') != null)
                self.fail(self.file.exprs.mainTok(e), "§12.5: `{s}`: an instance select out of range, or of no array", .{self.file.str(part)})
            else if (self.routines.by_name.get(.{ .scope = if (k == 0) self.instanceOf(self.scope) else scope, .str = part })) |idx| if (self.routines.rows.items[idx].decl.automatic)
                self.fail(self.file.exprs.mainTok(e), "§10.2.1: `{s}` is automatic: its items cannot be accessed by hierarchical references", .{self.file.str(part)})
            else
                self.exprFail(e, "undeclared instance in a hierarchical reference") else self.exprFail(e, "undeclared instance in a hierarchical reference");
        }
        return self.hier.names.get(.{ .scope = scope, .str = parts[parts.len - 1] }) orelse
            self.exprFail(e, "undeclared digital variable");
    }
    if (ex.tag(e) != .ident) return self.exprFail(e, "only whole-variable lvalues are implemented");
    return self.lookupAt(self.scope, ex.strOf(e), ex.mainTok(e)) orelse
        if (self.lookup(self.scope, ex.strOf(e)) != null and !self.instanceHides(self.scope, ex.strOf(e), ex.mainTok(e))) self.exprFail(e, "a name is used before its declaration") else self.exprFail(e, "undeclared digital variable");
}

/// `text`, a part of the hierarchical name at token `tok` with `[]`
/// selects, with each one's index from `indices` (from `used` on) folded
/// in this scope: the spelling of an instance or generate block name
/// (`SourceFile.hierIndices`).
pub fn foldSelects(self: *Run, tok: u32, text: []const u8, indices: []const Ast.ExprId, used: *usize) Error!Ast.StrId {
    assert(tok < self.starts.len);
    var out: std.Io.Writer.Allocating = .init(self.arena);
    var rest = text;
    while (std.mem.find(u8, rest, "[]")) |at| {
        if (used.* == indices.len) return self.fail(tok, "§12.5: a hierarchical select has no index", .{});
        const v = (try self.constant(indices[used.*], tok)).asInt() orelse return self.fail(tok, "§12.5: a hierarchical select's index has an x or z bit", .{});
        used.* += 1;
        try out.writer.print("{s}[{d}]", .{ rest[0..at], v });
        rest = rest[at + 2 ..];
    }
    try out.writer.writeAll(rest);
    return self.file.strings.find(out.written()) orelse
        self.fail(tok, "§12.5: `{s}`: an instance select out of range, or of no array", .{out.written()});
}

/// The scope of element `<next index>` of the instance array or loop
/// generate `base` declared in `parent`, or, with no parent (the first
/// part of a §12.5 name), in the nearest scope upward that has one.
pub fn elementScope(self: *Run, tok: u32, base: []const u8, parent: ?u32, indices: []const Ast.ExprId, used: *usize) Error!u32 {
    assert(tok < self.starts.len);
    if (used.* == indices.len) return self.fail(tok, "§12.5: a hierarchical select has no index", .{});
    const v = (try self.constant(indices[used.*], tok)).asInt() orelse return self.fail(tok, "§12.5: a hierarchical select's index has an x or z bit", .{});
    used.* += 1;
    const found: ?u32 = blk: {
        const name = self.file.strings.find(base) orelse break :blk null;
        if (parent) |p| break :blk compile.element(self, p, name, v);
        var s = self.scope;
        while (true) : (s = self.hier.scopes.items[s].parent) {
            if (compile.element(self, s, name, v)) |at| break :blk at;
            if (self.hier.scopes.items[s].parent == s) break :blk null;
        }
    };
    return found orelse self.fail(tok, "§12.5: `{s}[{d}]`: an instance select out of range, or of no array", .{ base, v });
}

/// The slot event term `e` watches: a name's own, or the hidden one a
/// §9.7.2 expression term keeps (`term_slots`).
pub fn termSlot(self: *Run, e: Ast.ExprId) Error!u32 {
    assert(e != .none);
    return self.typing.term_slots.get(.{ .scope = self.scope, .e = e }) orelse self.slot(e);
}

/// The type a slot's value has, for an assignment to it.
pub fn slotType(self: *const Run, at: u32) compile.Type {
    if (self.reals.contains(at)) return compile.real_type;
    return .{ .width = self.values[at].width, .signed = self.values[at].signed };
}

/// §12.7 a name as seen from `scope`: declared there, or in an enclosing
/// scope of the same module, never across an instance boundary.
/// `lookup` from a statement or expression at token `tok`. A name is
/// visible from its declaration on, so one declared after `tok` leaves
/// an outer one in view, or none (iverilog's decl_before_use: 1364
/// states the rule only for specparams, §4.10.3, and events, §9.7.3,
/// and leaves it open elsewhere). A gate, switch or UDP instance named
/// the same hides the outer name from the instance on (iverilog's
/// gate_instance_shadow_fail and gate_instance_reference_order).
pub fn lookupAt(self: *const Run, scope: u32, str: Ast.StrId, tok: u32) ?u32 {
    assert(scope < self.hier.scopes.items.len);
    assert(tok < self.starts.len);
    var s = scope;
    while (true) {
        if (self.hier.names.get(.{ .scope = s, .str = str })) |at| {
            // Elaboration's constant contexts (a range over a parameter
            // declared later, §12.2) see the whole scope.
            if (self.growing != null or (self.hier.bound_at.get(.{ .scope = s, .str = str }) orelse 0) <= tok) return at;
        } else if (self.hier.prim_names.get(.{ .scope = s, .str = str })) |at| if (at <= tok) return null;
        const info = self.hier.scopes.items[s];
        if (!info.lexical) return null;
        s = info.parent;
    }
}

/// Whether `lookupAt` found nothing because a primitive instance of
/// that name, at or before `tok`, hides the outer one.
pub fn instanceHides(self: *const Run, scope: u32, str: Ast.StrId, tok: u32) bool {
    assert(scope < self.hier.scopes.items.len);
    assert(tok < self.starts.len);
    var s = scope;
    while (true) {
        if (self.hier.names.contains(.{ .scope = s, .str = str })) return false;
        if (self.hier.prim_names.get(.{ .scope = s, .str = str })) |at| if (at <= tok) return true;
        const info = self.hier.scopes.items[s];
        if (!info.lexical) return false;
        s = info.parent;
    }
}

/// Returns the slot `str` names in `scope` or a scope around it, or null.
pub fn lookup(self: *const Run, scope: u32, str: Ast.StrId) ?u32 {
    assert(scope < self.hier.scopes.items.len);
    var s = scope;
    while (true) {
        if (self.hier.names.get(.{ .scope = s, .str = str })) |at| return at;
        const info = self.hier.scopes.items[s];
        if (!info.lexical) return null;
        s = info.parent;
    }
}

/// The scope whose parameters decide every type, part-select bound and
/// replication count in `scope`: the nearest instance (§12.2) or §12.4.1
/// loop-generate iteration (its genvar is a local parameter) at or above
/// it. A named block or a task frame declares names from its instance's
/// parameters, so it shares its instance's types.
pub fn specOf(self: *const Run, scope: u32) u32 {
    assert(scope < self.hier.scopes.items.len);
    var s = scope;
    while (s < self.hier.scopes.items.len) {
        const info = self.hier.scopes.items[s];
        if (!info.lexical or info.index != null) break;
        s = info.parent;
    }
    return s;
}

/// The instance a (possibly nested) scope belongs to.
pub fn instanceOf(self: *const Run, scope: u32) u32 {
    assert(scope < self.hier.scopes.items.len);
    var s = scope;
    while (self.hier.scopes.items[s].lexical) s = self.hier.scopes.items[s].parent;
    return s;
}

/// A vector slot's declared `[msb:lsb]` (an array's first element's is
/// every element's), `[w-1:0]` when it declares none.
pub fn vecRange(self: *const Run, at: u32) VecRange {
    return self.typing.vec_ranges.get(at) orelse .{ .msb = @as(i64, self.values[at].width) - 1, .lsb = 0 };
}

/// §4.3: "A net or reg declaration without a range specification shall
/// be considered 1 bit wide and is known as a scalar."
pub fn isScalar(self: *const Run, at: u32) bool {
    return self.values[at].width == 1 and !self.typing.vec_ranges.contains(at) and !self.params.contains(at);
}

/// The slot an lvalue's width comes from: an array element reference is as
/// wide as element zero, so a parked value can be sized before §8.5.3.3
/// resolves which element it lands in.
pub fn baseSlot(self: *Run, e: Ast.ExprId) Error!u32 {
    assert(e != .none);
    const ex = &self.file.exprs;
    return if (ex.tag(e) == .index) self.slot(self.chainBase(e).base) else self.scalarSlot(e);
}

/// The name at the bottom of a stack of selects, `a` in `a[i][j]`, and
/// how many selects stand on it.
pub fn chainBase(self: *const Run, e: Ast.ExprId) struct { base: Ast.ExprId, depth: u32 } {
    assert(e != .none);
    const ex = &self.file.exprs;
    var x = e;
    var depth: u32 = 0;
    while (ex.tag(x) == .index) : (depth += 1) x = ex.lhs(x);
    return .{ .base = x, .depth = depth };
}

/// The slot of a reference to one whole value. §3.9's unpacked array has
/// no value of its own, only its elements do, so a bare array name fails.
pub fn scalarSlot(self: *Run, e: Ast.ExprId) Error!u32 {
    assert(e != .none);
    const at = try self.slot(e);
    if (self.arrays.contains(at)) return self.exprFail(e, "an unpacked array reference requires an element index");
    return at;
}

/// The array an `.index` names an element of (one index per dimension,
/// §4.9), or null when it is a bit or part select.
pub fn indexedArray(self: *Run, e: Ast.ExprId) Error!?Array {
    assert(e != .none);
    const ex = &self.file.exprs;
    if (ex.tag(e) != .index) return null;
    const c = self.chainBase(e);
    if (ex.tag(c.base) != .ident and ex.tag(c.base) != .hier_ident) return null;
    const arr = self.arrays.get(try self.slot(c.base)) orelse return null;
    if (c.depth != 1 + arr.rest.len) return null;
    // IEEE 1364-2005 §5.2.2: "the desired word shall first be selected by
    // supplying an address for each dimension"; a range there would
    // select several elements, which §4.9 never assigns or reads.
    var at = e;
    while (ex.tag(at) == .index) : (at = ex.lhs(at)) switch (ex.tag(ex.rhs(at))) {
        .range, .indexed_range => return self.exprFail(ex.rhs(at), "§5.2.2: each array dimension takes an index, not a part-select"),
        else => {}, // else: an element index
    };
    return arr;
}

/// Binds `name` to slot `at` in the current scope (`scope`). A second
/// declaration of one name in one scope fails at `tok` (E1100).
pub fn bind(self: *Run, name: Ast.StrId, at: u32, tok: u32) Error!void {
    assert(tok < self.starts.len);
    const entry = try self.hier.names.getOrPut(self.arena, .{ .scope = self.scope, .str = name });
    if (entry.found_existing) return self.fail(tok, "duplicate digital variable", .{});
    entry.value_ptr.* = at;
    try self.hier.bound_at.put(self.arena, entry.key_ptr.*, tok);
}
