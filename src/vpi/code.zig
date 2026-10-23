//! The behavioural VPI objects (§11.6.3, §11.6.10, §11.6.13-§11.6.24): source
//! AST -> `.code` rows in root.zig's fixed object array. Every row is typed
//! by `vtype` (Annex G) and carries its diagram as data: `edges` (single
//! arrows), `lists` (double arrows), `props`. A tag the builder did not write
//! is an error; an edge written as `none` answers NULL with no error
//! (§11.5.3). The routines over these rows that are not traversal live
//! beside it: delays.zig (§12.11, §12.29) and decompile.zig (vpiDecompile).

const std = @import("std");
const Ast = @import("frontend").Ast;
const sim = @import("sim");
const root = @import("root.zig");
const model = @import("model.zig");

const Obj = root.Obj;
/// An edge written to nothing: vpi_handle answers NULL with no error.
pub const none = root.no_obj;

// Annex G object types (IEEE 1364-2005, which §12.2 and §12.31 defer to).
pub const vpiAlways: c_int = 1;
pub const vpiAssignStmt: c_int = 2;
pub const vpiAssignment: c_int = 3;
pub const vpiBegin: c_int = 4;
pub const vpiCase: c_int = 5;
pub const vpiCaseItem: c_int = 6;
pub const vpiContAssign: c_int = 8;
pub const vpiDeassign: c_int = 9;
pub const vpiDelayControl: c_int = 11;
pub const vpiDisable: c_int = 12;
pub const vpiEventControl: c_int = 13;
pub const vpiEventStmt: c_int = 14;
pub const vpiFor: c_int = 15;
pub const vpiForce: c_int = 16;
pub const vpiForever: c_int = 17;
pub const vpiFork: c_int = 18;
pub const vpiFuncCall: c_int = 19;
pub const vpiFunction: c_int = 20;
pub const vpiIf: c_int = 22;
pub const vpiIfElse: c_int = 23;
pub const vpiInitial: c_int = 24;
pub const vpiAttribute: c_int = 105;
pub const vpiDefAttribute: c_int = 55;
pub const vpiIODecl: c_int = 28;
pub const vpiNamedBegin: c_int = 33;
pub const vpiNamedEvent: c_int = 34;
pub const vpiNamedEventArray: c_int = 129;
pub const vpiNamedFork: c_int = 35;
pub const vpiNetBit: c_int = 37;
pub const vpiNullStmt: c_int = 38;
pub const vpiOperation: c_int = 39;
pub const vpiPartSelect: c_int = 42;
/// IEEE 1364-2005 §26.6.26 (Annex G).
pub const vpiIndexedPartSelect: c_int = 130;
pub const vpiRegBit: c_int = 49;
pub const vpiRelease: c_int = 50;
pub const vpiRepeat: c_int = 51;
pub const vpiRepeatControl: c_int = 52;
pub const vpiSysFuncCall: c_int = 56;
pub const vpiSysTaskCall: c_int = 57;
pub const vpiTask: c_int = 59;
pub const vpiTaskCall: c_int = 60;
pub const vpiWait: c_int = 69;
pub const vpiWhile: c_int = 70;
pub const vpiParamAssign: c_int = 40;
pub const vpiGate: c_int = 21;
pub const vpiPrimTerm: c_int = 46;
pub const vpiTableEntry: c_int = 58;
pub const vpiUdp: c_int = 65;
pub const vpiUdpDefn: c_int = 66;
pub const vpiPrimitive: c_int = 103;
pub const vpiPrimType: c_int = 33;
pub const vpiTermIndex: c_int = 30;
pub const vpiSwitch: c_int = 55;
pub const vpiPullupPrim: c_int = 25;
pub const vpiPulldownPrim: c_int = 26;
pub const vpiStrength0: c_int = 31;
pub const vpiStrength1: c_int = 32;
pub const vpiSeqPrim: c_int = 27;
pub const vpiCombPrim: c_int = 28;

// Annex G relationships.
pub const vpiCondition: c_int = 71;
pub const vpiDelay: c_int = 72;
pub const vpiElseStmt: c_int = 73;
pub const vpiForIncStmt: c_int = 74;
pub const vpiForInitStmt: c_int = 75;
pub const vpiLhs: c_int = 77;
pub const vpiHighConn: c_int = 76;
pub const vpiIndex: c_int = 78;
pub const vpiLeftRange: c_int = 79;
pub const vpiParent: c_int = 81;
pub const vpiRhs: c_int = 82;
pub const vpiScope: c_int = 84;
pub const vpiArgument: c_int = 89;
pub const vpiOperand: c_int = 97;
pub const vpiProcess: c_int = 99;
pub const vpiExpr: c_int = 102;
pub const vpiUse: c_int = 101;
pub const vpiBaseExpr: c_int = 131;
pub const vpiWidthExpr: c_int = 132;
/// IEEE 1364-2005 §26.6.22/§26.6.23.
pub const vpiDriver: c_int = 91;
pub const vpiLoad: c_int = 93;
pub const vpiLocalDriver: c_int = 122;
pub const vpiLocalLoad: c_int = 123;
// §11.6.15 (IEEE 1364 Annex G numbering): module paths, path terms, timing
// checks and their terms, the relations between them, and their properties.
pub const vpiModPath: c_int = 31;
pub const vpiPathTerm: c_int = 43;
pub const vpiTchk: c_int = 61;
pub const vpiTchkTerm: c_int = 62;
pub const vpiTchkDataTerm: c_int = 86;
pub const vpiTchkNotifier: c_int = 87;
pub const vpiTchkRefTerm: c_int = 88;
pub const vpiModPathIn: c_int = 95;
pub const vpiModPathOut: c_int = 96;
pub const vpiModDataPathIn: c_int = 94;
pub const vpiModPathHasIfNone: c_int = 71;
pub const vpiEdge: c_int = 36;
pub const vpiPathType: c_int = 37;
pub const vpiPolarity: c_int = 34;
pub const vpiDataPolarity: c_int = 35;
pub const vpiTchkType: c_int = 38;
pub const vpiPathFull: c_int = 1;
pub const vpiPathParallel: c_int = 2;
pub const vpiPositive: c_int = 1;
pub const vpiNegative: c_int = 2;
pub const vpiUnknown: c_int = 3;
pub const vpiNoEdge: c_int = 0x00;
pub const vpiPosedge: c_int = 0x0D;
pub const vpiNegedge: c_int = 0x32;
pub const vpiAnyEdge: c_int = 0x3F;
pub const vpiStmt: c_int = 104;
pub const vpiRightRange: c_int = 83;
/// IEEE 1364-2005 §26.6.10 an array's range.
pub const vpiRange: c_int = 115;
/// IEEE 1364-2005 §26.6.44 (Annex G).
pub const vpiGenScopeArray: c_int = 133;
pub const vpiGenScope: c_int = 134;
pub const vpiImplicitDecl: c_int = 26;
pub const vpiProtected: c_int = 10;

// Annex G properties.
pub const vpiOpType: c_int = 39;
pub const vpiBlocking: c_int = 41;
pub const vpiCaseType: c_int = 42;
pub const vpiNetDeclAssign: c_int = 43;
pub const vpiFuncType: c_int = 44;
// vpiFuncType values (Annex G).
pub const vpiIntFunc: c_int = 1;
pub const vpiRealFunc: c_int = 2;
pub const vpiTimeFunc: c_int = 3;
pub const vpiSizedFunc: c_int = 4;
pub const vpiSizedSignedFunc: c_int = 5;
pub const vpiDirection: c_int = 20;
pub const vpiSize: c_int = 4;
pub const vpiConnByName: c_int = 21;
pub const vpiIndexedPartSelectType: c_int = 72;
pub const vpiPosIndexed: c_int = 1;
pub const vpiNegIndexed: c_int = 2;

// vpiConstType values of a based literal (Annex G).
pub const vpiBinaryConst: c_int = 3;
pub const vpiOctConst: c_int = 4;
pub const vpiHexConst: c_int = 5;

// vpiCaseType values.
pub const vpiCaseExact: c_int = 1;
pub const vpiCaseX: c_int = 2;
pub const vpiCaseZ: c_int = 3;

// vpiOpType values.
pub const vpiMinusOp: c_int = 1;
pub const vpiPlusOp: c_int = 2;
pub const vpiNotOp: c_int = 3;
pub const vpiBitNegOp: c_int = 4;
pub const vpiUnaryAndOp: c_int = 5;
pub const vpiUnaryNandOp: c_int = 6;
pub const vpiUnaryOrOp: c_int = 7;
pub const vpiUnaryNorOp: c_int = 8;
pub const vpiUnaryXorOp: c_int = 9;
pub const vpiUnaryXNorOp: c_int = 10;
pub const vpiSubOp: c_int = 11;
pub const vpiDivOp: c_int = 12;
pub const vpiModOp: c_int = 13;
pub const vpiEqOp: c_int = 14;
pub const vpiNeqOp: c_int = 15;
pub const vpiCaseEqOp: c_int = 16;
pub const vpiCaseNeqOp: c_int = 17;
pub const vpiGtOp: c_int = 18;
pub const vpiGeOp: c_int = 19;
pub const vpiLtOp: c_int = 20;
pub const vpiLeOp: c_int = 21;
pub const vpiLShiftOp: c_int = 22;
pub const vpiRShiftOp: c_int = 23;
pub const vpiAddOp: c_int = 24;
pub const vpiMultOp: c_int = 25;
pub const vpiLogAndOp: c_int = 26;
pub const vpiLogOrOp: c_int = 27;
pub const vpiBitAndOp: c_int = 28;
pub const vpiBitOrOp: c_int = 29;
pub const vpiBitXorOp: c_int = 30;
pub const vpiBitXNorOp: c_int = 31;
pub const vpiConditionOp: c_int = 32;
pub const vpiConcatOp: c_int = 33;
pub const vpiMultiConcatOp: c_int = 34;
pub const vpiEventOrOp: c_int = 35;
pub const vpiListOp: c_int = 37;
pub const vpiPosedgeOp: c_int = 39;
pub const vpiNegedgeOp: c_int = 40;
pub const vpiArithLShiftOp: c_int = 41;
pub const vpiArithRShiftOp: c_int = 42;
pub const vpiPowerOp: c_int = 43;

// Verilog-AMS names these and numbers none; VerA's numbers, beside the
// analog classes of root.zig.
/// §11.6.21's `analog` process.
pub const vpiAnalog: c_int = 733;
/// §11.6.20 a contribution statement; `vpiDirect`/`vpiFlow` tell the four
/// members of the class apart.
pub const vpiContrib: c_int = 734;
pub const vpiDirect: c_int = 735;
/// §11.6.19 `accessfunc`, an access function applied to a branch or nodes.
pub const vpiAccessFunc: c_int = 736;

/// A single arrow: `vpi_handle(tag, obj)` answers object `to` (or `none`).
pub const Edge = struct { tag: c_int, to: u32 };
/// A double arrow: `vpi_iterate(tag, obj)` walks `items`.
pub const List = struct { tag: c_int, items: []const u32 };
/// An int or bool property `vpi_get(prop, obj)` answers.
pub const Prop = struct { prop: c_int, value: c_int };

/// The `vpi_get_str(vpiType)` spelling of every type this file makes.
pub fn typeName(t: c_int) ?[]const u8 {
    return switch (t) {
        vpiAlways => "vpiAlways",
        vpiRange => "vpiRange",
        vpiGenScopeArray => "vpiGenScopeArray",
        vpiGenScope => "vpiGenScope",
        vpiAssignStmt => "vpiAssignStmt",
        vpiAssignment => "vpiAssignment",
        vpiBegin => "vpiBegin",
        vpiCase => "vpiCase",
        vpiCaseItem => "vpiCaseItem",
        vpiContAssign => "vpiContAssign",
        vpiDeassign => "vpiDeassign",
        vpiDelayControl => "vpiDelayControl",
        vpiDisable => "vpiDisable",
        vpiEventControl => "vpiEventControl",
        vpiEventStmt => "vpiEventStmt",
        vpiFor => "vpiFor",
        vpiForce => "vpiForce",
        vpiForever => "vpiForever",
        vpiFork => "vpiFork",
        vpiFuncCall => "vpiFuncCall",
        vpiFunction => "vpiFunction",
        vpiIf => "vpiIf",
        vpiIfElse => "vpiIfElse",
        vpiInitial => "vpiInitial",
        vpiAttribute => "vpiAttribute",
        vpiIODecl => "vpiIODecl",
        vpiNamedBegin => "vpiNamedBegin",
        vpiNamedEvent => "vpiNamedEvent",
        vpiNamedEventArray => "vpiNamedEventArray",
        vpiNamedFork => "vpiNamedFork",
        vpiNetBit => "vpiNetBit",
        vpiNullStmt => "vpiNullStmt",
        vpiOperation => "vpiOperation",
        vpiPartSelect => "vpiPartSelect",
        vpiIndexedPartSelect => "vpiIndexedPartSelect",
        vpiRegBit => "vpiRegBit",
        vpiRelease => "vpiRelease",
        vpiRepeat => "vpiRepeat",
        vpiRepeatControl => "vpiRepeatControl",
        vpiSysFuncCall => "vpiSysFuncCall",
        vpiSysTaskCall => "vpiSysTaskCall",
        vpiTask => "vpiTask",
        vpiTaskCall => "vpiTaskCall",
        vpiWait => "vpiWait",
        vpiGate => "vpiGate",
        vpiSwitch => "vpiSwitch",
        vpiPrimTerm => "vpiPrimTerm",
        vpiTableEntry => "vpiTableEntry",
        vpiUdp => "vpiUdp",
        vpiUdpDefn => "vpiUdpDefn",
        vpiWhile => "vpiWhile",
        vpiParamAssign => "vpiParamAssign",
        vpiAnalog => "vpiAnalog",
        vpiContrib => "vpiContrib",
        vpiAccessFunc => "vpiAccessFunc",
        vpiModPath => "vpiModPath",
        vpiPathTerm => "vpiPathTerm",
        vpiTchk => "vpiTchk",
        vpiTchkTerm => "vpiTchkTerm",
        else => null, // else: not a type this file makes; the caller answers
    };
}

/// The per-scope double arrows of §11.6.1 this file fills.
pub const ScopeLists = struct {
    cont_assigns: std.ArrayList(u32) = .empty,
    processes: std.ArrayList(u32) = .empty,
    tasks: std.ArrayList(u32) = .empty,
    functions: std.ArrayList(u32) = .empty,
    events: std.ArrayList(u32) = .empty,
    event_arrays: std.ArrayList(u32) = .empty,
    primitives: std.ArrayList(u32) = .empty,
    mod_paths: std.ArrayList(u32) = .empty,
    tchks: std.ArrayList(u32) = .empty,
    gen_arrays: std.ArrayList(u32) = .empty,
    /// IEEE 1364-2005 §26.6.12: the `#(...)` assignments overriding this
    /// instance's parameters, written in its parent (model_digital.zig).
    param_assigns: std.ArrayList(u32) = .empty,
    /// IEEE 1364-2005 §26.6.3 the task, function and named block scopes
    /// written directly in the module; `model.freeze` joins its instances
    /// and gen scopes to them for `vpiInternalScope`.
    internal: std.ArrayList(u32) = .empty,

    /// Frees the lists (owned by `gpa`); the rows they index stay.
    pub fn deinit(s: *ScopeLists, gpa: std.mem.Allocator) void {
        inline for (@typeInfo(ScopeLists).@"struct".field_names) |name| @field(s, name).deinit(gpa);
    }

    /// Frozen as tagged rows, the shape `vpi_iterate(tag, module)` reads.
    pub fn freeze(s: *const ScopeLists, arena: std.mem.Allocator) ![]const List {
        return arena.dupe(List, &.{
            .{ .tag = vpiContAssign, .items = try arena.dupe(u32, s.cont_assigns.items) },
            .{ .tag = vpiProcess, .items = try arena.dupe(u32, s.processes.items) },
            .{ .tag = vpiTask, .items = try arena.dupe(u32, s.tasks.items) },
            .{ .tag = vpiFunction, .items = try arena.dupe(u32, s.functions.items) },
            .{ .tag = vpiNamedEvent, .items = try arena.dupe(u32, s.events.items) },
            .{ .tag = vpiNamedEventArray, .items = try arena.dupe(u32, s.event_arrays.items) },
            .{ .tag = vpiPrimitive, .items = try arena.dupe(u32, s.primitives.items) },
            .{ .tag = vpiModPath, .items = try arena.dupe(u32, s.mod_paths.items) },
            .{ .tag = vpiTchk, .items = try arena.dupe(u32, s.tchks.items) },
            .{ .tag = vpiGenScopeArray, .items = try arena.dupe(u32, s.gen_arrays.items) },
            .{ .tag = vpiParamAssign, .items = try arena.dupe(u32, s.param_assigns.items) },
        });
    }
};

const Error = root.Error;

/// One scope's worth of building: where new rows go, how a name in this
/// scope resolves, and the path new named objects hang under.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    objects: *model.Rows,
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
    inner: u32 = none,
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
    attrs: *const @import("attributes.zig").ByOwner,

    /// IEEE 1364-2005 §26.6.42: the attributes the source binds to `owner`,
    /// as vpiAttribute rows of object `at` (attributes.zig `attach`).
    pub fn attributes(b: *Builder, at: u32, owner: Ast.AttributeOwner, definition: bool) Error!void {
        return @import("attributes.zig").attach(b, at, owner, definition);
    }

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

    fn full(b: *Builder, local: []const u8) Error![]const u8 {
        const rel = if (b.path.len == 0) try b.arena.dupe(u8, local) else try b.arena.print("{s}.{s}", .{ b.path, local });
        return b.arena.print("{s}.{s}", .{ b.top_name, rel });
    }

    fn add(b: *Builder, o: Obj) Error!u32 {
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
    fn setName(b: *Builder, at: u32, local: []const u8) Error!void {
        const f = try b.full(local);
        b.objects.hot.items[at].name = local;
        b.objects.hot.items[at].full = f;
        try b.names.put(b.gpa, f, at);
    }

    const Saved = struct { inner: u32, path: []const u8, internal: ?*std.ArrayList(u32), engine: u32, automatic: bool };

    /// Enters object `at`, already named `local` in the current scope, as a
    /// scope of its own (IEEE 1364-2005 §12.5: "Each ... task, function, named
    /// begin-end or fork-join block defines a new hierarchical level"), with
    /// `into` collecting its internal scopes. `leave` restores the outer one.
    fn enter(b: *Builder, at: u32, local: []const u8, into: *std.ArrayList(u32)) Error!Saved {
        try (b.internal orelse &b.lists.internal).append(b.gpa, at);
        const saved: Saved = .{ .inner = b.inner, .path = b.path, .internal = b.internal, .engine = b.engine, .automatic = b.automatic };
        b.inner = at;
        b.path = if (b.path.len == 0) local else try b.arena.print("{s}.{s}", .{ b.path, local });
        b.internal = into;
        return saved;
    }

    fn leave(b: *Builder, s: Saved) void {
        b.inner = s.inner;
        b.path = s.path;
        b.internal = s.internal;
        b.engine = s.engine;
        b.automatic = s.automatic;
    }

    fn many(b: *Builder, items: []const u32) Error![]const u32 {
        var n: usize = 0;
        for (items) |i| n += @intFromBool(i != none);
        const out = try b.arena.alloc(u32, n);
        n = 0;
        for (items) |i| if (i != none) {
            out[n] = i;
            n += 1;
        };
        return out;
    }

    /// The engine's elaborated frame supplies widths even for automatic
    /// declarations; only static variables expose those slots as values.
    fn subFrame(b: *Builder, t: *const Ast.Subroutine) ?sim.digital.Frame {
        const r = b.run orelse return null;
        const i = r.sub_by_name.get(.{ .scope = b.engine, .str = t.name }) orelse return null;
        const sub = r.subs.items[i];
        return if (sub.framed) sub.frame else null;
    }

    fn declWidth(b: *Builder, v: Ast.VarDecl, slot: ?u32) c_int {
        if (slot) |at| return @intCast(b.run.?.values[at].width);
        return packedWidth(b.file, v);
    }

    const SubVars = struct {
        regs: std.ArrayList(u32) = .empty,
        ints: std.ArrayList(u32) = .empty,
        reals: std.ArrayList(u32) = .empty,
    };

    /// IEEE 1364-2005 §26.6.3/§26.6.18: one formal, local or implicit
    /// result variable in the entered subroutine scope. Register its name
    /// before building expressions that reference it.
    fn subVar(b: *Builder, vars: *SubVars, v: Ast.VarDecl, slot: ?u32, automatic: bool) Error!u32 {
        const kind = subVarKind(v) orelse return none;
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
            .edges = try b.arena.dupe(Edge, &.{.{ .tag = vpiScope, .to = b.inner }}),
        });
        try b.setName(at, try b.arena.dupe(u8, b.file.str(v.name)));
        try b.attributes(at, .{ .kind = .declaration, .tok = v.main_tok }, false);
        (if (kind == .reg) &vars.regs else if (kind == .real_var) &vars.reals else &vars.ints).appendAssumeCapacity(at);
        return at;
    }

    /// The object class `subVar` gives `v`, or null for none.
    ///
    /// ponytail: subroutine arrays and time variables still have no
    /// object here; the latter needs the model's vpiTimeVar class.
    fn subVarKind(v: Ast.VarDecl) ?@FieldType(Obj, "kind") {
        if (v.dims.len != 0 or v.storage == .time) return null;
        return if (v.ty == .real) .real_var else if (v.storage == .reg) .reg else .integer;
    }

    /// `t`'s subroutine variables, each list sized to what `subVar` will
    /// append to it.
    fn subVars(b: *Builder, t: *const Ast.Subroutine) Error!SubVars {
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

    // ---------------------------------------------------------------- module

    const Events = struct { scalars: []const u32, arrays: []const u32 };

    /// IEEE 1364-2005 §26.6.11: declarations and persistent element
    /// identities. Storage order is the engine's increasing row-major order;
    /// vpiRange retains source direction, vpiIndex runs innermost first.
    fn eventDecls(b: *Builder, declarations: []const Ast.EventDecl) Error!Events {
        var n_arrays: usize = 0;
        for (declarations) |e| n_arrays += @intFromBool(e.dims.len != 0);
        var scalars: std.ArrayList(u32) = try .initCapacity(b.arena, declarations.len - n_arrays);
        var arrays: std.ArrayList(u32) = try .initCapacity(b.arena, n_arrays);
        for (declarations) |e| {
            const slot = if (b.run) |r| r.names.get(.{ .scope = b.engine, .str = e.name }) else null;
            const scope: []const Edge = if (b.inner == none) &.{} else &.{.{ .tag = vpiScope, .to = b.inner }};
            const auto_prop: Prop = .{ .prop = root.vpiAutomatic, .value = @intFromBool(b.automatic) };
            const at = try b.code(if (e.dims.len == 0) vpiNamedEvent else vpiNamedEventArray, scope, &.{.{ .tag = vpiIndex, .items = &.{} }}, if (e.dims.len == 0) &.{ .{ .prop = root.vpiArray, .value = 0 }, auto_prop } else &.{auto_prop});
            try b.setName(at, try b.arena.dupe(u8, b.file.str(e.name)));
            b.objects.hot.items[at].src_tok = e.main_tok;
            b.objects.hot.items[at].automatic = b.automatic;
            try b.attributes(at, .{ .kind = .declaration, .tok = e.main_tok }, false);
            if (e.dims.len == 0) {
                b.objects.hot.items[at].slot = .of(if (b.automatic) null else slot);
                scalars.appendAssumeCapacity(at);
                continue;
            }
            arrays.appendAssumeCapacity(at);
            const base = slot orelse continue;
            const arr = b.run.?.arrays.get(base).?;
            const ranges = try b.arena.alloc(u32, e.dims.len);
            ranges[0] = try model.addRange(b.arena, b.objects, b.scope, arr.left, arr.right);
            for (arr.rest, ranges[1..]) |sp, *range| range.* = try model.addRange(b.arena, b.objects, b.scope, if (sp.descending) sp.high else sp.low, if (sp.descending) sp.low else sp.high);
            const members = try b.arena.alloc(u32, arr.count);
            for (members, 0..) |*member, k| {
                const indices = try b.arena.alloc(u32, e.dims.len);
                var suffix: std.ArrayList(u8) = try .initCapacity(b.arena, indices.len * model.index_text_max);
                var q: i64 = @intCast(k);
                for (indices, 0..) |*index, j| {
                    const d = indices.len - 1 - j;
                    const sp: sim.digital.Span = if (d == 0) .{ .low = arr.low, .high = arr.high } else arr.rest[d - 1];
                    const count = sp.high - sp.low + 1;
                    const i = sp.low + @mod(q, count);
                    q = @divTrunc(q, count);
                    index.* = try b.constant(.{ .int = i }, 32, root.vpiDecConst);
                    var buf: [model.index_text_max]u8 = undefined;
                    suffix.insertSliceAssumeCapacity(0, std.mem.print(&buf, "[{d}]", .{i}) catch unreachable);
                }
                const local = try b.arena.print("{s}{s}", .{ b.file.str(e.name), suffix.items });
                member.* = try b.code(vpiNamedEvent, &.{ .{ .tag = vpiParent, .to = at }, .{ .tag = vpiIndex, .to = indices[0] } }, &.{.{ .tag = vpiIndex, .items = indices }}, &.{ .{ .prop = root.vpiArray, .value = 1 }, auto_prop });
                if (scope.len != 0) b.objects.hot.items[member.*].edges = try b.arena.dupe(Edge, &.{ b.objects.hot.items[member.*].edges[0], b.objects.hot.items[member.*].edges[1], scope[0] });
                try b.setName(member.*, local);
                b.objects.hot.items[member.*].index = .of(indices[0]);
                b.objects.hot.items[member.*].automatic = b.automatic;
                b.objects.hot.items[member.*].slot = .of(if (b.automatic) null else base + @as(u32, @intCast(k)));
            }
            const cold = try b.objects.coldFor(at);
            cold.members = members;
            cold.range = ranges;
            b.objects.hot.items[at].lists = try b.arena.dupe(List, &.{ .{ .tag = vpiNamedEvent, .items = members }, .{ .tag = vpiRange, .items = ranges } });
        }
        return .{ .scalars = scalars.items, .arrays = arrays.items };
    }

    /// The behavioural contents of one digital module instance: its named
    /// events, tasks and functions, continuous assignments and processes.
    pub fn module(b: *Builder, m: *const Ast.ModuleDecl) Error!void {
        try b.attributes(b.scope, .{ .kind = .declaration, .tok = m.main_tok }, true);
        try b.reserveModule(m);
        const events = try b.eventDecls(m.events);
        try b.lists.events.appendSlice(b.gpa, events.scalars);
        try b.lists.event_arrays.appendSlice(b.gpa, events.arrays);
        // §11.6.3 task and function, before any statement that calls one.
        for (m.tasks) |*t| {
            const at = try b.add(.{ .kind = .code, .owner = .of(b.scope), .name = "", .full = "", .vtype = if (t.is_function) vpiFunction else vpiTask });
            try b.setName(at, try b.arena.dupe(u8, b.file.str(t.name)));
            (if (t.is_function) &b.lists.functions else &b.lists.tasks).appendAssumeCapacity(at);
            // §26.6.18/§26.6.19: publish all function types before building
            // any body, including calls of a later-declared function.
            const frame = b.subFrame(t);
            if (t.is_function) b.objects.hot.items[at].props = try b.arena.dupe(Prop, &.{
                .{ .prop = vpiSize, .value = b.declWidth(t.result, if (frame) |fr| fr.result else null) },
                .{ .prop = root.vpiSigned, .value = @intFromBool(t.result.is_signed) },
                .{ .prop = vpiFuncType, .value = funcType(t.result) },
            });
        }
        for (m.tasks, 0..) |*t, k| {
            const at = (if (t.is_function) b.lists.functions.items else b.lists.tasks.items)[subIndex(m.tasks, k)];
            // A prefix on the declaration is in the containing scope;
            // only its formals/body see the subroutine's local parameters.
            try b.attributes(at, .{ .kind = .declaration, .tok = t.main_tok }, false);
            var inner: std.ArrayList(u32) = .empty;
            defer inner.deinit(b.gpa);
            const saved = try b.enter(at, b.objects.hot.items[at].name, &inner);
            b.automatic = t.automatic;
            const frame = b.subFrame(t);
            if (frame) |fr| b.engine = fr.scope;
            const local_events = try b.eventDecls(t.events);
            var vars = try b.subVars(t);
            if (t.is_function) _ = try b.subVar(&vars, t.result, if (frame) |fr| fr.result else null, t.automatic);
            const ios = try b.arena.alloc(u32, t.ports.len);
            for (t.ports, ios, 0..) |p, *io, i| {
                const slot = if (frame) |fr| fr.ports[i] else null;
                const formal = try b.subVar(&vars, p.v, slot, t.automatic);
                const local = try b.arena.dupe(u8, b.file.str(p.v.name));
                io.* = try b.add(.{
                    .kind = .code,
                    .owner = .of(b.scope),
                    .name = local,
                    .full = "",
                    .vtype = vpiIODecl,
                    .src_tok = p.v.main_tok,
                    .props = try ioProps(b.arena, direction(p.direction), b.declWidth(p.v, slot), p.v.is_signed),
                    .edges = try b.arena.dupe(Edge, &.{ .{ .tag = vpiExpr, .to = formal }, .{ .tag = vpiScope, .to = at } }),
                });
            }
            for (t.vars) |v| {
                const slot = if (frame) |fr| b.run.?.names.get(.{ .scope = fr.scope, .str = v.name }) else null;
                _ = try b.subVar(&vars, v, slot, t.automatic);
            }
            const body = try b.stmt(t.body);
            b.leave(saved);
            b.objects.hot.items[at].edges = try b.arena.dupe(Edge, &.{.{ .tag = vpiStmt, .to = body }});
            b.objects.hot.items[at].lists = try b.arena.dupe(List, &.{
                .{ .tag = vpiIODecl, .items = ios },
                .{ .tag = root.vpiReg, .items = vars.regs.items },
                .{ .tag = root.vpiIntegerVar, .items = vars.ints.items },
                .{ .tag = root.vpiRealVar, .items = vars.reals.items },
                .{ .tag = vpiNamedEvent, .items = local_events.scalars },
                .{ .tag = vpiNamedEventArray, .items = local_events.arrays },
                .{ .tag = root.vpiInternalScope, .items = try b.arena.dupe(u32, inner.items) },
            });
        }
        // §11.6.17.
        for (m.assigns) |a| {
            const lhs = try b.expr(a.target);
            const rhs = try b.expr(a.value);
            const delay = try b.delayExpr(a.delay);
            const at = try b.code(vpiContAssign, &.{
                .{ .tag = vpiLhs, .to = lhs },
                .{ .tag = vpiRhs, .to = rhs },
                .{ .tag = vpiDelay, .to = delay },
            }, &.{}, &.{.{ .prop = vpiNetDeclAssign, .value = 0 }});
            b.objects.hot.items[at].delays = try b.delays(a.delay);
            b.objects.hot.items[at].src_tok = a.main_tok;
            try b.attributes(at, .{ .kind = .declaration, .tok = a.main_tok }, false);
            b.lists.cont_assigns.appendAssumeCapacity(at);
        }
        // IEEE 1364-2005 §26.6.24: a net declaration assignment (A.2.4) is a
        // continuous assignment too, "-> net decl assign bool:
        // vpiNetDeclAssign". §6.1.3: "When there is a continuous assignment
        // in a declaration, the delay is part of the continuous assignment".
        for (m.nets) |n| {
            if (n.init == .none) continue;
            const at = try b.code(vpiContAssign, &.{
                .{ .tag = vpiLhs, .to = b.lookup(b.file.str(n.name)) },
                .{ .tag = vpiRhs, .to = try b.expr(n.init) },
                .{ .tag = vpiDelay, .to = try b.delayExpr(n.delay) },
            }, &.{}, &.{.{ .prop = vpiNetDeclAssign, .value = 1 }});
            b.objects.hot.items[at].delays = try b.delays(n.delay);
            b.objects.hot.items[at].src_tok = n.main_tok;
            b.lists.cont_assigns.appendAssumeCapacity(at);
        }
        // §11.6.13 gates, in source order, then pull sources, switches and
        // UDP instances.
        for (m.gates) |g| {
            const terms = try b.arena.alloc(Ast.ExprId, 1 + g.ins.len);
            terms[0] = g.out;
            @memcpy(terms[1..], g.ins);
            const at = try b.primitive(vpiGate, gateType(g.kind), @tagName(g.kind)["g_".len..], terms, &.{}, &.{
                .{ .prop = root.vpiArray, .value = @intFromBool(g.range != null) },
                .{ .prop = vpiStrength0, .value = drive(g.strength0) },
                .{ .prop = vpiStrength1, .value = drive(g.strength1) },
            });
            if (g.name != .none) try b.setName(at, try b.arena.dupe(u8, b.file.str(g.name)));
            const delay = try b.delayExpr(g.delay);
            b.objects.hot.items[at].delays = try b.delays(g.delay);
            b.objects.hot.items[at].src_tok = g.main_tok;
            try b.attributes(at, .{ .kind = .declaration, .tok = g.main_tok }, false);
            b.objects.hot.items[at].edges = try b.arena.dupe(Edge, &.{.{ .tag = vpiDelay, .to = delay }});
        }
        // IEEE 1364-2005 §7.8: a pull source drives its one terminal, at its
        // strength on its own side (the other "shall be ignored").
        for (m.pulls) |p| {
            const side: c_int = if (p.one) vpiStrength1 else vpiStrength0;
            const at = try b.primitive(vpiGate, if (p.one) vpiPullupPrim else vpiPulldownPrim, if (p.one) "pullup" else "pulldown", &.{p.out}, &.{}, &.{
                .{ .prop = root.vpiArray, .value = 0 },
                .{ .prop = side, .value = drive(p.strength) },
            });
            try b.attributes(at, .{ .kind = .declaration, .tok = p.main_tok }, false);
        }
        // §7.1/§7.6's switches: a MOS or CMOS switch's output, then its input
        // and controls; a pass switch's two inouts, then its enable.
        for (m.switches) |sw| {
            const pass = switch (sw.kind) {
                .tran, .rtran, .tranif0, .tranif1, .rtranif0, .rtranif1 => true,
                .cmos, .rcmos, .nmos, .pmos, .rnmos, .rpmos => false,
            };
            const dirs = try b.arena.alloc(c_int, sw.terms.len);
            for (dirs, 0..) |*dir, k| dir.* = (if (k == 0) (if (pass) root.vpiInout else root.vpiOutput) else if (pass and k == 1) root.vpiInout else root.vpiInput);
            const at = try b.primitive(vpiSwitch, switchType(sw.kind), @tagName(sw.kind), sw.terms, dirs, &.{.{ .prop = root.vpiArray, .value = 0 }});
            try b.attributes(at, .{ .kind = .declaration, .tok = sw.main_tok }, false);
        }
        if (b.udps) |udps| for (m.instances) |inst| {
            const defn = udps.get(inst.module) orelse continue;
            const terms = try b.arena.alloc(Ast.ExprId, inst.ports.len);
            for (inst.ports, terms) |c, *t| t.* = c.expr;
            const d = b.objects.hot.items[defn];
            const at = try b.primitive(vpiUdp, d.props[1].value, d.def_name, terms, &.{}, &.{
                .{ .prop = root.vpiArray, .value = @intFromBool(inst.range != null) },
                .{ .prop = vpiStrength0, .value = drive(inst.strength0) },
                .{ .prop = vpiStrength1, .value = drive(inst.strength1) },
            });
            try b.setName(at, try b.arena.dupe(u8, b.file.str(inst.name)));
            const delay = try b.delayExpr(inst.delay);
            b.objects.hot.items[at].delays = try b.delays(inst.delay);
            b.objects.hot.items[at].src_tok = inst.main_tok;
            try b.attributes(at, .{ .kind = .declaration, .tok = inst.main_tok }, false);
            b.objects.hot.items[at].edges = try b.arena.dupe(Edge, &.{
                .{ .tag = vpiUdpDefn, .to = defn },
                .{ .tag = vpiDelay, .to = delay },
            });
        };
        // §11.6.15 the specify block's module paths and timing checks.
        for (m.paths) |p| try b.modPath(p);
        for (m.timing_checks) |t| try b.timingCheck(t);
        // §11.6.21 initial and always.
        for (m.discrete) |d| {
            const body = try b.stmt(d.body);
            const at = try b.code(if (d.is_always) vpiAlways else vpiInitial, &.{.{ .tag = vpiStmt, .to = body }}, &.{}, &.{});
            try b.attributes(at, .{ .kind = .declaration, .tok = d.main_tok }, false);
            b.lists.processes.appendAssumeCapacity(at);
        }
    }

    /// Sizes the scope lists only `module` fills to what it will append:
    /// one per task or function, continuous assignment (with net
    /// declaration assignments), primitive, module path and process; at most
    /// one per timing check (an unknown one is skipped).
    fn reserveModule(b: *Builder, m: *const Ast.ModuleDecl) Error!void {
        var n_fn: usize = 0;
        for (m.tasks) |t| n_fn += @intFromBool(t.is_function);
        var n_assign = m.assigns.len;
        for (m.nets) |n| n_assign += @intFromBool(n.init != .none);
        var n_prim = m.gates.len + m.pulls.len + m.switches.len;
        if (b.udps) |udps| for (m.instances) |inst| {
            n_prim += @intFromBool(udps.contains(inst.module));
        };
        const l = b.lists;
        try l.functions.ensureTotalCapacityPrecise(b.gpa, n_fn);
        try l.tasks.ensureTotalCapacityPrecise(b.gpa, m.tasks.len - n_fn);
        try l.cont_assigns.ensureTotalCapacityPrecise(b.gpa, n_assign);
        try l.primitives.ensureTotalCapacityPrecise(b.gpa, n_prim);
        try l.mod_paths.ensureTotalCapacityPrecise(b.gpa, m.paths.len);
        try l.tchks.ensureTotalCapacityPrecise(b.gpa, m.timing_checks.len);
        try l.processes.ensureTotalCapacityPrecise(b.gpa, m.discrete.len);
    }

    /// §11.6.21's third process, `analog`, over the flattened analog blocks
    /// that belong to this scope (`AnalogBlock.unit`).
    pub fn analogBlocks(b: *Builder, blocks: []const Ast.AnalogBlock) Error!void {
        var n: usize = 0;
        for (blocks) |blk| n += @intFromBool(blk.unit == b.scope);
        try b.lists.processes.ensureUnusedCapacity(b.gpa, n);
        for (blocks) |blk| {
            if (blk.unit != b.scope) continue;
            const body = try b.stmt(blk.body);
            const at = try b.code(vpiAnalog, &.{.{ .tag = vpiStmt, .to = body }}, &.{}, &.{});
            try b.attributes(at, .{ .kind = .declaration, .tok = blk.main_tok }, false);
            b.lists.processes.appendAssumeCapacity(at);
        }
    }

    /// A §11.6.13 primitive with its terminals, vpiTermIndex in A.3.3's
    /// order: each terminal's direction from `dirs`, or when empty, output
    /// first and then the inputs. `props` are the class's own (vpiArray,
    /// the strengths).
    ///
    /// ponytail: an array of instances (IEEE 1364-2005 §7.1.5) is this one
    /// object with vpiArray set, not one per index with a vpiIndex; splitting
    /// it needs §7.1.6's terminal split.
    fn primitive(b: *Builder, vtype: c_int, prim_type: c_int, def_name: []const u8, terms: []const Ast.ExprId, dirs: []const c_int, props: []const Prop) Error!u32 {
        const dir = struct {
            fn at(ds: []const c_int, k: usize) c_int {
                return if (ds.len != 0) ds[k] else if (k == 0) root.vpiOutput else root.vpiInput;
            }
        }.at;
        var inputs: c_int = 0;
        for (terms, 0..) |_, k| inputs += @intFromBool(dir(dirs, k) == root.vpiInput);
        const all = try std.mem.concat(b.arena, Prop, &.{
            &.{
                .{ .prop = vpiPrimType, .value = prim_type },
                // NOTE 1: "vpiSize shall return the number of inputs."
                .{ .prop = vpiSize, .value = inputs },
            },
            props,
        });
        const at = try b.code(vtype, &.{}, &.{}, all);
        b.objects.hot.items[at].def_name = def_name;
        const items = try b.arena.alloc(u32, terms.len);
        for (terms, items, 0..) |t, *item, k| {
            const e = try b.expr(t);
            item.* = try b.code(vpiPrimTerm, &.{
                .{ .tag = vpiExpr, .to = e },
                .{ .tag = vpiPrimitive, .to = at },
            }, &.{}, &.{
                .{ .prop = vpiDirection, .value = dir(dirs, k) },
                .{ .prop = vpiTermIndex, .value = @intCast(k) },
            });
        }
        b.objects.hot.items[at].lists = try b.arena.dupe(List, &.{.{ .tag = vpiPrimTerm, .items = items }});
        b.lists.primitives.appendAssumeCapacity(at);
        return at;
    }

    fn subIndex(tasks: []const Ast.Subroutine, k: usize) usize {
        var n: usize = 0;
        for (tasks[0..k]) |t| {
            if (t.is_function == tasks[k].is_function) n += 1;
        }
        return n;
    }

    /// §11.6.15 a module path: `vpiModPathIn` / `vpiModPathOut` path terms
    /// (each ->vpiExpr its terminal, with vpiDirection and vpiEdge),
    /// ->vpiCondition its `if` expression, and vpiPathType, vpiPolarity,
    /// vpiDataPolarity. Its delays are the A.7.4 list, for §12.11.
    fn modPath(b: *Builder, p: Ast.SpecPath) Error!void {
        const ins = try b.arena.alloc(u32, p.ins.len);
        for (p.ins, ins) |e, *t| t.* = try b.term(vpiPathTerm, e, root.vpiInput, p.edge);
        const outs = try b.arena.alloc(u32, p.outs.len);
        for (p.outs, outs) |e, *t| t.* = try b.term(vpiPathTerm, e, root.vpiOutput, .none);
        const cond = if (p.cond != .none) try b.expr(p.cond) else none;
        const data = try b.term(vpiPathTerm, p.data, root.vpiInput, .none);
        const at = try b.code(vpiModPath, &.{
            .{ .tag = vpiCondition, .to = cond },
            .{ .tag = vpiDelay, .to = try b.delayListExpr(p.delays) },
            .{ .tag = vpiModDataPathIn, .to = data },
        }, &.{
            .{ .tag = vpiModPathIn, .items = ins },
            .{ .tag = vpiModPathOut, .items = outs },
        }, &.{
            .{ .prop = vpiPathType, .value = if (p.full) vpiPathFull else vpiPathParallel },
            .{ .prop = vpiPolarity, .value = polarity(p.polarity) },
            .{ .prop = vpiDataPolarity, .value = polarity(p.data_polarity) },
            .{ .prop = vpiModPathHasIfNone, .value = @intFromBool(p.ifnone) },
        });
        b.objects.hot.items[at].delays = try b.foldAll(p.delays);
        b.objects.hot.items[at].src_tok = p.main_tok;
        b.lists.mod_paths.appendAssumeCapacity(at);
    }

    /// §11.6.15 a timing check: vpiTchkType, ->vpiTchkRefTerm its first event,
    /// ->vpiTchkDataTerm its second (not `$period`/`$width`, which have one),
    /// ->vpiTchkNotifier the reg a violation toggles, when written. Its
    /// "limits" are §12.11's delays: "the no_of_delays value shall match the
    /// number of limits existing in the timing check".
    fn timingCheck(b: *Builder, t: Ast.TimingCheck) Error!void {
        const name = b.file.str(t.name);
        const kind = tchk_kinds.get(name) orelse return;
        const arg = struct {
            fn at(tc: Ast.TimingCheck, k: usize) Ast.ExprId {
                return if (k < tc.args.len) tc.args[k] else .none;
            }
        }.at;
        // A.7.5.1: `$setup ( data_event , reference_event , …)` is the one
        // command that writes its data event first.
        const r: usize = if (kind.data_first) 1 else 0;
        const dt: usize = 1 - r;
        const ref = try b.term(vpiTchkTerm, arg(t, r), 0, if (t.edges.len > r) t.edges[r] else .none);
        const data = if (kind.data) try b.term(vpiTchkTerm, arg(t, dt), 0, if (t.edges.len > dt) t.edges[dt] else .none) else none;
        const notifier = if (arg(t, kind.notifier) != .none) try b.expr(arg(t, kind.notifier)) else none;
        // Details b: every argument written, in order, the events as their
        // tchk terms.
        const args = try b.arena.alloc(u32, t.args.len);
        for (t.args, args, 0..) |a, *out, k| out.* = if (k == r) ref else if (kind.data and k == dt) data else if (k == kind.notifier) notifier else try b.expr(a);
        var limit_buf: [kind.limits.len]Ast.ExprId = undefined;
        const limits = limit_buf[0..kind.n_limits];
        for (kind.limits[0..kind.n_limits], limits) |k, *l| l.* = arg(t, k);
        const at = try b.code(vpiTchk, &.{
            .{ .tag = vpiTchkRefTerm, .to = ref },
            .{ .tag = vpiTchkDataTerm, .to = data },
            .{ .tag = vpiTchkNotifier, .to = notifier },
            .{ .tag = vpiDelay, .to = try b.delayListExpr(limits) },
        }, &.{.{ .tag = vpiExpr, .items = try b.many(args) }}, &.{.{ .prop = vpiTchkType, .value = kind.type }});
        b.objects.hot.items[at].delays = try b.foldAll(limits);
        b.objects.hot.items[at].src_tok = t.main_tok;
        b.lists.tchks.appendAssumeCapacity(at);
    }

    /// A path or timing-check terminal: its expression, direction and edge.
    fn term(b: *Builder, vtype: c_int, e: Ast.ExprId, dir: c_int, edge: Ast.SpecEdge) Error!u32 {
        if (e == .none) return none;
        const x = try b.expr(e);
        const props: [2]Prop = .{ .{ .prop = vpiDirection, .value = dir }, .{ .prop = vpiEdge, .value = switch (edge) {
            .none => vpiNoEdge,
            .posedge => vpiPosedge,
            .negedge => vpiNegedge,
            .edge => vpiAnyEdge,
        } } };
        return b.code(vtype, &.{.{ .tag = vpiExpr, .to = x }}, &.{}, props[@intFromBool(dir == 0)..]);
    }

    /// IEEE 1364-2005 §26.3.4 vpiDelay: the one delay expression, or a
    /// vpiListOp operation over several; `none` when none is written.
    fn delayListExpr(b: *Builder, es: []const Ast.ExprId) Error!u32 {
        return switch (es.len) {
            0 => none,
            1 => b.expr(es[0]),
            else => b.operation(vpiListOp, es),
        };
    }

    /// Every expression folded to a literal, or none of them when one does
    /// not fold (a specparam name, which this model does not elaborate).
    fn foldAll(b: *Builder, es: []const Ast.ExprId) Error![]const f64 {
        const out = try b.arena.alloc(f64, es.len);
        for (es, out) |e, *v| v.* = literal(b.file, e) orelse return &.{};
        return out;
    }

    /// IEEE 1364-2005 §26.3.4 vpiDelay: "an expression that evaluates to a
    /// constant if there is only one delay specified or an operation if
    /// there are more than one delay specified. If multiple delays are
    /// specified, then the operation's vpiOpType shall be vpiListOp."
    fn delayExpr(b: *Builder, d: Ast.Delay3) Error!u32 {
        if (!d.any()) return none;
        // `parseDelay3` spreads a single delay over all three transitions.
        if (d.fall == d.rise) return b.expr(d.rise);
        return b.operation(vpiListOp, if (d.off == .none) &.{ d.rise, d.fall } else &.{ d.rise, d.fall, d.off });
    }

    fn delays(b: *Builder, d: Ast.Delay3) Error![]const f64 {
        if (!d.any()) return &.{};
        var out: [3]f64 = undefined;
        var n: usize = 0;
        for ([_]Ast.ExprId{ d.rise, d.fall, d.off }) |e| {
            if (e == .none) break;
            out[n] = literal(b.file, e) orelse return &.{};
            n += 1;
        }
        return b.arena.dupe(f64, out[0..n]);
    }

    // ------------------------------------------------------------ statements

    /// Builds the object for statement `id` and its children; returns its
    /// index, or `none` for `.none` or a statement with no §11.6.21 object.
    pub fn stmt(b: *Builder, id: Ast.StmtId) Error!u32 {
        const at = try b.stmtObj(id);
        if (id != .none) try b.attributes(at, .{ .kind = .statement, .tok = b.file.stmtTok(id) }, false);
        if (at != none) b.objects.hot.items[at].stmt = id;
        // IEEE 1364-2005 §26.6.3 stmt -> vpiScope: the innermost task,
        // function or named block around it. At module level the edge is the
        // owner one every object shares. Appended, so a disable's own
        // vpiScope (AMS §11.6.24, the scope it disables) is found first.
        if (at != none and b.inner != none) {
            const o = &b.objects.hot.items[at];
            o.edges = try std.mem.concat(b.arena, Edge, &.{ o.edges, &.{.{ .tag = vpiScope, .to = b.inner }} });
        }
        return at;
    }

    fn stmtObj(b: *Builder, id: Ast.StmtId) Error!u32 {
        if (id == .none) return none;
        const f = b.file;
        return switch (f.stmt(id)) {
            .empty => b.code(vpiNullStmt, &.{}, &.{}, &.{}),
            .block => |blk| blk: {
                // The block is made — and named — BEFORE its statements, so
                // a `disable` inside it finds it (§11.6.24 disable -> scope).
                const named = blk.name != .none;
                const vt: c_int = if (blk.parallel) (if (named) vpiNamedFork else vpiFork) else if (named) vpiNamedBegin else vpiBegin;
                const at = try b.code(vt, &.{}, &.{}, &.{});
                var inner: std.ArrayList(u32) = .empty;
                defer inner.deinit(b.gpa);
                var saved: ?Saved = null;
                if (named) {
                    const local = try b.arena.dupe(u8, f.str(blk.name));
                    try b.setName(at, local);
                    saved = try b.enter(at, local, &inner);
                    if (b.run) |r| b.engine = r.block_scopes.get(.{ .scope = b.engine, .stmt = id }) orelse b.engine;
                }
                const events = try b.eventDecls(blk.events);
                const items = try b.arena.alloc(u32, blk.body.len);
                for (blk.body, items) |s, *item| item.* = try b.stmt(s);
                if (saved) |sv| b.leave(sv);
                const stmts: List = .{ .tag = vpiStmt, .items = try b.many(items) };
                b.objects.hot.items[at].lists = if (named)
                    try b.arena.dupe(List, &.{ stmts, .{ .tag = root.vpiInternalScope, .items = try b.arena.dupe(u32, inner.items) }, .{ .tag = vpiNamedEvent, .items = events.scalars }, .{ .tag = vpiNamedEventArray, .items = events.arrays } })
                else
                    try b.arena.dupe(List, &.{stmts});
                break :blk at;
            },
            .assign => |a| switch (a.continuous) {
                .none => blk: {
                    const lhs = try b.expr(a.target);
                    const rhs = try b.expr(a.value);
                    // §11.6.22 NOTE: "For delay control and event control
                    // associated with assignment, the statement shall always
                    // be NULL."
                    var dc = none;
                    var ec = none;
                    var rc = none;
                    // An intra-assignment `@*` is the statement form's
                    // event control: its vpiCondition is NULL.
                    if (a.timing != .none or a.timing_implicit) {
                        const e = try b.expr(a.timing);
                        if (a.timing_is_delay) {
                            dc = try b.code(vpiDelayControl, &.{ .{ .tag = vpiDelay, .to = e }, .{ .tag = vpiStmt, .to = none } }, &.{}, &.{});
                        } else {
                            ec = try b.code(vpiEventControl, &.{ .{ .tag = vpiCondition, .to = e }, .{ .tag = vpiStmt, .to = none } }, &.{}, &.{});
                        }
                        // §26.6.31 a repeat control: its count and its event
                        // control, and no statement.
                        if (a.timing_repeat != .none) {
                            rc = try b.code(vpiRepeatControl, &.{ .{ .tag = vpiExpr, .to = try b.expr(a.timing_repeat) }, .{ .tag = vpiEventControl, .to = ec } }, &.{}, &.{});
                            ec = none;
                        }
                    }
                    break :blk b.code(vpiAssignment, &.{
                        .{ .tag = vpiLhs, .to = lhs },
                        .{ .tag = vpiRhs, .to = rhs },
                        .{ .tag = vpiDelayControl, .to = dc },
                        .{ .tag = vpiEventControl, .to = ec },
                        .{ .tag = vpiRepeatControl, .to = rc },
                    }, &.{}, &.{.{ .prop = vpiBlocking, .value = @intFromBool(!a.nonblocking) }});
                },
                // §11.6.24: force and assign stmt draw vpiLhs and vpiRhs;
                // deassign and release draw vpiLhs alone.
                .assign, .force => blk: {
                    const at = try b.code(if (a.continuous == .force) vpiForce else vpiAssignStmt, &.{
                        .{ .tag = vpiLhs, .to = try b.expr(a.target) },
                        .{ .tag = vpiRhs, .to = try b.expr(a.value) },
                    }, &.{}, &.{});
                    (try b.objects.coldFor(at)).override_expr = a.value;
                    break :blk at;
                },
                .deassign, .release => b.code(if (a.continuous == .release) vpiRelease else vpiDeassign, &.{
                    .{ .tag = vpiLhs, .to = try b.expr(a.target) },
                }, &.{}, &.{}),
            },
            .if_stmt => |s| blk: {
                const cond = try b.expr(s.cond);
                const then = try b.stmt(s.then_s);
                if (s.else_s == .none) break :blk b.code(vpiIf, &.{
                    .{ .tag = vpiCondition, .to = cond },
                    .{ .tag = vpiStmt, .to = then },
                }, &.{}, &.{});
                break :blk b.code(vpiIfElse, &.{
                    .{ .tag = vpiCondition, .to = cond },
                    .{ .tag = vpiStmt, .to = then },
                    .{ .tag = vpiElseStmt, .to = try b.stmt(s.else_s) },
                }, &.{}, &.{});
            },
            .case_stmt => |s| blk: {
                const cond = try b.expr(s.scrutinee);
                const items = try b.arena.alloc(u32, s.arms.len);
                for (s.arms, items) |arm, *item| {
                    // §11.6.23 NOTE 2: the default item has no expression, so
                    // its vpiExpr set is empty and vpi_iterate is NULL.
                    const labels = try b.arena.alloc(u32, arm.labels.len);
                    for (arm.labels, labels) |l, *label| label.* = try b.expr(l);
                    item.* = try b.code(vpiCaseItem, &.{.{ .tag = vpiStmt, .to = try b.stmt(arm.body) }}, &.{.{ .tag = vpiExpr, .items = try b.many(labels) }}, &.{});
                }
                break :blk b.code(vpiCase, &.{.{ .tag = vpiCondition, .to = cond }}, &.{.{ .tag = vpiCaseItem, .items = items }}, &.{.{ .prop = vpiCaseType, .value = switch (s.kind) {
                    .normal => vpiCaseExact,
                    .casex => vpiCaseX,
                    .casez => vpiCaseZ,
                } }});
            },
            .for_stmt => |s| b.code(vpiFor, &.{
                .{ .tag = vpiForInitStmt, .to = try b.stmt(s.init) },
                .{ .tag = vpiCondition, .to = try b.expr(s.cond) },
                .{ .tag = vpiForIncStmt, .to = try b.stmt(s.step) },
                .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
            }, &.{}, &.{}),
            // The parser records `forever s` as `while (1) s` with the `1`
            // on the `forever` keyword itself; IEEE 1364-2005 §26.6.34 draws
            // forever -> stmt alone.
            .while_stmt => |s| if (f.exprs.tag(s.cond) == .int_literal and f.exprs.mainTok(s.cond) == f.stmtTok(id))
                b.code(vpiForever, &.{.{ .tag = vpiStmt, .to = try b.stmt(s.body) }}, &.{}, &.{})
            else
                b.code(vpiWhile, &.{
                    .{ .tag = vpiCondition, .to = try b.expr(s.cond) },
                    .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
                }, &.{}, &.{}),
            .repeat_stmt => |s| b.code(vpiRepeat, &.{
                .{ .tag = vpiCondition, .to = try b.expr(s.count) },
                .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
            }, &.{}, &.{}),
            .event_control => |s| switch (s.kind) {
                .delay => blk: {
                    const at = try b.code(vpiDelayControl, &.{
                        .{ .tag = vpiDelay, .to = try b.expr(s.event) },
                        .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
                    }, &.{}, &.{});
                    if (literal(f, s.event)) |v| b.objects.hot.items[at].delays = try b.arena.dupe(f64, &.{v});
                    break :blk at;
                },
                .event => b.code(vpiEventControl, &.{
                    .{ .tag = vpiCondition, .to = try b.expr(s.event) },
                    .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
                }, &.{}, &.{}),
                .level => b.code(vpiWait, &.{
                    .{ .tag = vpiCondition, .to = try b.expr(s.event) },
                    .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
                }, &.{}, &.{}),
            },
            // §11.6.21 event stmt '->' -> named event.
            .event_trigger => |s| b.code(vpiEventStmt, &.{.{ .tag = vpiNamedEvent, .to = try b.expr(s.target) }}, &.{}, &.{}),
            // disable -> the named block, task or function it disables: AMS
            // §11.6.24 tags the arrow vpiScope, IEEE 1364-2005 §26.6.38
            // vpiExpr, and both are answered.
            .disable => |s| blk: {
                const target = b.lookupAs(f.str(s.name), .scope);
                break :blk b.code(vpiDisable, &.{ .{ .tag = vpiScope, .to = target }, .{ .tag = vpiExpr, .to = target } }, &.{}, &.{});
            },
            .sys_task => |s| blk: {
                const name = f.str(s.name);
                const args = try b.arena.alloc(u32, s.args.len);
                for (s.args, args) |a, *arg| arg.* = if (a == .none) none else try b.expr(a);
                // A.6.9: a name without `$` is a user task enable (§11.6.16
                // task call -> task).
                const user = name.len == 0 or name[0] != '$';
                const at = try b.code(if (user) vpiTaskCall else vpiSysTaskCall, if (user) &.{.{ .tag = vpiTask, .to = b.lookupAs(name, .task) }} else &.{}, &.{.{ .tag = vpiArgument, .items = try b.many(args) }}, &.{});
                b.objects.hot.items[at].name = try b.arena.dupe(u8, name);
                b.objects.hot.items[at].in_analog = b.analog != null;
                b.objects.hot.items[at].src_tok = f.stmtTok(id);
                b.objects.hot.items[at].src_stmt = id;
                break :blk at;
            },
            .contribute => |s| b.contrib(s.lhs, s.rhs),
            // §5.6.7's indirect form: the class's `ind flow`/`ind potential`,
            // with vpiLhs the probe it equates and vpiRhs the equation.
            .indirect => |s| blk: {
                const at = try b.contrib(s.lhs, s.eqn);
                const probe = try b.expr(s.probe);
                // Taken after every append: a row pointer does not survive
                // the array growing.
                const o = &b.objects.hot.items[at];
                o.edges = try b.arena.dupe(Edge, &.{
                    o.edges[0],
                    .{ .tag = vpiLhs, .to = probe },
                    o.edges[1],
                });
                o.props = try b.arena.dupe(Prop, &.{ o.props[0], .{ .prop = vpiDirect, .value = 0 } });
                break :blk at;
            },
            // A jump has no §11.6.21 object.
            .jump => none,
        };
    }

    /// §11.6.20: a contribution to a branch. The branch is the one the
    /// access names when it names a declared branch; `vpiFlow` is whether the
    /// access is the branch discipline's flow access.
    fn contrib(b: *Builder, lhs: Ast.ExprId, rhs: Ast.ExprId) Error!u32 {
        const f = b.file;
        var branch = none;
        var flow: c_int = 0;
        if (f.exprs.tag(lhs) == .branch_access) {
            const first = f.exprs.lhs(lhs);
            if (b.analog) |an| if (f.exprs.tag(first) == .ident and f.exprs.rhs(lhs) == .none) {
                if (an.branches.get(f.str(f.exprs.strOf(first)))) |br| {
                    branch = br;
                    if (b.objects.coldOf(br).disc) |di| if (an.flow_access.get(di)) |acc| {
                        flow = @intFromBool(std.mem.eql(u8, acc, f.str(f.exprs.strOf(lhs))));
                    };
                }
            };
        }
        return b.code(vpiContrib, &.{
            .{ .tag = root.vpiBranch, .to = branch },
            .{ .tag = vpiRhs, .to = try b.expr(rhs) },
        }, &.{}, &.{
            .{ .prop = root.vpiFlow, .value = flow },
            .{ .prop = vpiDirect, .value = 1 },
        });
    }

    // ----------------------------------------------------------- expressions

    /// The object a name denotes from this scope: §6.7's upward search over
    /// the full names, innermost first.
    pub fn lookup(b: *Builder, name: []const u8) u32 {
        return b.lookupAs(name, .any);
    }

    const Lookup = enum { any, function, task, scope };

    /// §26.6.18's implicit result variable shares the function's name.
    /// Expression identifiers find that variable, but a recursive call
    /// must continue outward to the function declaration. Task enables and
    /// disables likewise request declarations rather than local variables.
    fn lookupAs(b: *Builder, name: []const u8, want: Lookup) u32 {
        var path = b.path;
        while (true) {
            var buf: [root.name_buf_len]u8 = undefined;
            const full_name = if (path.len == 0)
                std.mem.print(&buf, "{s}.{s}", .{ b.top_name, name }) catch return none
            else
                std.mem.print(&buf, "{s}.{s}.{s}", .{ b.top_name, path, name }) catch return none;
            if (b.names.get(full_name)) |at| {
                const o = b.objects.hot.items[at];
                const matches = switch (want) {
                    .any => true,
                    .function => o.kind == .code and o.vtype == vpiFunction,
                    .task => o.kind == .code and o.vtype == vpiTask,
                    .scope => o.kind == .code and (o.vtype == vpiTask or o.vtype == vpiFunction or o.vtype == vpiNamedBegin or o.vtype == vpiNamedFork),
                };
                if (matches) return at;
            }
            if (path.len == 0) return none;
            path = path[0 .. std.mem.findScalarLast(u8, path, '.') orelse 0];
        }
    }

    /// Builds or resolves the object for expression `id`; returns its index,
    /// or `none` for `.none` or a form this model does not hold. An object
    /// built here remembers `id`, which §26.6.26 b)'s vpiDecompile spells;
    /// one resolved by name is the declared object, and keeps none.
    pub fn expr(b: *Builder, id: Ast.ExprId) Error!u32 {
        const at = try b.exprObj(id);
        if (at == none) return at;
        const o = &b.objects.hot.items[at];
        if ((o.kind == .code or o.kind == .constant) and o.full.len == 0 and o.src_expr == .none) {
            o.src_expr = id;
            o.expr_scope = .of(b.scope);
            o.in_analog = b.analog != null;
        }
        try b.attributes(at, .{ .kind = .expression, .tok = b.file.exprs.mainTok(id) }, false);
        return at;
    }

    fn exprObj(b: *Builder, id: Ast.ExprId) Error!u32 {
        if (id == .none) return none;
        const ex = &b.file.exprs;
        return switch (ex.tag(id)) {
            .ident => b.lookup(b.file.str(ex.strOf(id))),
            .hier_ident => blk: {
                const parts = ex.nameParts(id);
                var len: usize = parts.len -| 1;
                for (parts) |p| len += b.file.str(p).len;
                var name: std.ArrayList(u8) = try .initCapacity(b.arena, len);
                for (parts, 0..) |p, k| {
                    if (k != 0) name.appendAssumeCapacity('.');
                    name.appendSliceAssumeCapacity(b.file.str(p));
                }
                break :blk b.names.get(name.items) orelse b.lookup(name.items);
            },
            // IEEE 1364-2005 §26.6.26 vpiConstType: the base the literal was
            // written in (an unsized one without a base format is decimal,
            // A.8.7 unsigned_number).
            .int_literal => blk: {
                const lit = ex.intLiteral(id);
                break :blk b.constant(.{ .int = lit.value }, if (lit.width == 0) 32 else lit.width, switch (lit.radix) {
                    2 => vpiBinaryConst,
                    8 => vpiOctConst,
                    16 => vpiHexConst,
                    else => root.vpiDecConst,
                });
            },
            .real_literal => b.constant(.{ .real = ex.realValue(id) }, 64, root.vpiRealConst),
            .str_literal => b.constant(.{ .str = try b.arena.dupe(u8, b.file.str(ex.strOf(id))) }, 0, root.vpiStringConst),
            .logic_literal => blk: {
                const lit = ex.logicValue(id);
                // A value with no x or z that fits 64 bits is an integer
                // constant; anything else is a constant whose value this
                // model does not carry.
                const known = for (lit.unknowns()) |u| {
                    if (u != 0) break false;
                } else true;
                const v = lit.values();
                const fits = v.len == 1 or (v.len > 1 and std.mem.allEqual(u64, v[1..], 0));
                break :blk b.constant(if (known and fits) .{ .int = @bitCast(v[0]) } else null, lit.width, 0);
            },
            .unary => b.operation(unaryOp(ex.unOp(id)), &.{ex.lhs(id)}),
            .binary => b.operation(binaryOp(ex.binOp(id)), &.{ ex.lhs(id), ex.rhs(id) }),
            .ternary => b.operation(vpiConditionOp, &.{ ex.lhs(id), ex.rhs(id), ex.ternaryElse(id) }),
            .concat => b.operation(vpiConcatOp, ex.args(id)),
            // §11.6.19 NOTE: "For an operator whose type is vpiMultiConcat,
            // the first operand shall be the multiplier expression." IEEE
            // 1364-2005 §26.6.26 a): "The remaining operands shall be the
            // expressions within the concatenation". A digital parse keeps
            // the braces of that concatenation as a `.concat` of its own,
            // the one element of `rhs`.
            .multi_concat => blk: {
                var inner = ex.rhs(id);
                if (ex.tag(inner) == .concat and ex.args(inner).len == 1 and ex.tag(ex.args(inner)[0]) == .concat) inner = ex.args(inner)[0];
                const one = [1]Ast.ExprId{inner};
                const rest: []const Ast.ExprId = if (ex.tag(inner) == .concat) ex.args(inner) else &one;
                const ops = try b.arena.alloc(Ast.ExprId, 1 + rest.len);
                ops[0] = ex.lhs(id);
                @memcpy(ops[1..], rest);
                break :blk b.operation(vpiMultiConcatOp, ops);
            },
            .event_posedge => b.operation(vpiPosedgeOp, &.{ex.lhs(id)}),
            .event_negedge => b.operation(vpiNegedgeOp, &.{ex.lhs(id)}),
            .event_or => b.operation(vpiEventOrOp, &.{ ex.lhs(id), ex.rhs(id) }),
            .index => b.select(id),
            .sys_call, .call => blk: {
                const args = try b.arena.alloc(u32, ex.args(id).len);
                for (ex.args(id), args) |a, *arg| arg.* = try b.expr(a);
                const name = b.file.str(ex.strOf(id));
                const sys = ex.tag(id) == .sys_call;
                const func = if (sys) none else b.lookupAs(name, .function);
                // IEEE 1364-2005 §26.6.19 func call -> type int: vpiFuncType,
                // the function's (a system function's is computed in property.zig).
                var ftype: ?Prop = null;
                if (func != none) for (b.objects.hot.items[func].props) |p| {
                    if (p.prop == vpiFuncType) ftype = p;
                };
                const at = try b.code(if (sys) vpiSysFuncCall else vpiFuncCall, if (sys) &.{} else &.{.{ .tag = vpiFunction, .to = func }}, &.{.{ .tag = vpiArgument, .items = try b.many(args) }}, if (ftype) |p| &.{p} else &.{});
                b.objects.hot.items[at].name = try b.arena.dupe(u8, name);
                b.objects.hot.items[at].in_analog = b.analog != null;
                b.objects.hot.items[at].src_tok = ex.mainTok(id);
                break :blk at;
            },
            // §11.6.19 accessfunc -> branches, discipline.
            .branch_access => blk: {
                var branch = none;
                if (b.analog) |an| {
                    const first = ex.lhs(id);
                    if (ex.tag(first) == .ident and ex.rhs(id) == .none) branch = an.branches.get(b.file.str(ex.strOf(first))) orelse none;
                }
                const disc = if (branch != none) b.objects.coldOf(branch).disc orelse none else none;
                const at = try b.code(vpiAccessFunc, &.{
                    .{ .tag = root.vpiBranch, .to = branch },
                    .{ .tag = root.vpiDiscipline, .to = disc },
                }, &.{}, &.{});
                b.objects.hot.items[at].name = try b.arena.dupe(u8, b.file.str(ex.strOf(id)));
                break :blk at;
            },
            // Not modelled: the analog operators and filters, event
            // functions, patterns, infinities. No object.
            .builtin_call, .filter_call, .noise_call, .port_access, .assign_pattern, .pattern_repl, .range, .indexed_range, .pos_inf, .neg_inf, .event_initial_step, .event_final_step, .event_driver_update, .event_function => none,
        };
    }

    fn constant(b: *Builder, v: ?root.Const, width: u32, const_type: c_int) Error!u32 {
        return b.add(.{ .kind = .constant, .owner = .none, .name = "", .full = "", .size = width, .value = v, .const_type = const_type });
    }

    /// §11.6.19 a vpiOperation of type `op` over `operands`, each built as an
    /// expression first; in no scope, as every expression is. Invalidates
    /// pointers into `objects.hot.items`.
    pub fn operation(b: *Builder, op: c_int, operands: []const Ast.ExprId) Error!u32 {
        const items = try b.arena.alloc(u32, operands.len);
        for (operands, items) |o, *item| item.* = try b.expr(o);
        const at = try b.code(vpiOperation, &.{}, &.{.{ .tag = vpiOperand, .items = try b.many(items) }}, &.{.{ .prop = vpiOpType, .value = op }});
        b.objects.hot.items[at].owner = .none;
        return at;
    }

    /// `base[i]`, `base[msb:lsb]` and `base[i +: w]`: an array element is the
    /// memory word or variable select the model already holds (§11.6.18); a
    /// bit of a vector is a net bit or reg bit with vpiParent and vpiIndex; a
    /// range is §11.6.19's part select, and an IEEE 1364-2005 §5.2.1
    /// indexed part-select is §26.6.26's, with its base and width.
    fn select(b: *Builder, id: Ast.ExprId) Error!u32 {
        const ex = &b.file.exprs;
        var event_base = id;
        var rank: usize = 0;
        while (ex.tag(event_base) == .index) : (event_base = ex.lhs(event_base)) rank += 1;
        if (ex.tag(event_base) == .ident or ex.tag(event_base) == .hier_ident) {
            const array = try b.expr(event_base);
            if (array != none and b.objects.hot.items[array].vtype == vpiNamedEventArray) {
                const indices = try b.arena.alloc(u32, rank);
                const values = try b.arena.alloc(?i64, rank);
                var x = id;
                for (indices, values) |*index, *v| {
                    index.* = try b.expr(ex.rhs(x));
                    v.* = try b.eventIndexValue(ex.rhs(x));
                    x = ex.lhs(x);
                }
                for (b.objects.coldOf(array).members) |member| {
                    for (b.objects.hot.items[member].lists) |l| {
                        if (l.tag != vpiIndex or l.items.len != rank) continue;
                        const matches = for (l.items, values) |want, have| {
                            if (have == null or have.? != b.objects.hot.items[want].value.?.int) break false;
                        } else true;
                        if (matches) return member;
                    }
                }
                const automatic = b.automatic or b.objects.hot.items[array].automatic;
                const at = try b.code(vpiNamedEvent, &.{ .{ .tag = vpiParent, .to = array }, .{ .tag = vpiIndex, .to = indices[0] } }, &.{.{ .tag = vpiIndex, .items = indices }}, &.{ .{ .prop = root.vpiArray, .value = 1 }, .{ .prop = root.vpiAutomatic, .value = @intFromBool(automatic) } });
                b.objects.hot.items[at].automatic = automatic;
                (try b.objects.coldFor(at)).event_ref = .{ .expr = id, .scope = b.engine };
                return at;
            }
        }
        const ix = ex.rhs(id);
        const base = try b.expr(ex.lhs(id));
        if (ex.tag(ix) == .indexed_range) {
            const at = try b.code(vpiIndexedPartSelect, &.{
                .{ .tag = vpiParent, .to = base },
                .{ .tag = vpiBaseExpr, .to = try b.expr(ex.lhs(ix)) },
                .{ .tag = vpiWidthExpr, .to = try b.expr(ex.rhs(ix)) },
            }, &.{}, &.{.{ .prop = vpiIndexedPartSelectType, .value = if (ex.extraOf(ix) == 0) vpiPosIndexed else vpiNegIndexed }});
            b.objects.hot.items[at].owner = .none;
            return at;
        }
        if (base != none) {
            const members = b.objects.coldOf(base).members;
            if (members.len != 0 and ex.tag(ix) == .int_literal) {
                const want = ex.intValue(ix);
                for (members) |m| {
                    const c = b.objects.hot.items[m].index.get() orelse continue;
                    if (b.objects.hot.items[c].value.?.int == want) return m;
                }
            }
        }
        if (ex.tag(ix) == .range) {
            const at = try b.code(vpiPartSelect, &.{
                .{ .tag = vpiParent, .to = base },
                .{ .tag = vpiLeftRange, .to = try b.expr(ex.lhs(ix)) },
                .{ .tag = vpiRightRange, .to = try b.expr(ex.rhs(ix)) },
            }, &.{}, &.{});
            b.objects.hot.items[at].owner = .none;
            return at;
        }
        const is_net = base != none and b.objects.hot.items[base].kind == .net;
        const at = try b.code(if (is_net) vpiNetBit else vpiRegBit, &.{
            .{ .tag = vpiParent, .to = base },
            .{ .tag = vpiIndex, .to = try b.expr(ix) },
        }, &.{}, &.{});
        b.objects.hot.items[at].owner = .none;
        return at;
    }

    /// Constant source selects denote the declared element, including
    /// negative bounds and parameter expressions. Use the engine's integer
    /// rules; a variable or application function is never evaluated here.
    fn eventIndexValue(b: *Builder, e: Ast.ExprId) Error!?i64 {
        const r = b.run orelse return null;
        return r.vpiConstantIndex(b.arena, b.engine, e) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.NotElaborated;
    }
};

/// Annex G's vpiPrimType for a §7.8 gate.
fn gateType(k: Ast.GateKind) c_int {
    return switch (k) {
        .g_and => 1,
        .g_nand => 2,
        .g_nor => 3,
        .g_or => 4,
        .g_xor => 5,
        .g_xnor => 6,
        .g_buf => 7,
        .g_not => 8,
        .g_bufif0 => 9,
        .g_bufif1 => 10,
        .g_notif0 => 11,
        .g_notif1 => 12,
    };
}

/// Annex G's vpiPrimType for a §7.1 switch.
fn switchType(k: Ast.SwitchKind) c_int {
    return switch (k) {
        .nmos => 13,
        .pmos => 14,
        .cmos => 15,
        .rnmos => 16,
        .rpmos => 17,
        .rcmos => 18,
        .rtran => 19,
        .rtranif0 => 20,
        .rtranif1 => 21,
        .tran => 22,
        .tranif0 => 23,
        .tranif1 => 24,
    };
}

/// Annex G's strength code of a §7.9 strength level: one bit per level,
/// vpiHiZ 0x01 up to vpiSupplyDrive 0x80.
fn drive(s: Ast.Strength) c_int {
    return @as(c_int, 1) << @intCast(@backingInt(s));
}

/// §11.6.14 the UDP definitions of `file`, design-wide (the diagram's
/// circled arrow): each with its io decls (the output, then the inputs) and
/// its table entries, whose vpiSize is "number of symbol entries" — one per
/// input field (an edge `(01)` is one field), one for the current state of
/// a sequential entry, one for the output. An entry's value is its
/// decompilation, `1 1 : ? : 1`: the fields space-separated, a colon between
/// columns (§26.6.14 Details a).
pub fn udpDefns(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    objects: *model.Rows,
    file: *const Ast.SourceFile,
    attrs: *const @import("attributes.zig").ByOwner,
    out: *std.AutoHashMapUnmanaged(Ast.StrId, u32),
) Error![]const u32 {
    const defns = try arena.alloc(u32, file.udps.len);
    for (file.udps, defns) |*u, *at| {
        const ios = try arena.alloc(u32, u.ports.len);
        for (u.ports, ios, 0..) |p, *io, k| {
            io.* = @intCast(objects.hot.items.len);
            try objects.append(.{ .kind = .code, .owner = .none, .name = try arena.dupe(u8, file.str(p)), .full = "", .vtype = vpiIODecl, .props = try ioProps(arena, if (k == 0) root.vpiOutput else root.vpiInput, 1, false) });
        }
        const rows = try arena.alloc(u32, u.rows.len);
        for (u.rows, rows) |r, *row| {
            var fields: c_int = 0;
            var in_edge = false;
            // Each input symbol and its separator, then two " : c" columns.
            var text: std.ArrayList(u8) = try .initCapacity(arena, 2 * r.inputs.len + 8);
            for (r.inputs) |c| switch (c) {
                ' ', '\t' => {},
                else => {
                    if (!in_edge and text.items.len != 0) text.appendAssumeCapacity(' ');
                    text.appendAssumeCapacity(c);
                    if (c == '(') in_edge = true;
                    if (c == ')') in_edge = false;
                    if (!in_edge) fields += 1;
                },
            };
            if (u.is_sequential) text.printAssumeCapacity(" : {c}", .{r.state});
            text.printAssumeCapacity(" : {c}", .{r.output});
            row.* = @intCast(objects.hot.items.len);
            try objects.append(.{ .kind = .code, .owner = .none, .name = "", .full = "", .vtype = vpiTableEntry, .value = .{ .str = text.items }, .props = try arena.dupe(Prop, &.{
                .{ .prop = vpiSize, .value = fields + @intFromBool(u.is_sequential) + 1 },
            }) });
        }
        // A.5.3's `initial output = init_val`: an initial process whose
        // statement assigns the output its io decl names.
        var init = none;
        if (u.init != .none) {
            var no_names: std.StringHashMapUnmanaged(u32) = .empty;
            var no_lists: ScopeLists = .{};
            var b: Builder = .{ .gpa = gpa, .arena = arena, .objects = objects, .file = file, .names = &no_names, .top_name = "", .scope = 0, .path = "", .lists = &no_lists, .attrs = attrs };
            const rhs = try b.expr(u.init);
            const assign: u32 = @intCast(objects.hot.items.len);
            try objects.append(.{ .kind = .code, .owner = .none, .name = "", .full = "", .vtype = vpiAssignment, .edges = try arena.dupe(Edge, &.{
                .{ .tag = vpiLhs, .to = ios[0] },
                .{ .tag = vpiRhs, .to = rhs },
            }), .props = try arena.dupe(Prop, &.{.{ .prop = vpiBlocking, .value = 1 }}) });
            init = @intCast(objects.hot.items.len);
            try objects.append(.{ .kind = .code, .owner = .none, .name = "", .full = "", .vtype = vpiInitial, .edges = try arena.dupe(Edge, &.{.{ .tag = vpiStmt, .to = assign }}) });
        }
        at.* = @intCast(objects.hot.items.len);
        try objects.append(.{
            .kind = .code,
            .owner = .none,
            .name = "",
            .full = "",
            .vtype = vpiUdpDefn,
            .def_name = try arena.dupe(u8, file.str(u.name)),
            .props = try arena.dupe(Prop, &.{
                .{ .prop = vpiSize, .value = @intCast(u.ports.len - 1) },
                .{ .prop = vpiPrimType, .value = if (u.is_sequential) vpiSeqPrim else vpiCombPrim },
            }),
            .edges = try arena.dupe(Edge, &.{.{ .tag = vpiInitial, .to = init }}),
            .lists = try arena.dupe(List, &.{
                .{ .tag = vpiIODecl, .items = ios },
                .{ .tag = vpiTableEntry, .items = rows },
            }),
        });
        try out.put(gpa, u.name, at.*);
    }
    return defns;
}

fn direction(d: Ast.Direction) c_int {
    return switch (d) {
        .input => root.vpiInput,
        .output => root.vpiOutput,
        .inout => root.vpiInout,
        .unspecified => root.vpiNoDirection,
    };
}

/// IEEE 1364-2005 §26.6.4 io decl: direction, size, and whether it is a
/// scalar, a vector and signed. `size` is vpiUndefined when the range did not
/// fold, and then scalar and vector are not answered either.
fn ioProps(arena: std.mem.Allocator, dir: c_int, size: c_int, signed: bool) Error![]const Prop {
    if (size < 0) return arena.dupe(Prop, &.{ .{ .prop = vpiDirection, .value = dir }, .{ .prop = vpiSize, .value = size }, .{ .prop = root.vpiSigned, .value = @intFromBool(signed) } });
    return arena.dupe(Prop, &.{
        .{ .prop = vpiDirection, .value = dir },
        .{ .prop = vpiSize, .value = size },
        .{ .prop = root.vpiScalar, .value = @intFromBool(size == 1) },
        .{ .prop = root.vpiVector, .value = @intFromBool(size > 1) },
        .{ .prop = root.vpiSigned, .value = @intFromBool(signed) },
    });
}

/// Annex G's vpiFuncType of a function whose result is `v` (A.2.6
/// function_range_or_type).
fn funcType(v: Ast.VarDecl) c_int {
    if (v.ty == .real) return vpiRealFunc;
    return switch (v.storage) {
        .variable => vpiIntFunc,
        .time => vpiTimeFunc,
        .reg => if (v.is_signed) vpiSizedSignedFunc else vpiSizedFunc,
    };
}

fn packedWidth(file: *const Ast.SourceFile, v: Ast.VarDecl) c_int {
    if (v.storage == .time) return 64;
    if (v.ty == .integer and v.storage != .reg) return 32;
    if (v.ty == .real) return 64;
    const range = v.packed_range orelse return 1;
    if (file.exprs.tag(range.msb) != .int_literal or file.exprs.tag(range.lsb) != .int_literal) return root.vpiUndefined;
    return @intCast(@abs(file.exprs.intValue(range.msb) - file.exprs.intValue(range.lsb)) + 1);
}

/// A literal delay, as a real: an integer or a real literal. Null otherwise.
fn literal(file: *const Ast.SourceFile, e: Ast.ExprId) ?f64 {
    return switch (file.exprs.tag(e)) {
        .int_literal => @floatFromInt(file.exprs.intValue(e)),
        .real_literal => file.exprs.realValue(e),
        else => null, // else: only a literal folds without the elaborator
    };
}

fn unaryOp(op: Ast.UnaryOp) c_int {
    return switch (op) {
        .plus => vpiPlusOp,
        .minus => vpiMinusOp,
        .logical_not => vpiNotOp,
        .bit_not => vpiBitNegOp,
        .reduce_and => vpiUnaryAndOp,
        .reduce_nand => vpiUnaryNandOp,
        .reduce_or => vpiUnaryOrOp,
        .reduce_nor => vpiUnaryNorOp,
        .reduce_xor => vpiUnaryXorOp,
        .reduce_xnor => vpiUnaryXNorOp,
    };
}

fn binaryOp(op: Ast.BinaryOp) c_int {
    return switch (op) {
        .add => vpiAddOp,
        .sub => vpiSubOp,
        .mul => vpiMultOp,
        .div => vpiDivOp,
        .mod => vpiModOp,
        .pow => vpiPowerOp,
        .eq => vpiEqOp,
        .neq => vpiNeqOp,
        .case_eq => vpiCaseEqOp,
        .case_neq => vpiCaseNeqOp,
        .lt => vpiLtOp,
        .le => vpiLeOp,
        .gt => vpiGtOp,
        .ge => vpiGeOp,
        .logical_and => vpiLogAndOp,
        .logical_or => vpiLogOrOp,
        .bit_and => vpiBitAndOp,
        .bit_or => vpiBitOrOp,
        .bit_xor => vpiBitXorOp,
        .bit_xnor => vpiBitXNorOp,
        .shl => vpiLShiftOp,
        .shr => vpiRShiftOp,
        .ashl => vpiArithLShiftOp,
        .ashr => vpiArithRShiftOp,
    };
}

fn polarity(p: Ast.SpecPolarity) c_int {
    return switch (p) {
        .none => vpiUnknown,
        .positive => vpiPositive,
        .negative => vpiNegative,
    };
}

/// A.7.5.1's twelve commands as §11.6.15 describes them: vpiTchkType, whether
/// a data event accompanies the reference one (and whether it is written
/// first, `$setup` alone), the 0-based argument slots that
/// are "limits" (§12.11), and the notifier's slot (A.7.5.2; `$width`'s
/// optional threshold comes before it).
const TchkKind = struct { type: c_int, data: bool, limits: [2]usize, n_limits: usize, notifier: usize, data_first: bool = false };
const tchk_kinds = std.StaticStringMap(TchkKind).initComptime(.{
    .{ "$setup", TchkKind{ .type = 1, .data = true, .limits = .{ 2, 0 }, .n_limits = 1, .notifier = 3, .data_first = true } },
    .{ "$hold", TchkKind{ .type = 2, .data = true, .limits = .{ 2, 0 }, .n_limits = 1, .notifier = 3 } },
    .{ "$period", TchkKind{ .type = 3, .data = false, .limits = .{ 1, 0 }, .n_limits = 1, .notifier = 2 } },
    .{ "$width", TchkKind{ .type = 4, .data = false, .limits = .{ 1, 0 }, .n_limits = 1, .notifier = 3 } },
    .{ "$skew", TchkKind{ .type = 5, .data = true, .limits = .{ 2, 0 }, .n_limits = 1, .notifier = 3 } },
    .{ "$recovery", TchkKind{ .type = 6, .data = true, .limits = .{ 2, 0 }, .n_limits = 1, .notifier = 3 } },
    .{ "$nochange", TchkKind{ .type = 7, .data = true, .limits = .{ 2, 3 }, .n_limits = 2, .notifier = 4 } },
    .{ "$setuphold", TchkKind{ .type = 8, .data = true, .limits = .{ 2, 3 }, .n_limits = 2, .notifier = 4 } },
    .{ "$fullskew", TchkKind{ .type = 9, .data = true, .limits = .{ 2, 3 }, .n_limits = 2, .notifier = 4 } },
    .{ "$recrem", TchkKind{ .type = 10, .data = true, .limits = .{ 2, 3 }, .n_limits = 2, .notifier = 4 } },
    .{ "$removal", TchkKind{ .type = 11, .data = true, .limits = .{ 2, 0 }, .n_limits = 1, .notifier = 3 } },
    .{ "$timeskew", TchkKind{ .type = 12, .data = true, .limits = .{ 2, 0 }, .n_limits = 1, .notifier = 3 } },
});

// ---------------------------------------------------------------------------
// Tests: the tables. The rows themselves are tests/unit.zig's `vpi_tests`,
// over designs.
// ---------------------------------------------------------------------------

test "typeName spells every behavioural type the builders make, as its constant is named" {
    // Every vtype a `code`/`add` call above (and model.zig's addRange,
    // attributes.zig's attach, model_digital.zig's gen scopes) writes.
    inline for (.{
        "vpiAlways",
        "vpiAssignStmt",
        "vpiAssignment",
        "vpiBegin",
        "vpiCase",
        "vpiCaseItem",
        "vpiContAssign",
        "vpiDeassign",
        "vpiDelayControl",
        "vpiDisable",
        "vpiEventControl",
        "vpiEventStmt",
        "vpiFor",
        "vpiForce",
        "vpiForever",
        "vpiFork",
        "vpiFuncCall",
        "vpiFunction",
        "vpiIf",
        "vpiIfElse",
        "vpiInitial",
        "vpiAttribute",
        "vpiIODecl",
        "vpiNamedBegin",
        "vpiNamedEvent",
        "vpiNamedEventArray",
        "vpiNamedFork",
        "vpiNetBit",
        "vpiNullStmt",
        "vpiOperation",
        "vpiPartSelect",
        "vpiIndexedPartSelect",
        "vpiRegBit",
        "vpiRelease",
        "vpiRepeat",
        "vpiRepeatControl",
        "vpiSysFuncCall",
        "vpiSysTaskCall",
        "vpiTask",
        "vpiTaskCall",
        "vpiWait",
        "vpiWhile",
        "vpiParamAssign",
        "vpiGate",
        "vpiSwitch",
        "vpiPrimTerm",
        "vpiTableEntry",
        "vpiUdp",
        "vpiUdpDefn",
        "vpiModPath",
        "vpiPathTerm",
        "vpiTchk",
        "vpiTchkTerm",
        "vpiRange",
        "vpiGenScopeArray",
        "vpiGenScope",
        "vpiAnalog",
        "vpiContrib",
        "vpiAccessFunc",
    }) |decl| try std.testing.expectEqualStrings(decl, typeName(@field(@This(), decl)) orelse "(none)");
}

test "A.7.5.1: each timing check's limits precede its notifier; only $setup writes data first" {
    var types: u32 = 0;
    for (tchk_kinds.keys(), tchk_kinds.values()) |name, k| {
        try std.testing.expect(k.n_limits >= 1 and k.n_limits <= k.limits.len);
        for (k.limits[0..k.n_limits]) |l| try std.testing.expect(l < k.notifier);
        try std.testing.expectEqual(std.mem.eql(u8, name, "$setup"), k.data_first);
        // $period and $width are the single-event checks.
        const single = std.mem.eql(u8, name, "$period") or std.mem.eql(u8, name, "$width");
        try std.testing.expectEqual(!single, k.data);
        types |= @as(u32, 1) << @intCast(k.type);
    }
    // vpiTchkType 1..12, each once.
    try std.testing.expectEqual(@as(u32, 0x1FFE), types);
}

test "Annex G vpiPrimType: gates 1-12, switches 13-24, each once; a gate's vpiDefName is its keyword" {
    var gates: u32 = 0;
    for (std.enums.values(Ast.GateKind)) |k| {
        gates |= @as(u32, 1) << @intCast(gateType(k));
        // `module` spells a gate's vpiDefName as its tag behind `g_` (A.3.4).
        try std.testing.expect(std.mem.startsWith(u8, @tagName(k), "g_"));
    }
    try std.testing.expectEqual(@as(u32, 0x1FFE), gates);
    var switches: u32 = 0;
    for (std.enums.values(Ast.SwitchKind)) |k| switches |= @as(u32, 1) << @intCast(switchType(k));
    try std.testing.expectEqual(@as(u32, 0x1FFE000), switches);
}

test "§7.9: a strength is one Annex G bit, highz 0x01 up to supply 0x80" {
    var all: c_int = 0;
    for (std.enums.values(Ast.Strength)) |s| {
        const bit = drive(s);
        try std.testing.expectEqual(@as(u32, 1), @popCount(bit));
        all |= bit;
    }
    try std.testing.expectEqual(@as(c_int, 0xFF), all);
    try std.testing.expectEqual(@as(c_int, 0x40), drive(.strong));
    try std.testing.expectEqual(@as(c_int, 0x01), drive(.highz));
}
