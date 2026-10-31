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
//! - `pub fn attributes(b: *Builder, at: u32, owner: Ast.AttributeOwner, definition: bool) Error!void`
//! - `pub fn add(b: *Builder, o: Obj) Error!u32`
//! - `pub fn code(b: *Builder, vtype: c_int, edges: []const Edge, lists: []const List, props: []const Prop) Error!u32`
//! - `pub fn setName(b: *Builder, at: u32, local: []const u8) Error!void`
//! - `pub fn enter(b: *Builder, at: u32, local: []const u8, into: *std.ArrayList(u32)) Error!Saved`
//! - `pub fn leave(b: *Builder, s: Saved) void`
//! - `pub fn many(b: *Builder, items: []const u32) Error![]const u32`
//! - `pub fn subFrame(b: *Builder, t: *const Ast.Subroutine) ?sim.digital.Frame`
//! - `pub fn declWidth(b: *Builder, v: Ast.VarDecl, slot: ?u32) c_int`
//! - `pub fn subVar(b: *Builder, vars: *SubVars, v: Ast.VarDecl, slot: ?u32, automatic: bool) Error!u32`
//! - `pub fn subVars(b: *Builder, t: *const Ast.Subroutine) Error!SubVars`
//! - `pub fn lookup(b: *Builder, name: []const u8) u32`
//! - `pub fn lookupAs(b: *Builder, name: []const u8, want: Lookup) u32`
//! - `pub fn constant(b: *Builder, v: ?Const, width: u32, const_type: c_int) Error!u32`
//! - `pub fn operation(b: *Builder, op: c_int, operands: []const Ast.ExprId) Error!u32`

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
names: *std.StringHashMapUnmanaged(u32),

top_name: []const u8,

/// The scope being built, and its §6.7 path relative to the top.
scope: u32,

path: []const u8,
lists: *ScopeLists,

/// IEEE 1364-2005 §26.6.3 the innermost task, function or named block
/// being built (a statement's vpiScope), `none` at module level, and the
/// list its own internal scopes go to. `path` includes it (§12.5).
inner: u32 = schema.no_obj,

internal: ?*std.ArrayList(u32) = null,

/// The analog model's discipline-by-name table and the branch objects,
/// for §11.6.19's accessfunc and §11.6.20's contribution; empty for a
/// digital scope.
analog: ?*const Analog = null,

/// §11.6.14 UDP definition name -> its `vpiUdpDefn` object.
udps: ?*const std.AutoHashMapUnmanaged(Ast.StrId, u32) = null,

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
    branches: std.StringHashMapUnmanaged(u32) = .empty,
    /// Discipline object -> its flow access name, for telling a flow
    /// contribution from a potential one (§3.6.1.2).
    flow_access: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
};

pub const Saved = struct { inner: u32, path: []const u8, internal: ?*std.ArrayList(u32), engine: u32, automatic: bool };
pub const Events = struct { scalars: []const u32, arrays: []const u32 };

const Builder = @This();

const SubVars = struct {
    regs: std.ArrayList(u32) = .empty,
    ints: std.ArrayList(u32) = .empty,
    reals: std.ArrayList(u32) = .empty,
};

const Lookup = enum { any, function, task, scope };

/// IEEE 1364-2005 §26.6.42: the attributes the source binds to `owner`,
/// as vpiAttribute rows of object `at` (attributes.zig `attach`).
pub fn attributes(b: *Builder, at: u32, owner: Ast.AttributeOwner, definition: bool) Error!void {
    return attribute.attach(b, at, owner, definition);
}

pub fn add(b: *Builder, o: Obj) Error!u32 {
    const at: u32 = @intCast(b.objects.hot.items.len);
    try b.objects.append(o);
    return at;
}

/// Appends one `.code` row of `vtype` owned by this scope, its edge, list
/// and prop rows copied into the arena; returns its index. Invalidates
/// pointers into `objects.hot.items`.
pub fn code(b: *Builder, vtype: c_int, edges: []const Edge, lists: []const List, props: []const Prop) Error!u32 {
    return b.add(.{
        .kind = .code,
        .owner = .of(b.scope),
        .name = "",
        .full = "",
        .vtype = vtype,
        .edges = try b.arena.dupe(Edge, edges),
        .lists = try b.arena.dupe(List, lists),
        .props = try b.arena.dupe(Prop, props),
    });
}

/// Give object `at` the local name `local` and a full name under this
/// scope, and make the full name resolvable.
pub fn setName(b: *Builder, at: u32, local: []const u8) Error!void {
    const f = try b.full(local);
    b.objects.hot.items[at].name = local;
    b.objects.hot.items[at].full = f;
    try b.names.put(b.gpa, f, at);
}

/// Enters object `at`, already named `local` in the current scope, as a
/// scope of its own (IEEE 1364-2005 §12.5: "Each ... task, function, named
/// begin-end or fork-join block defines a new hierarchical level"), with
/// `into` collecting its internal scopes. `leave` restores the outer one.
pub fn enter(b: *Builder, at: u32, local: []const u8, into: *std.ArrayList(u32)) Error!Saved {
    try (b.internal orelse &b.lists.internal).append(b.gpa, at);
    const saved: Saved = .{ .inner = b.inner, .path = b.path, .internal = b.internal, .engine = b.engine, .automatic = b.automatic };
    b.inner = at;
    b.path = if (b.path.len == 0) local else try b.arena.print("{s}.{s}", .{ b.path, local });
    b.internal = into;
    return saved;
}

pub fn leave(b: *Builder, s: Saved) void {
    b.inner = s.inner;
    b.path = s.path;
    b.internal = s.internal;
    b.engine = s.engine;
    b.automatic = s.automatic;
}

pub fn many(b: *Builder, items: []const u32) Error![]const u32 {
    var n: usize = 0;
    for (items) |i| n += @intFromBool(i != schema.no_obj);
    const out = try b.arena.alloc(u32, n);
    n = 0;
    for (items) |i| if (i != schema.no_obj) {
        out[n] = i;
        n += 1;
    };
    return out;
}

/// The engine's elaborated frame supplies widths even for automatic
/// declarations; only static variables expose those slots as values.
pub fn subFrame(b: *Builder, t: *const Ast.Subroutine) ?sim.digital.Frame {
    const r = b.run orelse return null;
    const i = r.routines.by_name.get(.{ .scope = b.engine, .str = t.name }) orelse return null;
    const sub = r.routines.rows.items[i];
    return if (sub.framed) sub.frame else null;
}

pub fn declWidth(b: *Builder, v: Ast.VarDecl, slot: ?u32) c_int {
    if (slot) |at| return @intCast(b.run.?.values[at].width);
    return code_tables.packedWidth(b.file, v);
}

/// IEEE 1364-2005 §26.6.3/§26.6.18: one formal, local or implicit
/// result variable in the entered subroutine scope. Register its name
/// before building expressions that reference it.
pub fn subVar(b: *Builder, vars: *SubVars, v: Ast.VarDecl, slot: ?u32, automatic: bool) Error!u32 {
    const kind = subVarKind(v) orelse return schema.no_obj;
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
    return at;
}

/// `t`'s subroutine variables, each list sized to what `subVar` will
/// append to it.
pub fn subVars(b: *Builder, t: *const Ast.Subroutine) Error!SubVars {
    var n: [3]usize = .{ 0, 0, 0 };
    const tally = struct {
        fn one(counts: *[3]usize, v: Ast.VarDecl) void {
            const kind = subVarKind(v) orelse return;
            counts[if (kind == .reg) 0 else if (kind == .real_var) 2 else 1] += 1;
        }
    }.one;
    if (t.is_function) tally(&n, t.result);
    for (t.ports) |p| tally(&n, p.v);
    for (t.vars) |v| tally(&n, v);
    return .{
        .regs = try .initCapacity(b.arena, n[0]),
        .ints = try .initCapacity(b.arena, n[1]),
        .reals = try .initCapacity(b.arena, n[2]),
    };
}

/// The object a name denotes from this scope: §6.7's upward search over
/// the full names, innermost first.
pub fn lookup(b: *Builder, name: []const u8) u32 {
    return b.lookupAs(name, .any);
}

/// §26.6.18's implicit result variable shares the function's name.
/// Expression identifiers find that variable, but a recursive call
/// must continue outward to the function declaration. Task enables and
/// disables likewise request declarations rather than local variables.
pub fn lookupAs(b: *Builder, name: []const u8, want: Lookup) u32 {
    var path = b.path;
    while (true) {
        var buf: [schema.name_buf_len]u8 = undefined;
        const full_name = if (path.len == 0)
            std.mem.print(&buf, "{s}.{s}", .{ b.top_name, name }) catch return schema.no_obj
        else
            std.mem.print(&buf, "{s}.{s}.{s}", .{ b.top_name, path, name }) catch return schema.no_obj;
        if (b.names.get(full_name)) |at| {
            const o = b.objects.hot.items[at];
            const matches = switch (want) {
                .any => true,
                .function => o.kind == .code and o.vtype == user.vpiFunction,
                .task => o.kind == .code and o.vtype == user.vpiTask,
                .scope => o.kind == .code and (o.vtype == user.vpiTask or o.vtype == user.vpiFunction or o.vtype == user.vpiNamedBegin or o.vtype == user.vpiNamedFork),
            };
            if (matches) return at;
        }
        if (path.len == 0) return schema.no_obj;
        path = path[0 .. std.mem.findScalarLast(u8, path, '.') orelse 0];
    }
}

pub fn constant(b: *Builder, v: ?Const, width: u32, const_type: c_int) Error!u32 {
    return b.add(.{ .kind = .constant, .owner = .none, .name = "", .full = "", .size = width, .value = v, .const_type = const_type });
}

/// §11.6.19 a vpiOperation of type `op` over `operands`, each built as an
/// expression first; in no scope, as every expression is. Invalidates
/// pointers into `objects.hot.items`.
pub fn operation(b: *Builder, op: c_int, operands: []const Ast.ExprId) Error!u32 {
    const items = try b.arena.alloc(u32, operands.len);
    for (operands, items) |o, *item| item.* = try b.expr(o);
    const at = try b.code(user.vpiOperation, &.{}, &.{.{ .tag = user.vpiOperand, .items = try b.many(items) }}, &.{.{ .prop = user.vpiOpType, .value = op }});
    b.objects.hot.items[at].owner = .none;
    return at;
}

// ---- private ----

fn full(b: *Builder, local: []const u8) Error![]const u8 {
    const rel = if (b.path.len == 0) try b.arena.dupe(u8, local) else try b.arena.print("{s}.{s}", .{ b.path, local });
    return b.arena.print("{s}.{s}", .{ b.top_name, rel });
}

/// The object class `subVar` gives `v`, or null for none.
///
/// ponytail: subroutine arrays and time variables still have no
/// object here; the latter needs the model's vpiTimeVar class.
fn subVarKind(v: Ast.VarDecl) ?@FieldType(Obj, "kind") {
    if (v.dims.len != 0 or v.storage == .time) return null;
    return if (v.ty == .real) .real_var else if (v.storage == .reg) .reg else .integer;
}
