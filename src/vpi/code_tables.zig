//! The fixed mappings from the AST's enums to Annex G's numbers that the
//! behavioural rows carry (primitive types, strengths, operators, directions,
//! function types, timing-check kinds), the per-scope behavioural lists, and
//! the vpiType spellings of the behavioural classes.
//! Cites: IEEE 1364-2005 Annex G, §7.9, §26.6.4, §26.6.19, A.7.5.1.
//!
//! Contents:
//! - `pub const ScopeLists = struct`
//! - `pub fn ScopeLists.deinit(s: *ScopeLists, gpa: std.mem.Allocator) void`
//! - `pub fn ScopeLists.freeze(s: *const ScopeLists, arena: std.mem.Allocator) ![]const List`
//! - `pub const tchk_kinds = std.StaticStringMap(TchkKind).initComptime(.{`
//! - `pub fn typeName(t: c_int) ?[]const u8`
//! - `pub fn gateType(k: Ast.GateKind) c_int`
//! - `pub fn defName(o: *const Obj) ?[]const u8`
//! - `pub fn switchType(k: Ast.SwitchKind) c_int`
//! - `pub fn drive(s: Ast.Strength) c_int`
//! - `pub fn direction(d: Ast.Direction) c_int`
//! - `pub fn ioProps(arena: std.mem.Allocator, dir: c_int, size: c_int, signed: bool) Error![]const Prop`
//! - `pub fn funcType(v: Ast.VarDecl) c_int`
//! - `pub fn packedWidth(file: *const Ast.SourceFile, v: Ast.VarDecl) c_int`
//! - `pub fn literal(file: *const Ast.SourceFile, e: Ast.ExprId) ?f64`
//! - `pub fn unaryOp(op: Ast.UnaryOp) c_int`
//! - `pub fn binaryOp(op: Ast.BinaryOp) c_int`
//! - `pub fn polarity(p: Ast.SpecPolarity) c_int`

const std = @import("std");
const Ast = @import("frontend").Ast;
const schema = @import("schema.zig");
const ObjId = schema.ObjId;
const session = @import("session.zig");
const user = @import("vpi_user.zig");
const Error = session.Error;
const List = schema.List;
const Obj = schema.Obj;
const Prop = schema.Prop;

/// The per-scope double arrows of §11.6.1 this file fills.
pub const ScopeLists = struct {
    cont_assigns: std.ArrayList(ObjId) = .empty,
    processes: std.ArrayList(ObjId) = .empty,
    tasks: std.ArrayList(ObjId) = .empty,
    functions: std.ArrayList(ObjId) = .empty,
    events: std.ArrayList(ObjId) = .empty,
    event_arrays: std.ArrayList(ObjId) = .empty,
    primitives: std.ArrayList(ObjId) = .empty,
    mod_paths: std.ArrayList(ObjId) = .empty,
    tchks: std.ArrayList(ObjId) = .empty,
    gen_arrays: std.ArrayList(ObjId) = .empty,
    /// IEEE 1364-2005 §26.6.12: the `#(...)` assignments overriding this
    /// instance's parameters, written in its parent (model_digital.zig).
    param_assigns: std.ArrayList(ObjId) = .empty,
    /// IEEE 1364-2005 §26.6.3 the task, function and named block scopes
    /// written directly in the module; `model.freeze` joins its instances
    /// and gen scopes to them for `vpiInternalScope`.
    internal: std.ArrayList(ObjId) = .empty,

    /// Frees the lists (owned by `gpa`); the rows they index stay.
    pub fn deinit(s: *ScopeLists, gpa: std.mem.Allocator) void {
        inline for (@typeInfo(ScopeLists).@"struct".field_names) |name| @field(s, name).deinit(gpa);
    }

    /// Frozen as tagged rows, the shape `vpi_iterate(tag, module)` reads.
    pub fn freeze(s: *const ScopeLists, arena: std.mem.Allocator) ![]const List {
        return arena.dupe(List, &.{
            .{ .tag = user.vpiContAssign, .items = try arena.dupe(ObjId, s.cont_assigns.items) },
            .{ .tag = user.vpiProcess, .items = try arena.dupe(ObjId, s.processes.items) },
            .{ .tag = user.vpiTask, .items = try arena.dupe(ObjId, s.tasks.items) },
            .{ .tag = user.vpiFunction, .items = try arena.dupe(ObjId, s.functions.items) },
            .{ .tag = user.vpiNamedEvent, .items = try arena.dupe(ObjId, s.events.items) },
            .{ .tag = user.vpiNamedEventArray, .items = try arena.dupe(ObjId, s.event_arrays.items) },
            .{ .tag = user.vpiPrimitive, .items = try arena.dupe(ObjId, s.primitives.items) },
            .{ .tag = user.vpiModPath, .items = try arena.dupe(ObjId, s.mod_paths.items) },
            .{ .tag = user.vpiTchk, .items = try arena.dupe(ObjId, s.tchks.items) },
            .{ .tag = user.vpiGenScopeArray, .items = try arena.dupe(ObjId, s.gen_arrays.items) },
            .{ .tag = user.vpiParamAssign, .items = try arena.dupe(ObjId, s.param_assigns.items) },
        });
    }
};

pub const tchk_kinds = std.StaticStringMap(TchkKind).initComptime(.{
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

/// A.7.5.1's twelve commands as §11.6.15 describes them: vpiTchkType, whether
/// a data event accompanies the reference one (and whether it is written
/// first, `$setup` alone), the 0-based argument slots that
/// are "limits" (§12.11), and the notifier's slot (A.7.5.2; `$width`'s
/// optional threshold comes before it).
const TchkKind = struct { type: c_int, data: bool, limits: [2]usize, n_limits: usize, notifier: usize, data_first: bool = false };

/// The `vpi_get_str(vpiType)` spelling of every type this file makes.
pub fn typeName(t: c_int) ?[]const u8 {
    return switch (t) {
        user.vpiAlways => "vpiAlways",
        user.vpiRange => "vpiRange",
        user.vpiGenScopeArray => "vpiGenScopeArray",
        user.vpiGenScope => "vpiGenScope",
        user.vpiAssignStmt => "vpiAssignStmt",
        user.vpiAssignment => "vpiAssignment",
        user.vpiBegin => "vpiBegin",
        user.vpiCase => "vpiCase",
        user.vpiCaseItem => "vpiCaseItem",
        user.vpiContAssign => "vpiContAssign",
        user.vpiDeassign => "vpiDeassign",
        user.vpiDelayControl => "vpiDelayControl",
        user.vpiDisable => "vpiDisable",
        user.vpiEventControl => "vpiEventControl",
        user.vpiEventStmt => "vpiEventStmt",
        user.vpiFor => "vpiFor",
        user.vpiForce => "vpiForce",
        user.vpiForever => "vpiForever",
        user.vpiFork => "vpiFork",
        user.vpiFuncCall => "vpiFuncCall",
        user.vpiFunction => "vpiFunction",
        user.vpiIf => "vpiIf",
        user.vpiIfElse => "vpiIfElse",
        user.vpiInitial => "vpiInitial",
        user.vpiAttribute => "vpiAttribute",
        user.vpiIODecl => "vpiIODecl",
        user.vpiNamedBegin => "vpiNamedBegin",
        user.vpiNamedEvent => "vpiNamedEvent",
        user.vpiNamedEventArray => "vpiNamedEventArray",
        user.vpiNamedFork => "vpiNamedFork",
        user.vpiNetBit => "vpiNetBit",
        user.vpiNullStmt => "vpiNullStmt",
        user.vpiOperation => "vpiOperation",
        user.vpiPartSelect => "vpiPartSelect",
        user.vpiIndexedPartSelect => "vpiIndexedPartSelect",
        user.vpiRegBit => "vpiRegBit",
        user.vpiRelease => "vpiRelease",
        user.vpiRepeat => "vpiRepeat",
        user.vpiRepeatControl => "vpiRepeatControl",
        user.vpiSysFuncCall => "vpiSysFuncCall",
        user.vpiSysTaskCall => "vpiSysTaskCall",
        user.vpiTask => "vpiTask",
        user.vpiTaskCall => "vpiTaskCall",
        user.vpiWait => "vpiWait",
        user.vpiGate => "vpiGate",
        user.vpiSwitch => "vpiSwitch",
        user.vpiPrimTerm => "vpiPrimTerm",
        user.vpiTableEntry => "vpiTableEntry",
        user.vpiUdp => "vpiUdp",
        user.vpiUdpDefn => "vpiUdpDefn",
        user.vpiWhile => "vpiWhile",
        user.vpiParamAssign => "vpiParamAssign",
        user.vpiAnalog => "vpiAnalog",
        user.vpiContrib => "vpiContrib",
        user.vpiAccessFunc => "vpiAccessFunc",
        user.vpiModPath => "vpiModPath",
        user.vpiPathTerm => "vpiPathTerm",
        user.vpiTchk => "vpiTchk",
        user.vpiTchkTerm => "vpiTchkTerm",
        else => null, // else: not a type this file makes; the caller answers
    };
}

/// Annex G's vpiPrimType for a §7.8 gate.
pub fn gateType(k: Ast.GateKind) c_int {
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

/// §11.6.13/§11.6.14's vpiDefName of `.code` row `o` of the installed
/// design, or null when its class has none. A gate's or switch's is its
/// keyword, read back from its vpiPrimType; a UDP instance's is its
/// definition's.
pub fn defName(o: *const Obj) ?[]const u8 {
    switch (o.vtype) {
        user.vpiUdpDefn => return schema.coldOf(o).def_name,
        user.vpiUdp => return schema.coldOf(session.design.?.obj(schema.edgeTo(o, user.vpiUdpDefn))).def_name,
        user.vpiGate, user.vpiSwitch => {},
        else => return null,
    }
    std.debug.assert(o.props[0].prop == user.vpiPrimType);
    const t = o.props[0].value;
    if (t == user.vpiPullupPrim) return "pullup";
    if (t == user.vpiPulldownPrim) return "pulldown";
    inline for (comptime std.enums.values(Ast.GateKind)) |k| if (gateType(k) == t) return @tagName(k)["g_".len..];
    inline for (comptime std.enums.values(Ast.SwitchKind)) |k| if (switchType(k) == t) return @tagName(k);
    unreachable;
}

/// Annex G's vpiPrimType for a §7.1 switch.
pub fn switchType(k: Ast.SwitchKind) c_int {
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
pub fn drive(s: Ast.Strength) c_int {
    return @as(c_int, 1) << @intCast(@backingInt(s));
}

pub fn direction(d: Ast.Direction) c_int {
    return switch (d) {
        .input => user.vpiInput,
        .output => user.vpiOutput,
        .inout => user.vpiInout,
        .unspecified => user.vpiNoDirection,
    };
}

/// IEEE 1364-2005 §26.6.4 io decl: direction, size, and whether it is a
/// scalar, a vector and signed. `size` is vpiUndefined when the range did not
/// fold, and then scalar and vector are not answered either.
pub fn ioProps(arena: std.mem.Allocator, dir: c_int, size: c_int, signed: bool) Error![]const Prop {
    if (size < 0) return arena.dupe(Prop, &.{ .{ .prop = user.vpiDirection, .value = dir }, .{ .prop = user.vpiSize, .value = size }, .{ .prop = user.vpiSigned, .value = @intFromBool(signed) } });
    return arena.dupe(Prop, &.{
        .{ .prop = user.vpiDirection, .value = dir },
        .{ .prop = user.vpiSize, .value = size },
        .{ .prop = user.vpiScalar, .value = @intFromBool(size == 1) },
        .{ .prop = user.vpiVector, .value = @intFromBool(size > 1) },
        .{ .prop = user.vpiSigned, .value = @intFromBool(signed) },
    });
}

/// Annex G's vpiFuncType of a function whose result is `v` (A.2.6
/// function_range_or_type).
pub fn funcType(v: Ast.VarDecl) c_int {
    if (v.ty == .real) return user.vpiRealFunc;
    return switch (v.storage) {
        .variable => user.vpiIntFunc,
        .time => user.vpiTimeFunc,
        .reg => if (v.is_signed) user.vpiSizedSignedFunc else user.vpiSizedFunc,
    };
}

pub fn packedWidth(file: *const Ast.SourceFile, v: Ast.VarDecl) c_int {
    if (v.storage == .time) return 64;
    if (v.ty == .integer and v.storage != .reg) return 32;
    if (v.ty == .real) return 64;
    const range = v.packed_range orelse return 1;
    if (file.exprs.tag(range.msb) != .int_literal or file.exprs.tag(range.lsb) != .int_literal) return user.vpiUndefined;
    return @intCast(@abs(file.exprs.intValue(range.msb) - file.exprs.intValue(range.lsb)) + 1);
}

/// A literal delay, as a real: an integer or a real literal. Null otherwise.
pub fn literal(file: *const Ast.SourceFile, e: Ast.ExprId) ?f64 {
    return switch (file.exprs.tag(e)) {
        .int_literal => @floatFromInt(file.exprs.intValue(e)),
        .real_literal => file.exprs.realValue(e),
        else => null, // else: only a literal folds without the elaborator
    };
}

pub fn unaryOp(op: Ast.UnaryOp) c_int {
    return switch (op) {
        .plus => user.vpiPlusOp,
        .minus => user.vpiMinusOp,
        .logical_not => user.vpiNotOp,
        .bit_not => user.vpiBitNegOp,
        .reduce_and => user.vpiUnaryAndOp,
        .reduce_nand => user.vpiUnaryNandOp,
        .reduce_or => user.vpiUnaryOrOp,
        .reduce_nor => user.vpiUnaryNorOp,
        .reduce_xor => user.vpiUnaryXorOp,
        .reduce_xnor => user.vpiUnaryXNorOp,
    };
}

pub fn binaryOp(op: Ast.BinaryOp) c_int {
    return switch (op) {
        .add => user.vpiAddOp,
        .sub => user.vpiSubOp,
        .mul => user.vpiMultOp,
        .div => user.vpiDivOp,
        .mod => user.vpiModOp,
        .pow => user.vpiPowerOp,
        .eq => user.vpiEqOp,
        .neq => user.vpiNeqOp,
        .case_eq => user.vpiCaseEqOp,
        .case_neq => user.vpiCaseNeqOp,
        .lt => user.vpiLtOp,
        .le => user.vpiLeOp,
        .gt => user.vpiGtOp,
        .ge => user.vpiGeOp,
        .logical_and => user.vpiLogAndOp,
        .logical_or => user.vpiLogOrOp,
        .bit_and => user.vpiBitAndOp,
        .bit_or => user.vpiBitOrOp,
        .bit_xor => user.vpiBitXorOp,
        .bit_xnor => user.vpiBitXNorOp,
        .shl => user.vpiLShiftOp,
        .shr => user.vpiRShiftOp,
        .ashl => user.vpiArithLShiftOp,
        .ashr => user.vpiArithRShiftOp,
    };
}

pub fn polarity(p: Ast.SpecPolarity) c_int {
    return switch (p) {
        .none => user.vpiUnknown,
        .positive => user.vpiPositive,
        .negative => user.vpiNegative,
    };
}

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
    }) |decl| try std.testing.expectEqualStrings(decl, typeName(@field(user, decl)) orelse "(none)");
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
