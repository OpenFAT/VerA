//! One scope's worth of behavioural-row building: where new `.code` rows
//! go, how a name in this scope resolves (§6.7's upward search), and the
//! path new named objects hang under. The transformations over it live in
//! code_module.zig (module items), code_stmt.zig (statements) and
//! code_expr.zig (expressions); this file holds the state and the helpers
//! they share.
//! Cites: VAMS-2023 §6.7, §11.6.3, §11.6.19; IEEE 1364-2005 §12.5, §26.6.3,
//! §26.6.18.
//!
//! Contents:
//! - `pub const eventDecls = code_module.eventDecls`
//! - `pub const module = code_module.module`
//! - `pub const reserveModule = code_module.reserveModule`
//! - `pub const analogBlocks = code_module.analogBlocks`
//! - `pub const primitive = code_module.primitive`
//! - `pub const subIndex = code_module.subIndex`
//! - `pub const modPath = code_module.modPath`
//! - `pub const timingCheck = code_module.timingCheck`
//! - `pub const term = code_module.term`
//! - `pub const delayListExpr = code_module.delayListExpr`
//! - `pub const foldAll = code_module.foldAll`
//! - `pub const delayExpr = code_module.delayExpr`
//! - `pub const delays = code_module.delays`
//! - `pub const stmt = code_stmt.stmt`
//! - `pub const stmtObj = code_stmt.stmtObj`
//! - `pub const contrib = code_stmt.contrib`
//! - `pub const expr = code_expr.expr`
//! - `pub const exprObj = code_expr.exprObj`
//! - `pub const select = code_expr.select`
//! - `pub const eventIndexValue = code_expr.eventIndexValue`
//! - `pub const Analog = struct`
//! - `pub const Saved = struct`
//! - `pub const Events = struct`
//! - `pub fn attributes(b: *Builder, at: ObjId, owner: Ast.AttributeOwner, definition: bool) Error!void`
//! - `pub fn add(b: *Builder, o: Obj) Error!ObjId`
//! - `pub fn code(b: *Builder, vtype: c_int, edges: []const Edge, lists: []const List, props: []const Prop) Error!ObjId`
//! - `pub fn setName(b: *Builder, at: ObjId, local: []const u8) Error!void`
//! - `pub fn enter(b: *Builder, at: ObjId, local: []const u8, into: *std.ArrayList(ObjId)) Error!Saved`
//! - `pub fn leave(b: *Builder, s: Saved) void`
//! - `pub fn many(b: *Builder, items: []const ObjId) Error![]const ObjId`
//! - `pub fn subFrame(b: *Builder, t: *const Ast.Subroutine) ?sim.digital.Frame`
//! - `pub fn declWidth(b: *Builder, v: Ast.VarDecl, slot: ?u32) c_int`
//! - `pub fn subVar(b: *Builder, vars: *SubVars, v: Ast.VarDecl, slot: ?u32, automatic: bool) Error!ObjId`
//! - `pub fn subVars(b: *Builder, t: *const Ast.Subroutine) Error!SubVars`
//! - `pub fn lookup(b: *Builder, name: []const u8) ObjId`
//! - `pub fn lookupAs(b: *Builder, name: []const u8, want: Lookup) ObjId`
//! - `pub fn constant(b: *Builder, v: ?Const, width: u32, const_type: c_int) Error!ObjId`
//! - `pub fn operation(b: *Builder, op: c_int, operands: []const Ast.ExprId) Error!ObjId`

const std = @import("std");
const Ast = @import("frontend").Ast;
const Lower = @import("ir").Lowered;
const Lowered = @import("ir").Lowered;
const sim = @import("sim");
const Const = Lower.Const;
const attribute = @import("attribute.zig");
const code_expr = @import("code_expr.zig");
const code_module = @import("code_module.zig");
const code_stmt = @import("code_stmt.zig");
const code_tables = @import("code_tables.zig");
const schema = @import("schema.zig");
const ObjId = schema.ObjId;
const user = @import("vpi_user.zig");
const model = @import("model.zig");
const session = @import("session.zig");
const ByOwner = attribute.ByOwner;
const Edge = schema.Edge;
const Error = session.Error;
const List = schema.List;
const Obj = schema.Obj;
const Prop = schema.Prop;
const Rows = model.Rows;
const ScopeLists = code_tables.ScopeLists;

gpa: std.mem.Allocator,
arena: std.mem.Allocator,
objects: *Rows,
file: *const Ast.SourceFile,

/// §6.7 full name -> object index, for every object that has a name.
/// Named objects this builder makes (events, tasks, named blocks) are
/// added as they are made, so a later statement finds them.
names: *std.StringHashMapUnmanaged(ObjId),

top_name: []const u8,

/// The scope being built, and its §6.7 path relative to the top.
scope: u32,

path: []const u8,
lists: *ScopeLists,

/// IEEE 1364-2005 §26.6.3 the innermost task, function or named block
/// being built (a statement's vpiScope), `none` at module level, and the
/// list its own internal scopes go to. `path` includes it (§12.5).
inner: ObjId = .none,

internal: ?*std.ArrayList(ObjId) = null,

/// The analog model's discipline-by-name table and the branch objects,
/// for §11.6.19's accessfunc and §11.6.20's contribution; empty for a
/// digital scope.
analog: ?*const Analog = null,

/// §11.6.14 UDP definition name -> its `vpiUdpDefn` object.
udps: ?*const std.AutoHashMapUnmanaged(Ast.StrId, ObjId) = null,

/// A digital model's engine run and the instance scope in it, where a
/// static subroutine's variables have their slots.
run: ?*sim.digital.Run = null,

engine: u32 = 0,
automatic: bool = false,

/// `file`'s attribute bindings by owner, built once per model.
attrs: *const ByOwner,

pub const eventDecls = code_module.eventDecls;
pub const module = code_module.module;
pub const reserveModule = code_module.reserveModule;
pub const analogBlocks = code_module.analogBlocks;
pub const primitive = code_module.primitive;
pub const subIndex = code_module.subIndex;
pub const modPath = code_module.modPath;
pub const timingCheck = code_module.timingCheck;
pub const term = code_module.term;
pub const delayListExpr = code_module.delayListExpr;
pub const foldAll = code_module.foldAll;
pub const delayExpr = code_module.delayExpr;
pub const delays = code_module.delays;
pub const stmt = code_stmt.stmt;
pub const stmtObj = code_stmt.stmtObj;
pub const contrib = code_stmt.contrib;
pub const expr = code_expr.expr;
pub const exprObj = code_expr.exprObj;
pub const select = code_expr.select;
pub const eventIndexValue = code_expr.eventIndexValue;

/// The analog model's lookups, built once per design by model_analog.zig
/// and shared by every scope's builder. Owned by that caller (`gpa`).
pub const Analog = struct {
    /// Final analog parameter types used by constant attribute values.
    lowered: ?*const @import("ir").Lowered = null,
    /// Flat branch name -> branch object.
    branches: std.StringHashMapUnmanaged(ObjId) = .empty,
    /// Discipline object -> its flow access name, for telling a flow
    /// contribution from a potential one (§3.6.1.2).
    flow_access: std.AutoHashMapUnmanaged(ObjId, []const u8) = .empty,
};

pub const Saved = struct { inner: ObjId, path: []const u8, internal: ?*std.ArrayList(ObjId), engine: u32, automatic: bool };
pub const Events = struct { scalars: []const ObjId, arrays: []const ObjId };

const Builder = @This();

const SubVars = struct {
    regs: std.ArrayList(ObjId) = .empty,
    ints: std.ArrayList(ObjId) = .empty,
    reals: std.ArrayList(ObjId) = .empty,
};

const Lookup = enum { any, function, task, scope };

/// IEEE 1364-2005 §26.6.42: the attributes the source binds to `owner`,
/// as vpiAttribute rows of object `at` (attributes.zig `attach`). Asserts
/// that `at` is `none` or a row that exists, and that attaching only
/// appends rows.
pub fn attributes(b: *Builder, at: ObjId, owner: Ast.AttributeOwner, definition: bool) Error!void {
    std.debug.assert(at == ObjId.none or at.index() < b.objects.hot.items.len);
    const before = b.objects.hot.items.len;
    try attribute.attach(b, at, owner, definition);
    std.debug.assert(b.objects.hot.items.len >= before);
}

/// Appends row `o`; returns its id. Asserts that `o`'s owner, when it has
/// one, is a row already made, and that `o` is the one row appended.
pub fn add(b: *Builder, o: Obj) Error!ObjId {
    const at = b.objects.next();
    std.debug.assert(o.owner == ObjId.none or o.owner.index() < at.index());
    try b.objects.append(o);
    std.debug.assert(b.objects.next().index() == at.index() + 1);
    return at;
}

/// Appends one `.code` row of `vtype` owned by this scope, its edge, list
/// and prop rows copied into the arena; returns its index. Invalidates
/// pointers into `objects.hot.items`. Asserts that `vtype` is an object type
/// and that the row made is a `.code` row of it.
pub fn code(b: *Builder, vtype: c_int, edges: []const Edge, lists: []const List, props: []const Prop) Error!ObjId {
    std.debug.assert(vtype > 0);
    const at = try b.add(.{
        .kind = .code,
        .owner = .of(b.scope),
        .name = "",
        .full = "",
        .vtype = vtype,
        .edges = try b.arena.dupe(Edge, edges),
        .lists = try b.arena.dupe(List, lists),
        .props = try b.arena.dupe(Prop, props),
    });
    std.debug.assert(b.objects.at(at).vtype == vtype);
    return at;
}

/// Give object `at` the local name `local` and a full name under this
/// scope, and make the full name resolvable. Asserts that `local` is a
/// name, and that the full name now resolves to `at`.
pub fn setName(b: *Builder, at: ObjId, local: []const u8) Error!void {
    std.debug.assert(local.len != 0);
    const f = try b.full(local);
    b.objects.at(at).name = local;
    b.objects.at(at).full = f;
    try b.names.put(b.gpa, f, at);
    std.debug.assert(b.names.get(f).? == at);
}

/// Enters object `at`, already named `local` in the current scope, as a
/// scope of its own (IEEE 1364-2005 §12.5: "Each ... task, function, named
/// begin-end or fork-join block defines a new hierarchical level"), with
/// `into` collecting its internal scopes. `leave` restores the outer one.
/// Asserts that `at` is a named row, and that the path grew by `local`.
pub fn enter(b: *Builder, at: ObjId, local: []const u8, into: *std.ArrayList(ObjId)) Error!Saved {
    std.debug.assert(local.len != 0);
    std.debug.assert(std.mem.eql(u8, b.objects.at(at).name, local));
    try (b.internal orelse &b.lists.internal).append(b.gpa, at);
    const saved: Saved = .{ .inner = b.inner, .path = b.path, .internal = b.internal, .engine = b.engine, .automatic = b.automatic };
    b.inner = at;
    b.path = if (b.path.len == 0) local else try b.arena.print("{s}.{s}", .{ b.path, local });
    b.internal = into;
    std.debug.assert(std.mem.endsWith(u8, b.path, local));
    return saved;
}

/// Leaves the scope `enter` saved `s` for. Asserts that the outer path is
/// a prefix of the inner one, and that the outer scope is back.
pub fn leave(b: *Builder, s: Saved) void {
    std.debug.assert(std.mem.startsWith(u8, b.path, s.path));
    b.inner = s.inner;
    b.path = s.path;
    b.internal = s.internal;
    b.engine = s.engine;
    b.automatic = s.automatic;
    std.debug.assert(b.inner == s.inner);
}

/// `items` without its `none` entries, in order, in the arena. Asserts that
/// each entry is `none` or a row that exists, and that only the `none`
/// entries are dropped.
pub fn many(b: *Builder, items: []const ObjId) Error![]const ObjId {
    var n: usize = 0;
    for (items) |i| {
        std.debug.assert(i == ObjId.none or i.index() < b.objects.hot.items.len);
        n += @intFromBool(i != ObjId.none);
    }
    const out = try b.arena.alloc(ObjId, n);
    n = 0;
    for (items) |i| if (i != ObjId.none) {
        out[n] = i;
        n += 1;
    };
    std.debug.assert(n == out.len);
    return out;
}

/// The engine's elaborated frame supplies widths even for automatic
/// declarations; only static variables expose those slots as values.
/// Asserts that this builder's engine scope and the routine found are the
/// run's.
pub fn subFrame(b: *Builder, t: *const Ast.Subroutine) ?sim.digital.Frame {
    const r = b.run orelse return null;
    std.debug.assert(b.engine < r.hier.scopes.items.len);
    const i = r.routines.by_name.get(.{ .scope = b.engine, .str = t.name }) orelse return null;
    std.debug.assert(i < r.routines.rows.items.len);
    const sub = r.routines.rows.items[i];
    return if (sub.framed) sub.frame else null;
}

/// `v`'s width: its engine slot's when it has one, else as declared.
/// Asserts that a slot is one of the run's, and that a width is positive
/// or vpiUndefined.
pub fn declWidth(b: *Builder, v: Ast.VarDecl, slot: ?u32) c_int {
    const w: c_int = if (slot) |at| blk: {
        std.debug.assert(at < b.run.?.values.len);
        break :blk @intCast(b.run.?.values[at].width);
    } else code_tables.packedWidth(b.file, v);
    std.debug.assert(w > 0 or w == user.vpiUndefined);
    return w;
}

/// IEEE 1364-2005 §26.6.3/§26.6.18: one formal, local or implicit
/// result variable in the entered subroutine scope. Register its name
/// before building expressions that reference it. Asserts that a
/// subroutine scope is entered, and that the variable resolves by name.
pub fn subVar(b: *Builder, vars: *SubVars, v: Ast.VarDecl, slot: ?u32, automatic: bool) Error!ObjId {
    std.debug.assert(b.inner != ObjId.none);
    const kind = subVarKind(v) orelse return ObjId.none;
    const at = try b.add(.{
        .kind = kind,
        .owner = .of(b.scope),
        .name = "",
        .full = "",
        .size = std.math.cast(u32, b.declWidth(v, slot)) orelse 0,
        .is_signed = v.is_signed,
        .automatic = automatic,
        .slot = .of(if (automatic) null else slot),
        .src_tok = v.main_tok,
        .edges = try b.arena.dupe(Edge, &.{.{ .tag = user.vpiScope, .to = b.inner }}),
    });
    try b.setName(at, try b.arena.dupe(u8, b.file.str(v.name)));
    try b.attributes(at, .{ .kind = .declaration, .tok = v.main_tok }, false);
    (if (kind == .reg) &vars.regs else if (kind == .real_var) &vars.reals else &vars.ints).appendAssumeCapacity(at);
    std.debug.assert(b.objects.at(at).kind == kind);
    return at;
}

/// `t`'s subroutine variables, each list sized to what `subVar` will
/// append to it. Asserts that no more variables are counted than `t`
/// declares.
pub fn subVars(b: *Builder, t: *const Ast.Subroutine) Error!SubVars {
    var n: [3]usize = .{ 0, 0, 0 };
    if (t.is_function) tally(&n, t.result);
    for (t.ports) |p| tally(&n, p.v);
    for (t.vars) |v| tally(&n, v);
    std.debug.assert(n[0] + n[1] + n[2] <= @intFromBool(t.is_function) + t.ports.len + t.vars.len);
    const out: SubVars = .{
        .regs = try .initCapacity(b.arena, n[0]),
        .ints = try .initCapacity(b.arena, n[1]),
        .reals = try .initCapacity(b.arena, n[2]),
    };
    std.debug.assert(out.regs.items.len == 0 and out.ints.items.len == 0 and out.reals.items.len == 0);
    return out;
}

/// The object a name denotes from this scope: §6.7's upward search over
/// the full names, innermost first. Asserts that `name` is a name and the
/// answer is `none` or a row that exists.
pub fn lookup(b: *Builder, name: []const u8) ObjId {
    std.debug.assert(name.len != 0);
    const at = b.lookupAs(name, .any);
    std.debug.assert(at == ObjId.none or at.index() < b.objects.hot.items.len);
    return at;
}

/// §26.6.18's implicit result variable shares the function's name.
/// Expression identifiers find that variable, but a recursive call
/// must continue outward to the function declaration. Task enables and
/// disables likewise request declarations rather than local variables.
/// Asserts that the search climbs at most one level per path component.
pub fn lookupAs(b: *Builder, name: []const u8, want: Lookup) ObjId {
    var path = b.path;
    // The scope itself, then one level per '.' of its path, then the top.
    const levels = std.mem.count(u8, b.path, ".") + 2;
    var level: usize = 0;
    while (true) : (level += 1) {
        std.debug.assert(level < levels);
        var buf: [schema.name_buf_len]u8 = undefined;
        const full_name = if (path.len == 0)
            std.mem.print(&buf, "{s}.{s}", .{ b.top_name, name }) catch return ObjId.none
        else
            std.mem.print(&buf, "{s}.{s}.{s}", .{ b.top_name, path, name }) catch return ObjId.none;
        if (b.names.get(full_name)) |at| {
            const o = b.objects.at(at);
            const matches = switch (want) {
                .any => true,
                .function => o.kind == .code and o.vtype == user.vpiFunction,
                .task => o.kind == .code and o.vtype == user.vpiTask,
                .scope => o.kind == .code and (o.vtype == user.vpiTask or o.vtype == user.vpiFunction or o.vtype == user.vpiNamedBegin or o.vtype == user.vpiNamedFork),
            };
            if (matches) return at;
        }
        if (path.len == 0) return ObjId.none;
        const up = path[0 .. std.mem.findScalarLast(u8, path, '.') orelse 0];
        std.debug.assert(up.len < path.len);
        path = up;
    }
}

/// A constant row of `width` bits holding `v` (null: a value this model
/// does not carry), of vpiConstType `const_type`. Asserts that the type is
/// a code (0 for none) and that the row made is a constant.
pub fn constant(b: *Builder, v: ?Const, width: u32, const_type: c_int) Error!ObjId {
    std.debug.assert(const_type >= 0);
    const at = try b.add(.{ .kind = .constant, .owner = .none, .name = "", .full = "", .size = width, .value = v, .const_type = const_type });
    std.debug.assert(b.objects.at(at).kind == .constant);
    return at;
}

/// §11.6.19 a vpiOperation of type `op` over `operands`, each built as an
/// expression first; in no scope, as every expression is. Invalidates
/// pointers into `objects.hot.items`. Asserts that `op` is an operator code
/// and that the operation has no more operands than were given.
pub fn operation(b: *Builder, op: c_int, operands: []const Ast.ExprId) Error!ObjId {
    std.debug.assert(op > 0);
    const items = try b.arena.alloc(ObjId, operands.len);
    for (operands, items) |o, *item| item.* = try b.expr(o);
    const at = try b.code(user.vpiOperation, &.{}, &.{.{ .tag = user.vpiOperand, .items = try b.many(items) }}, &.{.{ .prop = user.vpiOpType, .value = op }});
    b.objects.at(at).owner = .none;
    std.debug.assert(b.objects.at(at).lists[0].items.len <= operands.len);
    return at;
}

// ---- private ----

/// `local`'s §6.7 full name under this scope. Asserts that `local` is a
/// name and the full name ends in it, past the top's name.
fn full(b: *Builder, local: []const u8) Error![]const u8 {
    std.debug.assert(local.len != 0);
    const rel = if (b.path.len == 0) try b.arena.dupe(u8, local) else try b.arena.print("{s}.{s}", .{ b.path, local });
    const f = try b.arena.print("{s}.{s}", .{ b.top_name, rel });
    std.debug.assert(f.len > b.top_name.len + local.len);
    return f;
}

/// Counts `v` into `counts` by the list `subVar` appends it to: regs,
/// integers, reals. Asserts that it counts it at most once.
fn tally(counts: *[3]usize, v: Ast.VarDecl) void {
    const before = counts[0] + counts[1] + counts[2];
    defer std.debug.assert(counts[0] + counts[1] + counts[2] <= before + 1);
    const kind = subVarKind(v) orelse return;
    std.debug.assert(kind == .reg or kind == .real_var or kind == .integer);
    counts[if (kind == .reg) 0 else if (kind == .real_var) 2 else 1] += 1;
}

/// The object class `subVar` gives `v`, or null for none. Asserts that a
/// class is given only to a scalar non-time declaration, and that it is a
/// variable class.
///
/// ponytail: subroutine arrays and time variables still have no
/// object here; the latter needs the model's vpiTimeVar class.
fn subVarKind(v: Ast.VarDecl) ?@FieldType(Obj, "kind") {
    if (v.dims.len != 0 or v.storage == .time) return null;
    const kind: @FieldType(Obj, "kind") = if (v.ty == .real) .real_var else if (v.storage == .reg) .reg else .integer;
    std.debug.assert(v.dims.len == 0);
    std.debug.assert(kind != .time_var);
    return kind;
}
