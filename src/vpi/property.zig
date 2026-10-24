//! Property reads: §12.5 vpi_get, §12.18 vpi_get_real and §12.12
//! vpi_get_str. A handle and a property -> the integer, real or string §11.6
//! lists for the object's class. A property the class does not have is
//! vpiUndefined (NULL for a string) plus an error, never a zero. Every
//! vpi_get_str answer is in one static buffer (`str_buf`) that the next call
//! overwrites.

const std = @import("std");
const Ast = @import("frontend").Ast;
const analog_run = @import("analog.zig");
const callback = @import("callback.zig");
const code = @import("code.zig");
const decompile = @import("decompile.zig");
const delays = @import("delays.zig");
const root = @import("root.zig");
const run = @import("run.zig");
const systf = @import("systf.zig");
const value = @import("value.zig");

const Obj = root.Obj;
const asIter = root.asIter;
const asObj = root.asObj;
const refused = root.refused;
const enter = root.enter;
const fail = root.fail;
const issued = root.issued;
const name_buf_len = root.name_buf_len;
const object = root.object;
const typeName = root.typeName;
const typeOf = root.typeOf;
const vpiArray = root.vpiArray;
const vpiAutomatic = root.vpiAutomatic;
const vpiCell = root.vpiCell;
const vpiConfig = root.vpiConfig;
const vpiConstType = root.vpiConstType;
const vpiDecompile = root.vpiDecompile;
const vpiDefName = root.vpiDefName;
const vpiDirection = root.vpiDirection;
const vpiFile = root.vpiFile;
const vpiFullName = root.vpiFullName;
const vpiHandle = root.vpiHandle;
const vpiInout = root.vpiInout;
const vpiInput = root.vpiInput;
const vpiIntConst = root.vpiIntConst;
const vpiIsMemory = root.vpiIsMemory;
const vpiIterator = root.vpiIterator;
const vpiIteratorType = root.vpiIteratorType;
const vpiLibrary = root.vpiLibrary;
const vpiLineNo = root.vpiLineNo;
const vpiLocalParam = root.vpiLocalParam;
const vpiName = root.vpiName;
const vpiNetType = root.vpiNetType;
const vpiNoDirection = root.vpiNoDirection;
const vpiOutput = root.vpiOutput;
const vpiPortIndex = root.vpiPortIndex;
const vpiProtected = root.vpiProtected;
const vpiRealConst = root.vpiRealConst;
const vpiScalar = root.vpiScalar;
const vpiSigned = root.vpiSigned;
const vpiSize = root.vpiSize;
const vpiStringConst = root.vpiStringConst;
const vpiTimePrecision = root.vpiTimePrecision;
const vpiTimeUnit = root.vpiTimeUnit;
const vpiTopModule = root.vpiTopModule;
const vpiType = root.vpiType;
const vpiUndefined = root.vpiUndefined;
const vpiVector = root.vpiVector;

// ---------------------------------------------------------------------------
// §12.5 vpi_get
// ---------------------------------------------------------------------------

/// "Should an error occur, `vpi_get()` shall return `vpiUndefined`."
///
/// Every property below is one §11.6 lists for the class it is asked of. Asking
/// for a property a class does not have — `vpiDirection` of a net, `vpiSize` of
/// a module — is an error and not a zero: §11.6.8 simply gives a net no
/// direction, and a 0 would be indistinguishable from `vpiNoDirection`.
pub export fn vpi_get(prop: c_int, obj: vpiHandle) c_int {
    // Not `enter`: callbacks, time queues, events and systf registrations are
    // objects without a design, and a handle to one still has a type.
    if (refused("vpi_get")) return vpiUndefined;
    // A handle VerA issued that is no design object: §12.23's iterator,
    // §11.6.25's callback, §12.30's scheduled event, a systf registration,
    // IEEE 1364-2005 §26.6.16's inter-module path, a time queue. Each has a
    // type and, at most, one property of its own.
    const other: ?c_int = if (asIter(obj) != null) vpiIterator else if (callback.asCb(obj) != null) callback.vpiCallback else if (value.asEvent(obj) != null) value.vpiSchedEvent else if (systf.asSystf(obj) != null) systf.vpiUserSystf else if (delays.asPath(obj) != null) systf.vpiInterModPath else if (run.asQueue(obj) != null) run.vpiTimeQueue else null;
    // IEEE 1364-2005 §26.3.5: "All objects have a vpiIsProtected property",
    // which vpi_user.h numbers as Annex G's vpiProtected (VD-045). No object
    // is protected: §28's `pragma protect` is refused where it is written
    // (E0146).
    if (prop == vpiProtected and (other != null or asObj(obj) != null)) return 0;
    if (root.unansweredProp(prop)) |u| {
        root.failUnanswered("vpi_get", u);
        return vpiUndefined;
    }
    if (other) |t| {
        if (prop == vpiType) return t;
        if (prop == vpiIteratorType) if (asIter(obj)) |it| return it.ty;
        if (prop == value.vpiScheduled) if (value.asEvent(obj)) |e| return @intFromBool(value.scheduled(e));
        fail("NOPROP", "vpi_get: a {s} has no property {d}", .{ typeName(t), prop });
        return vpiUndefined;
    }
    // §12.5's NULL-object case: IEEE 1364-2005 §26.6.1 Details b.
    if (obj == null and (prop == vpiTimeUnit or prop == vpiTimePrecision)) {
        if (root.design) |d| if (d.finest) |f| return f;
    }
    const o = object("vpi_get", obj) orelse return vpiUndefined;
    if (o.kind == .code and prop != vpiType and prop != vpiLineNo) return codeProp(o, prop);
    switch (prop) {
        vpiType => return typeOf(o),
        // IEEE 1364 §26.6.1/§26.6.6-§26.6.8: "is item an array" — an array,
        // or a module, net or reg that is a member of one (a reg that is
        // one is a `.word`). §26.6.8 draws no vpiArray on a var select.
        vpiArray => return switch (o.kind) {
            .reg_array, .var_array, .net_array, .word => 1,
            .module, .net => @intFromBool(o.parent != .none),
            .reg, .integer, .real_var, .time_var, .var_select => 0,
            else => propFail(prop, o),
        },
        code.vpiImplicitDecl => return switch (o.kind) {
            .net => @intFromBool(o.implicit),
            else => propFail(prop, o),
        },
        vpiAutomatic => return switch (o.kind) {
            .reg, .integer, .real_var, .time_var => @intFromBool(o.automatic),
            else => propFail(prop, o),
        },
        vpiIsMemory => return switch (o.kind) {
            .reg_array => 1,
            .var_array, .reg => 0,
            else => propFail(prop, o),
        },
        // §11.6.1 — true for the root of the instance tree, the one module
        // `Elaborate.pickTop` chose.
        vpiTopModule => {
            if (o.kind != .module) return propFail(prop, o);
            return @intFromBool(o.owner == .none);
        },
        vpiTimeUnit, vpiTimePrecision => {
            if (o.kind != .module) return propFail(prop, o);
            const sc = root.design.?.scopes[o.scope];
            return (if (prop == vpiTimeUnit) sc.time_unit else sc.time_precision) orelse propFail(prop, o);
        },
        vpiSize, vpiScalar, vpiVector => {
            // An array's size counts ELEMENTS (§26.6.9 "array size counts
            // members"), everything else's counts bits.
            switch (o.kind) {
                .reg_array, .var_array, .net_array, .module_array => if (prop == vpiSize) return @intCast(o.size) else return propFail(prop, o),
                .port, .net, .reg, .integer, .real_var, .time_var, .word, .var_select, .constant, .node, .branch, .quantity => {},
                else => return propFail(prop, o),
            }
            // A width of 0 means the declared range did not fold (see
            // model_analog.zig `packedWidth`): unknown, which is not the
            // same as zero-width.
            if (o.size == 0) {
                fail("NOFOLD", "vpi_get: the declared range of `{s}` is not a constant this model folded", .{o.full});
                return vpiUndefined;
            }
            // §11.6.4 NOTE 3: scalar and vector are about the object's own
            // width and "shall not indicate anything about what is connected".
            return switch (prop) {
                vpiSize => @intCast(o.size),
                vpiScalar => @intFromBool(o.size == 1),
                else => @intFromBool(o.size > 1),
            };
        },
        vpiDirection => {
            if (o.kind != .port) return propFail(prop, o);
            // §6.5.2.2. `.unspecified` is a port named in the header whose
            // direction declaration never arrived — §11.6.4's `vpiNoDirection`,
            // which is an answer rather than a missing one.
            return switch (o.direction) {
                .input => vpiInput,
                .output => vpiOutput,
                .inout => vpiInout,
                .unspecified => vpiNoDirection,
            };
        },
        vpiPortIndex => {
            if (o.kind != .port) return propFail(prop, o);
            return @intCast(o.port_index);
        },
        vpiLocalParam => {
            if (o.kind != .parameter) return propFail(prop, o);
            return @intFromBool(o.is_local);
        },
        // §11.6.12 `vpiConstType` over §3.4.1's parameter types. `.unspecified`
        // is a `parameter p = <expr>;` whose type follows its value, which
        // this property does not read.
        vpiConstType => {
            if (o.kind == .constant) {
                if (o.const_type == 0) {
                    fail("NOTYPE", "vpi_get: this literal's base is not recorded", .{});
                    return vpiUndefined;
                }
                return o.const_type;
            }
            if (o.kind != .parameter) return propFail(prop, o);
            return switch (o.ty) {
                .real => vpiRealConst,
                .integer => vpiIntConst,
                .string => vpiStringConst,
                .unspecified => {
                    fail("NOTYPE", "vpi_get: `{s}` has no declared type; its constant type follows its value", .{o.full});
                    return vpiUndefined;
                },
            };
        },
        vpiSigned => {
            if (o.kind != .reg and o.kind != .integer and o.kind != .time_var) return propFail(prop, o);
            return @intFromBool(o.is_signed);
        },
        vpiNetType => {
            if (o.kind != .net) return propFail(prop, o);
            return netType(o.net_type) orelse propFail(prop, o);
        },
        vpiLineNo => {
            const at = location(o) orelse return propFail(prop, o);
            return at.line;
        },
        else => {
            for (o.props) |p| if (p.prop == prop) return p.value;
            fail("NOPROP", "vpi_get: property {d} is not answered for a {s}", .{ prop, @tagName(o.kind) });
            return vpiUndefined;
        },
    }
}

/// §11.6.16's two computed properties of a system call — whether the name is
/// a registered user systf (NOTE 3) and, for a function, its sysfunctype —
/// then the object's own `props` rows.
pub fn codeProp(o: *const Obj, prop: c_int) c_int {
    if (o.vtype == code.vpiSysTaskCall or o.vtype == code.vpiSysFuncCall) {
        const reg = systf.regOf(o);
        if (prop == systf.vpiUserDefn) return @intFromBool(reg != null);
        if (prop == systf.vpiSysFuncType and o.vtype == code.vpiSysFuncCall) {
            const r = reg orelse return propFail(prop, o);
            return if (r.domain == .digital) r.digital.sysfunctype else r.analog.sysfunctype;
        }
        // IEEE 1364-2005 §26.1.1: "the number of bits that the calltf
        // routine shall provide as the return value".
        if (prop == vpiSize and o.vtype == code.vpiSysFuncCall and !o.in_analog) if (systf.kindOf(o.name)) |k| switch (k) {
            .func => |t| return @intCast(t.width),
            .task => {},
        };
    }
    for (o.props) |p| if (p.prop == prop) return p.value;
    return propFail(prop, o);
}

// ---------------------------------------------------------------------------
// §12.18 vpi_get_real
// ---------------------------------------------------------------------------

// §12.18's analysis properties. Verilog-AMS names them and numbers none;
// VerA's numbers, after the analog systf types.
pub const vpiStartTime: c_int = 742;
pub const vpiEndTime: c_int = 743;
pub const vpiTransientMaxStep: c_int = 744;
pub const vpiStartFrequency: c_int = 745;
pub const vpiEndFrequency: c_int = 746;

/// "shall return the value of object properties, for properties of type
/// real ... This function is available to analog tasks and functions only.
/// Should an error occur, vpi_get_real() shall return vpiUndefined."
///
/// So it answers only inside a callback of an analog system task or function
/// (`systf.active`). There the five properties are the analysis's
/// (`analog_run.analysis`), asked of a NULL object; with no analysis, or for
/// the AC-only frequencies outside an AC sweep, the answer is the error.
pub export fn vpi_get_real(prop: c_int, obj: vpiHandle) f64 {
    const undef: f64 = @floatFromInt(vpiUndefined);
    if (refused("vpi_get_real")) return undef;
    const at = systf.active orelse {
        fail("NOTANALOG", "vpi_get_real: available to analog tasks and functions only, and none is running", .{});
        return undef;
    };
    if (!root.design.?.objects[at].in_analog) {
        fail("NOTANALOG", "vpi_get_real: the running system task or function is a digital one", .{});
        return undef;
    }
    switch (prop) {
        vpiStartTime, vpiEndTime, vpiTransientMaxStep, vpiStartFrequency, vpiEndFrequency => {
            if (obj != null) {
                fail("BADHANDLE", "vpi_get_real: property {d} is the analysis's, asked of NULL", .{prop});
                return undef;
            }
            const a = analog_run.analysis() orelse {
                fail("NOANALYSIS", "vpi_get_real: no analysis is set up in this process", .{});
                return undef;
            };
            return switch (prop) {
                vpiStartTime => a.start,
                vpiEndTime => a.stop,
                vpiTransientMaxStep => a.max_step,
                // §12.18 "for the start/end frequency of AC analysis": a
                // transient or operating point has none.
                else => if (a.kind == .ac) (if (prop == vpiStartFrequency) a.fstart else a.fstop) else {
                    fail("NOANALYSIS", "vpi_get_real: property {d} is an AC analysis's, and none is running", .{prop});
                    return undef;
                },
            };
        },
        else => {
            fail("NOPROP", "vpi_get_real: {d} is not a real property", .{prop});
            return undef;
        },
    }
}

/// IEEE 1364-2005 §26.6.6's vpiNetType, Annex G numbered; null for a
/// `wreal`, which Annex G has no constant for.
fn netType(k: Ast.NetKind) ?c_int {
    return switch (k) {
        .wire => 1,
        .wand => 2,
        .wor => 3,
        .tri => 4,
        .tri0 => 5,
        .tri1 => 6,
        .trireg => 7,
        .triand => 8,
        .trior => 9,
        .supply1 => 10,
        .supply0 => 11,
        .uwire => 13,
        .wreal => null,
    };
}

/// IEEE 1364-2005 §26.3.3 vpiLineNo and vpiFile: the location the model
/// resolved when it was built (`Cold.loc`, the analog model's instances),
/// else where the declaration or statement `o.src_tok` is, in the source
/// file as written, through the digital run's source map.
///
/// ponytail: the physical line; §19.7's `line renumbering is not applied.
fn location(o: *const Obj) ?root.Loc {
    if (root.coldOf(o).loc) |l| return l;
    if (o.src_tok == 0) return null;
    const r = run.attached() orelse return null;
    return root.locate(r.bag, r.starts[o.src_tok]);
}

fn propFail(prop: c_int, o: *const Obj) c_int {
    fail("NOPROP", "vpi_get: a {s} has no property {d}", .{ @tagName(o.kind), prop });
    return vpiUndefined;
}

// ---------------------------------------------------------------------------
// §12.12 vpi_get_str
// ---------------------------------------------------------------------------

/// "The string shall be placed in a temporary buffer which shall be used by
/// every call to this routine. If the string is to be used after a subsequent
/// call, the string needs to be copied to another location."
///
/// One buffer, reused, so the model stores names unterminated. A failing call
/// returns NULL, the one value an application would not go on to print.
pub export fn vpi_get_str(prop: c_int, obj: vpiHandle) [*c]u8 {
    const d = enter("vpi_get_str") orelse return null;
    if (root.unansweredProp(prop)) |u| {
        root.failUnanswered("vpi_get_str", u);
        return null;
    }
    // IEEE 1364-2005 §26.3.2: every object has a type, and its name, the
    // handles that are not design objects (an iterator, a callback) included.
    if (prop == vpiType and asObj(obj) == null and issued(obj) != null) return copyStr(typeName(vpi_get(vpiType, obj)));
    const o = object("vpi_get_str", obj) orelse return null;
    const s: []const u8 = switch (prop) {
        // §11.6.7 lists no name for a quantity: it is reached from its
        // branch, and named only as `V(b)`/`I(b)` in source.
        vpiName, vpiFullName => blk: {
            // A behavioural object has the names its diagram lists and no
            // others: a named block both, a call its tf name only, a
            // statement none.
            if (o.kind == .code and (if (prop == vpiName) o.name else o.full).len == 0) {
                fail("NOPROP", "vpi_get_str: a {s} has no name property {d}", .{ typeName(o.vtype), prop });
                return null;
            }
            if (o.kind == .quantity) {
                fail("NOPROP", "vpi_get_str: a quantity has no name property {d}", .{prop});
                return null;
            }
            break :blk if (prop == vpiName) o.name else o.full;
        },
        vpiType => typeName(typeOf(o)),
        // §11.6.1 — a module property and only a module's. A net has no
        // definition to name.
        vpiDefName => blk: {
            if (o.kind == .code) if (code.defName(o)) |n| break :blk n;
            if (o.kind != .module) {
                fail("NOPROP", "vpi_get_str: a {s} has no vpiDefName", .{@tagName(o.kind)});
                return null;
            }
            break :blk d.scopes[o.scope].def_name;
        },
        vpiFile => blk: {
            const at = location(o) orelse {
                fail("NOPROP", "vpi_get_str: no source location is recorded for a {s}", .{@tagName(o.kind)});
                return null;
            };
            break :blk at.file;
        },
        // IEEE 1364-2005 §26.6.26 b) / §26.6.19 g), spelled from the
        // source straight into the buffer.
        vpiDecompile => {
            if (o.src_expr == .none and o.src_stmt == .none) {
                fail("NOPROP", "vpi_get_str: a {s} has no vpiDecompile", .{typeName(typeOf(o))});
                return null;
            }
            const f = d.file orelse {
                fail("NOSOURCE", "vpi_get_str: the analog model keeps no source to decompile", .{});
                return null;
            };
            var w: std.Io.Writer = .fixed(str_buf[0 .. str_buf.len - 1]);
            (if (o.src_expr != .none) decompile.decompile(&w, f, o.src_expr) else decompile.decompileCall(&w, f, o.src_stmt)) catch {
                fail("TOOLONG", "vpi_get_str: the decompiled text passes {d} bytes", .{str_buf.len - 1});
                return null;
            };
            str_buf[w.end] = 0;
            return @ptrCast(&str_buf);
        },
        // IEEE 1364-2005 §13.6: "The following VPI properties shall exist for
        // objects of type vpiModule".
        vpiLibrary, vpiCell, vpiConfig => blk: {
            if (o.kind != .module) {
                fail("NOPROP", "vpi_get_str: a {s} has no library binding", .{@tagName(o.kind)});
                return null;
            }
            const sc = d.scopes[o.scope];
            break :blk switch (prop) {
                vpiLibrary => sc.library,
                vpiCell => sc.def_name,
                else => if (sc.config.len == 0) return null else sc.config,
            };
        },
        else => {
            fail("NOPROP", "vpi_get_str: string property {d} is not answered for a {s}", .{ prop, @tagName(o.kind) });
            return null;
        },
    };
    return copyStr(s);
}

fn copyStr(s: []const u8) [*c]u8 {
    const n = @min(s.len, str_buf.len - 1);
    @memcpy(str_buf[0..n], s[0..n]);
    str_buf[n] = 0;
    return @ptrCast(&str_buf);
}

/// §12.12's single shared buffer. See `name_buf_len` for the ceiling.
var str_buf: [name_buf_len]u8 = undefined;

// ---------------------------------------------------------------------------
// Tests. Properties of design rows are test.zig's.
// ---------------------------------------------------------------------------

test "IEEE 1364-2005 §26.6.6 vpiNetType: Annex G's numbers, each once, none for wreal" {
    var seen: u32 = 0;
    for (std.enums.values(Ast.NetKind)) |k| {
        const t = netType(k) orelse {
            try std.testing.expectEqual(Ast.NetKind.wreal, k);
            continue;
        };
        // Annex G numbers 1-11 and 13 (12 is vpiNone).
        try std.testing.expect(t >= 1 and t <= 13 and t != 12);
        const bit = @as(u32, 1) << @intCast(t);
        try std.testing.expect((seen & bit) == 0);
        seen |= bit;
    }
}

test "§12.18 vpi_get_real: only inside an analog task or function" {
    try std.testing.expectEqual(@as(f64, @floatFromInt(vpiUndefined)), vpi_get_real(vpiStartTime, null));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}
