//! Property reads: a handle and a property -> the integer, real or string
//! §11.6 lists for the object's class. A property the class does not have is
//! vpiUndefined (NULL for a string) plus an error, never a zero. Every
//! vpi_get_str answer is in one static buffer that the next call overwrites.
//! Cites: VAMS-2023 §12.5, §12.12, §12.18, §11.6; IEEE 1364-2005 §13.6,
//! §26.3.2, §26.3.3, §26.3.5, §26.6.
//!
//! Contents:
//! - `pub fn vpi_get(prop: c_int, obj: abi.vpiHandle) c_int`
//! - `pub fn codeProp(o: *const Obj, prop: c_int) c_int`
//! - `pub fn vpi_get_real(prop: c_int, obj: abi.vpiHandle) f64`
//! - `pub fn vpi_get_str(prop: c_int, obj: abi.vpiHandle) [*c]u8`

const std = @import("std");
const Ast = @import("frontend").Ast;
const abi = @import("abi.zig");
const analog = @import("analog.zig");
const callback = @import("callback.zig");
const code_tables = @import("code_tables.zig");
const decompile = @import("decompile.zig");
const delays = @import("delays.zig");
const run = @import("run.zig");
const schema = @import("schema.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const systf = @import("systf.zig");
const trust = @import("trust.zig");
const value_put = @import("value_put.zig");
const user = @import("vpi_user.zig");
const Loc = schema.Loc;
const Obj = schema.Obj;

/// §12.12's single shared buffer. See `name_buf_len` for the ceiling.
var str_buf: [schema.name_buf_len]u8 = undefined;

/// "Should an error occur, `vpi_get()` shall return `vpiUndefined`."
///
/// Every property below is one §11.6 lists for the class it is asked of. Asking
/// for a property a class does not have — `vpiDirection` of a net, `vpiSize` of
/// a module — is an error and not a zero: §11.6.8 simply gives a net no
/// direction, and a 0 would be indistinguishable from `vpiNoDirection`.
pub export fn vpi_get(prop: c_int, obj: abi.vpiHandle) c_int {
    // Not `enter`: callbacks, time queues, events and systf registrations are
    // objects without a design, and a handle to one still has a type.
    if (status.refused("vpi_get")) return user.vpiUndefined;
    // A handle VerA issued that is no design object: §12.23's iterator,
    // §11.6.25's callback, §12.30's scheduled event, a systf registration,
    // IEEE 1364-2005 §26.6.16's inter-module path, a time queue. Each has a
    // type and, at most, one property of its own.
    const other: ?c_int = if (trust.asIter(obj) != null) user.vpiIterator else if (callback.asCb(obj) != null) user.vpiCallback else if (value_put.asEvent(obj) != null) user.vpiSchedEvent else if (systf.asSystf(obj) != null) user.vpiUserSystf else if (delays.asPath(obj) != null) user.vpiInterModPath else if (run.asQueue(obj) != null) user.vpiTimeQueue else null;
    // IEEE 1364-2005 §26.3.5: "All objects have a vpiIsProtected property",
    // which vpi_user.h numbers as Annex G's vpiProtected (VD-045). An object
    // is protected when a §28 decryption envelope's cleartext declares it;
    // a handle that is no design object never is.
    if (prop == user.vpiProtected) {
        if (trust.asObj(obj)) |o| return @intFromBool(isProtected(o));
        if (other != null) return 0;
    }
    if (status.unansweredProp(prop)) |u| {
        status.failUnanswered("vpi_get", u);
        return user.vpiUndefined;
    }
    if (other) |t| {
        if (prop == user.vpiType) return t;
        if (prop == user.vpiIteratorType) if (trust.asIter(obj)) |it| return it.ty;
        if (prop == user.vpiScheduled) if (value_put.asEvent(obj)) |e| return @intFromBool(value_put.scheduled(e));
        status.fail("NOPROP", "vpi_get: a {s} has no property {d}", .{ schema.typeName(t), prop });
        return user.vpiUndefined;
    }
    // §12.5's NULL-object case: IEEE 1364-2005 §26.6.1 Details b.
    if (obj == null and (prop == user.vpiTimeUnit or prop == user.vpiTimePrecision)) {
        if (session.design) |d| if (d.finest) |f| return f;
    }
    const o = status.object("vpi_get", obj) orelse return user.vpiUndefined;
    if (o.kind == .code and prop != user.vpiType and prop != user.vpiLineNo) return codeProp(o, prop);
    switch (prop) {
        user.vpiType => return schema.typeOf(o),
        // IEEE 1364 §26.6.1/§26.6.6-§26.6.8: "is item an array" — an array,
        // or a module, net or reg that is a member of one (a reg that is
        // one is a `.word`). §26.6.8 draws no vpiArray on a var select.
        user.vpiArray => return switch (o.kind) {
            .reg_array, .var_array, .net_array, .word => 1,
            .module, .net => @intFromBool(o.parent != .none),
            .reg, .integer, .real_var, .time_var, .var_select => 0,
            else => propFail(prop, o),
        },
        user.vpiImplicitDecl => return switch (o.kind) {
            .net => @intFromBool(o.implicit),
            else => propFail(prop, o),
        },
        user.vpiAutomatic => return switch (o.kind) {
            .reg, .integer, .real_var, .time_var => @intFromBool(o.automatic),
            else => propFail(prop, o),
        },
        user.vpiIsMemory => return switch (o.kind) {
            .reg_array => 1,
            .var_array, .reg => 0,
            else => propFail(prop, o),
        },
        // §11.6.1 — true for the root of the instance tree, the one module
        // `Elaborate.pickTop` chose.
        user.vpiTopModule => {
            if (o.kind != .module) return propFail(prop, o);
            return @intFromBool(o.owner == .none);
        },
        user.vpiTimeUnit, user.vpiTimePrecision => {
            if (o.kind != .module) return propFail(prop, o);
            const sc = session.design.?.scopes[o.scope];
            return (if (prop == user.vpiTimeUnit) sc.time_unit else sc.time_precision) orelse propFail(prop, o);
        },
        user.vpiSize, user.vpiScalar, user.vpiVector => {
            // An array's size counts ELEMENTS (§26.6.9 "array size counts
            // members"), everything else's counts bits.
            switch (o.kind) {
                .reg_array, .var_array, .net_array, .module_array => if (prop == user.vpiSize) return @intCast(o.size) else return propFail(prop, o),
                .port, .net, .reg, .integer, .real_var, .time_var, .word, .var_select, .constant, .node, .branch, .quantity => {},
                else => return propFail(prop, o),
            }
            // A width of 0 means the declared range did not fold (see
            // model_analog.zig `packedWidth`): unknown, which is not the
            // same as zero-width.
            if (o.size == 0) {
                status.fail("NOFOLD", "vpi_get: the declared range of `{s}` is not a constant this model folded", .{o.full});
                return user.vpiUndefined;
            }
            // §11.6.4 NOTE 3: scalar and vector are about the object's own
            // width and "shall not indicate anything about what is connected".
            return switch (prop) {
                user.vpiSize => @intCast(o.size),
                user.vpiScalar => @intFromBool(o.size == 1),
                else => @intFromBool(o.size > 1),
            };
        },
        user.vpiDirection => {
            if (o.kind != .port) return propFail(prop, o);
            // §6.5.2.2. `.unspecified` is a port named in the header whose
            // direction declaration never arrived — §11.6.4's `vpiNoDirection`,
            // which is an answer rather than a missing one.
            return switch (o.direction) {
                .input => user.vpiInput,
                .output => user.vpiOutput,
                .inout => user.vpiInout,
                .unspecified => user.vpiNoDirection,
            };
        },
        user.vpiPortIndex => {
            if (o.kind != .port) return propFail(prop, o);
            return @intCast(o.port_index);
        },
        user.vpiLocalParam => {
            if (o.kind != .parameter) return propFail(prop, o);
            return @intFromBool(o.is_local);
        },
        // §11.6.12 `vpiConstType` over §3.4.1's parameter types. `.unspecified`
        // is a `parameter p = <expr>;` whose type follows its value, which
        // this property does not read.
        user.vpiConstType => {
            if (o.kind == .constant) {
                if (o.const_type == 0) {
                    status.fail("NOTYPE", "vpi_get: this literal's base is not recorded", .{});
                    return user.vpiUndefined;
                }
                return o.const_type;
            }
            if (o.kind != .parameter) return propFail(prop, o);
            return switch (o.ty) {
                .real => user.vpiRealConst,
                .integer => user.vpiIntConst,
                .string => user.vpiStringConst,
                .unspecified => {
                    status.fail("NOTYPE", "vpi_get: `{s}` has no declared type; its constant type follows its value", .{o.full});
                    return user.vpiUndefined;
                },
            };
        },
        user.vpiSigned => {
            if (o.kind != .reg and o.kind != .integer and o.kind != .time_var) return propFail(prop, o);
            return @intFromBool(o.is_signed);
        },
        user.vpiNetType => {
            if (o.kind != .net) return propFail(prop, o);
            return netType(o.net_type) orelse propFail(prop, o);
        },
        user.vpiLineNo => {
            const at = location(o) orelse return propFail(prop, o);
            return at.line;
        },
        else => {
            for (o.props) |p| if (p.prop == prop) return p.value;
            status.fail("NOPROP", "vpi_get: property {d} is not answered for a {s}", .{ prop, @tagName(o.kind) });
            return user.vpiUndefined;
        },
    }
}

/// §11.6.16's two computed properties of a system call — whether the name is
/// a registered user systf (NOTE 3) and, for a function, its sysfunctype —
/// then the object's own `props` rows.
pub fn codeProp(o: *const Obj, prop: c_int) c_int {
    if (o.vtype == user.vpiSysTaskCall or o.vtype == user.vpiSysFuncCall) {
        const reg = systf.regOf(o);
        if (prop == user.vpiUserDefn) return @intFromBool(reg != null);
        if (prop == user.vpiSysFuncType and o.vtype == user.vpiSysFuncCall) {
            const r = reg orelse return propFail(prop, o);
            return if (r.domain == .digital) r.digital.sysfunctype else r.analog.sysfunctype;
        }
        // IEEE 1364-2005 §26.1.1: "the number of bits that the calltf
        // routine shall provide as the return value".
        if (prop == user.vpiSize and o.vtype == user.vpiSysFuncCall and !o.in_analog) if (systf.kindOf(o.name)) |k| switch (k) {
            .func => |t| return @intCast(t.width),
            .task => {},
        };
    }
    for (o.props) |p| if (p.prop == prop) return p.value;
    return propFail(prop, o);
}

/// "shall return the value of object properties, for properties of type
/// real ... This function is available to analog tasks and functions only.
/// Should an error occur, vpi_get_real() shall return vpiUndefined."
///
/// So it answers only inside a callback of an analog system task or function
/// (`systf.active`). There the five properties are the analysis's
/// (`analog_run.analysis`), asked of a NULL object; with no analysis, or for
/// the AC-only frequencies outside an AC sweep, the answer is the error.
pub export fn vpi_get_real(prop: c_int, obj: abi.vpiHandle) f64 {
    const undef: f64 = @floatFromInt(user.vpiUndefined);
    if (status.refused("vpi_get_real")) return undef;
    const at = systf.active orelse {
        status.fail("NOTANALOG", "vpi_get_real: available to analog tasks and functions only, and none is running", .{});
        return undef;
    };
    if (!session.design.?.obj(at).in_analog) {
        status.fail("NOTANALOG", "vpi_get_real: the running system task or function is a digital one", .{});
        return undef;
    }
    switch (prop) {
        user.vpiStartTime, user.vpiEndTime, user.vpiTransientMaxStep, user.vpiStartFrequency, user.vpiEndFrequency => {
            if (obj != null) {
                status.fail("BADHANDLE", "vpi_get_real: property {d} is the analysis's, asked of NULL", .{prop});
                return undef;
            }
            const a = analog.analysis() orelse {
                status.fail("NOANALYSIS", "vpi_get_real: no analysis is set up in this process", .{});
                return undef;
            };
            return switch (prop) {
                user.vpiStartTime => a.start,
                user.vpiEndTime => a.stop,
                user.vpiTransientMaxStep => a.max_step,
                // §12.18 "for the start/end frequency of AC analysis": a
                // transient or operating point has none.
                else => if (a.kind == .ac) (if (prop == user.vpiStartFrequency) a.fstart else a.fstop) else {
                    status.fail("NOANALYSIS", "vpi_get_real: property {d} is an AC analysis's, and none is running", .{prop});
                    return undef;
                },
            };
        },
        else => {
            status.fail("NOPROP", "vpi_get_real: {d} is not a real property", .{prop});
            return undef;
        },
    }
}

/// "The string shall be placed in a temporary buffer which shall be used by
/// every call to this routine. If the string is to be used after a subsequent
/// call, the string needs to be copied to another location."
///
/// One buffer, reused, so the model stores names unterminated. A failing call
/// returns NULL, the one value an application would not go on to print.
pub export fn vpi_get_str(prop: c_int, obj: abi.vpiHandle) [*c]u8 {
    const d = status.enter("vpi_get_str") orelse return null;
    if (status.unansweredProp(prop)) |u| {
        status.failUnanswered("vpi_get_str", u);
        return null;
    }
    // IEEE 1364-2005 §26.3.2: every object has a type, and its name, the
    // handles that are not design objects (an iterator, a callback) included.
    if (prop == user.vpiType and trust.asObj(obj) == null and trust.issued(obj) != null) return copyStr(schema.typeName(vpi_get(user.vpiType, obj)));
    const o = status.object("vpi_get_str", obj) orelse return null;
    const s: []const u8 = switch (prop) {
        // §11.6.7 lists no name for a quantity: it is reached from its
        // branch, and named only as `V(b)`/`I(b)` in source.
        user.vpiName, user.vpiFullName => blk: {
            // A behavioural object has the names its diagram lists and no
            // others: a named block both, a call its tf name only, a
            // statement none.
            if (o.kind == .code and (if (prop == user.vpiName) o.name else o.full).len == 0) {
                status.fail("NOPROP", "vpi_get_str: a {s} has no name property {d}", .{ schema.typeName(o.vtype), prop });
                return null;
            }
            if (o.kind == .quantity) {
                status.fail("NOPROP", "vpi_get_str: a quantity has no name property {d}", .{prop});
                return null;
            }
            break :blk if (prop == user.vpiName) o.name else o.full;
        },
        user.vpiType => schema.typeName(schema.typeOf(o)),
        // §11.6.1 — a module property and only a module's. A net has no
        // definition to name.
        user.vpiDefName => blk: {
            if (o.kind == .code) if (code_tables.defName(o)) |n| break :blk n;
            if (o.kind != .module) {
                status.fail("NOPROP", "vpi_get_str: a {s} has no vpiDefName", .{@tagName(o.kind)});
                return null;
            }
            break :blk d.scopes[o.scope].def_name;
        },
        user.vpiFile => blk: {
            const at = location(o) orelse {
                status.fail("NOPROP", "vpi_get_str: no source location is recorded for a {s}", .{@tagName(o.kind)});
                return null;
            };
            break :blk at.file;
        },
        // IEEE 1364-2005 §26.6.26 b) / §26.6.19 g), spelled from the
        // source straight into the buffer.
        user.vpiDecompile => {
            if (o.src_expr == .none and o.src_stmt == .none) {
                status.fail("NOPROP", "vpi_get_str: a {s} has no vpiDecompile", .{schema.typeName(schema.typeOf(o))});
                return null;
            }
            const f = d.file orelse {
                status.fail("NOSOURCE", "vpi_get_str: the analog model keeps no source to decompile", .{});
                return null;
            };
            var w: std.Io.Writer = .fixed(str_buf[0 .. str_buf.len - 1]);
            (if (o.src_expr != .none) decompile.decompile(&w, f, o.src_expr) else decompile.decompileCall(&w, f, o.src_stmt)) catch {
                status.fail("TOOLONG", "vpi_get_str: the decompiled text passes {d} bytes", .{str_buf.len - 1});
                return null;
            };
            str_buf[w.end] = 0;
            return @ptrCast(&str_buf);
        },
        // IEEE 1364-2005 §13.6: "The following VPI properties shall exist for
        // objects of type vpiModule".
        user.vpiLibrary, user.vpiCell, user.vpiConfig => blk: {
            if (o.kind != .module) {
                status.fail("NOPROP", "vpi_get_str: a {s} has no library binding", .{@tagName(o.kind)});
                return null;
            }
            const sc = d.scopes[o.scope];
            break :blk switch (prop) {
                user.vpiLibrary => sc.library,
                user.vpiCell => sc.def_name,
                else => if (sc.config.len == 0) return null else sc.config,
            };
        },
        else => {
            status.fail("NOPROP", "vpi_get_str: string property {d} is not answered for a {s}", .{ prop, @tagName(o.kind) });
            return null;
        },
    };
    return copyStr(s);
}

// ---- private ----

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
fn location(o: *const Obj) ?Loc {
    if (schema.coldOf(o).loc) |l| return l;
    if (o.src_tok == 0) return null;
    const r = run.attached() orelse return null;
    return schema.locate(r.bag, r.starts[o.src_tok]);
}

/// §26.3.5: whether `o` is declared in a decrypted envelope's cleartext,
/// which the preprocessor registers as its own file.
fn isProtected(o: *const Obj) bool {
    const at = location(o) orelse return false;
    return std.mem.eql(u8, at.file, @import("vera").Preprocessor.protect.file_name);
}

fn propFail(prop: c_int, o: *const Obj) c_int {
    status.fail("NOPROP", "vpi_get: a {s} has no property {d}", .{ @tagName(o.kind), prop });
    return user.vpiUndefined;
}

fn copyStr(s: []const u8) [*c]u8 {
    const n = @min(s.len, str_buf.len - 1);
    @memcpy(str_buf[0..n], s[0..n]);
    str_buf[n] = 0;
    return @ptrCast(&str_buf);
}

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
    try std.testing.expectEqual(@as(f64, @floatFromInt(user.vpiUndefined)), vpi_get_real(user.vpiStartTime, null));
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
}
