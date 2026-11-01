//! Parsed attribute/owner bindings -> IEEE 1364-2005 §26.6.42 attribute
//! objects, values, provenance and parent links. §3.8 / AMS §2.9 supply
//! default 1 and last-name-wins within each decorated language element.
//! Cites: IEEE 1364-2005 §3.8, §26.6.42; VAMS-2023 §2.9.
//!
//! Contents:
//! - `pub const ByOwner = struct`
//! - `pub const ByOwner.end: u32`
//! - `pub fn ByOwner.init(gpa: std.mem.Allocator, file: *const Ast.SourceFile) error{OutOfMemory}!ByOwner`
//! - `pub fn ByOwner.deinit(self: *ByOwner, gpa: std.mem.Allocator) void`
//! - `pub fn AnalogEnv.leaf(env: AnalogEnv, e: Ast.ExprId) ?Const`
//! - `pub fn AnalogEnv.signed(env: AnalogEnv, e: Ast.ExprId) ?bool`
//! - `pub fn AnalogEnv.width(env: AnalogEnv, e: Ast.ExprId) ?u32`
//! - `pub fn supports(o: *const Obj) bool`
//! - `pub fn attach(b: *Builder, parent: ObjId, owner: Ast.AttributeOwner, definition: bool) Error!void`

const std = @import("std");
const Ast = @import("frontend").Ast;
const Lower = @import("ir").Lowered;
const Lowered = @import("ir").Lowered;
const constfold = @import("frontend").constfold;
const Const = Lower.Const;
const schema = @import("schema.zig");
const ObjId = schema.ObjId;
const user = @import("vpi_user.zig");
const Builder = @import("Builder.zig");
const session = @import("session.zig");
const Error = session.Error;
const Obj = schema.Obj;

/// The source's attribute bindings by owner, each owner's in source order:
/// `attach`'s lookup, built once per model rather than a scan of every
/// binding for each element it is asked about.
pub const ByOwner = struct {
    /// Owner -> its first binding's index in `file.attributes`.
    heads: std.AutoHashMapUnmanaged(Ast.AttributeOwner, u32) = .empty,
    /// Binding index -> the next binding of the same owner, `end` after
    /// the last.
    next: []u32 = &.{},

    /// The `next` of an owner's last binding.
    pub const end: u32 = std.math.maxInt(u32);

    /// Indexes `file.attributes` in one pass, O(bindings). Caller owns the
    /// result and frees it with `deinit` and the same `gpa`.
    pub fn init(gpa: std.mem.Allocator, file: *const Ast.SourceFile) error{OutOfMemory}!ByOwner {
        const bindings = file.attributes.items;
        var self: ByOwner = .{ .next = try gpa.alloc(u32, bindings.len) };
        errdefer self.deinit(gpa);
        var k = bindings.len;
        while (k > 0) {
            k -= 1;
            const g = try self.heads.getOrPut(gpa, bindings[k].owner);
            self.next[k] = if (g.found_existing) g.value_ptr.* else end;
            g.value_ptr.* = @intCast(k);
        }
        return self;
    }

    /// Frees both tables; `gpa` must be the one `init` used.
    pub fn deinit(self: *ByOwner, gpa: std.mem.Allocator) void {
        self.heads.deinit(gpa);
        gpa.free(self.next);
    }
};

/// Analog attributes use the same final parameter constants the VPI model
/// publishes, resolving the source spelling in the declaring instance.
const AnalogEnv = struct {
    b: *Builder,

    /// `constfold`'s leaf hook: a parameter's folded value, or one of the
    /// conversion calls the analog validator folds. Null: not a constant.
    pub fn leaf(env: AnalogEnv, e: Ast.ExprId) ?Const {
        // These are the conversion calls the analog constant-expression
        // validator folds (src/analog/constfold.zig, AMS §9.11/§9.14).
        if (env.b.file.exprs.tag(e) == .sys_call) {
            const ex = &env.b.file.exprs;
            const args = ex.args(e);
            if (args.len != 1) return null;
            const name = env.b.file.str(ex.strOf(e));
            const clog = std.mem.eql(u8, name, "$clog2");
            const v = (if (clog) constfold.foldSized(env.b.file, args[0], env) else constfold.fold(env.b.file, args[0], env)) orelse return null;
            if (v == .str) return null;
            if (clog) return .{ .int = constfold.clog2(v.asIntExact() orelse return null, constfold.clog2Width(env.b.file, args[0], env) orelse return null) };
            if (std.mem.eql(u8, name, "$itor")) return .{ .real = @floatFromInt(v.asIntExact() orelse return null) };
            if (std.mem.eql(u8, name, "$rtoi")) {
                const t = @trunc(v.asReal());
                if (!(t >= -2147483648.0 and t <= 2147483647.0)) return null;
                return .{ .int = @intFromFloat(t) };
            }
            return null;
        }
        if (env.b.file.exprs.tag(e) != .ident) return null;
        const at = env.b.lookup(env.b.file.str(env.b.file.exprs.strOf(e)));
        if (at == ObjId.none or env.b.objects.at(at).kind != .parameter) return null;
        return env.b.objects.at(at).value;
    }
    fn parameter(env: AnalogEnv, e: Ast.ExprId) ?@import("ir").Lowered.ParamInfo {
        if (env.b.file.exprs.tag(e) != .ident) return null;
        const at = env.b.lookup(env.b.file.str(env.b.file.exprs.strOf(e)));
        if (at == ObjId.none) return null;
        const full = env.b.objects.at(at).full;
        const lowered = (env.b.analog orelse return null).lowered orelse return null;
        if (full.len <= env.b.top_name.len) return null;
        const name = full[env.b.top_name.len + 1 ..];
        for (lowered.params.items) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
    /// `constfold`'s signedness hook; an `integer` parameter is signed.
    pub fn signed(env: AnalogEnv, e: Ast.ExprId) ?bool {
        if (env.b.file.exprs.tag(e) != .ident) return constfold.clog2Signed(env.b.file, e, env);
        const p = env.parameter(e) orelse return null;
        return if (p.integer32) true else p.source_signed;
    }
    /// `constfold`'s width hook: 32 for an `integer` parameter, else the
    /// source width.
    pub fn width(env: AnalogEnv, e: Ast.ExprId) ?u32 {
        const p = env.parameter(e) orelse return null;
        return if (p.integer32) 32 else p.source_width;
    }
};

/// Is `o` one of IEEE 1364-2005 §26.6.42's decorated language elements, so
/// `vpi_iterate(vpiAttribute, o)` is a relationship (empty when undecorated)
/// rather than an error?
pub fn supports(o: *const Obj) bool {
    return switch (o.kind) {
        .module, .port, .net, .reg, .integer, .real_var, .time_var, .reg_array, .var_array, .net_array => true,
        .code => switch (o.vtype) {
            user.vpiAlways,
            user.vpiInitial,
            user.vpiAnalog,
            user.vpiAssignStmt,
            user.vpiAssignment,
            user.vpiBegin,
            user.vpiCase,
            user.vpiContAssign,
            user.vpiDeassign,
            user.vpiDelayControl,
            user.vpiDisable,
            user.vpiEventControl,
            user.vpiEventStmt,
            user.vpiFor,
            user.vpiForce,
            user.vpiForever,
            user.vpiFork,
            user.vpiIf,
            user.vpiIfElse,
            user.vpiNamedBegin,
            user.vpiNamedFork,
            user.vpiNullStmt,
            user.vpiRelease,
            user.vpiRepeat,
            user.vpiRepeatControl,
            user.vpiWait,
            user.vpiWhile,
            user.vpiContrib,
            user.vpiTaskCall,
            user.vpiSysTaskCall,
            user.vpiOperation,
            user.vpiFuncCall,
            user.vpiSysFuncCall,
            user.vpiAccessFunc,
            user.vpiTask,
            user.vpiFunction,
            user.vpiNamedEvent,
            user.vpiNamedEventArray,
            user.vpiGate,
            user.vpiSwitch,
            user.vpiUdp,
            user.vpiPrimTerm,
            user.vpiModPath,
            user.vpiPathTerm,
            user.vpiTchk,
            user.vpiTchkTerm,
            user.vpiParamAssign,
            user.vpiTableEntry,
            => true,
            else => false, // else: helper objects, selects and constants are not decorated elements in §26.6.42
        },
        else => false, // else: values, iterators and analog topology are not §26.6.42 decorated language elements
    };
}

/// Appends a vpiAttribute row to `parent` for each attribute the source binds
/// to `owner`, its value folded (§3.8/AMS §2.9: no value is 1). A name
/// repeated on one element keeps the later spelling. `definition` is
/// vpiDefAttribute. A no-op for a `parent` of `.none`. `error.NotElaborated`: a value
/// that does not fold, which the frontend should already have refused.
pub fn attach(b: *Builder, parent: ObjId, owner: Ast.AttributeOwner, definition: bool) Error!void {
    if (parent == ObjId.none) return;
    var k = b.attrs.heads.get(owner) orelse ByOwner.end;
    while (k != ByOwner.end) : (k = b.attrs.next[k]) {
        const binding = b.file.attributes.items[k];
        for (binding.specs) |spec| {
            const name = b.file.str(spec.name);
            const found: ?ObjId = for (b.objects.coldOf(parent).attributes) |at| {
                const old = b.objects.at(at);
                if (std.mem.eql(u8, old.name, name) and old.props[0].value == @intFromBool(definition)) break at;
            } else null;
            // Declaration-list fan-out may copy an earlier prefix after a
            // later one was parsed. Source order, not append order, wins.
            if (found) |at| if (b.objects.at(at).src_tok >= spec.main_tok) continue;
            const at = found orelse try b.code(user.vpiAttribute, &.{.{ .tag = user.vpiParent, .to = parent }}, &.{}, &.{.{ .prop = user.vpiDefAttribute, .value = @intFromBool(definition) }});
            var value: ?Const = null;
            var bits: ?@import("frontend").Integer.Literal = null;
            if (spec.value == .none) {
                value = .{ .int = 1 };
            } else if (b.file.exprs.tag(spec.value) == .str_literal) {
                value = .{ .str = try b.arena.dupe(u8, b.file.str(b.file.exprs.strOf(spec.value))) };
            } else if (b.run) |r| {
                const scope = b.objects.coldOf(parent).src_engine orelse b.engine;
                const v = r.vpiAttributeValue(b.arena, scope, spec.value) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.NotElaborated;
                switch (v) {
                    .bits => |lit| bits = lit,
                    .real => |real| value = .{ .real = real },
                }
            } else {
                value = constfold.fold(b.file, spec.value, AnalogEnv{ .b = b }) orelse return error.NotElaborated;
            }
            b.objects.at(at).name = try b.arena.dupe(u8, name);
            b.objects.at(at).src_tok = spec.main_tok;
            b.objects.at(at).value = value;
            if (bits != null or b.objects.coldOf(at).constant_bits != null)
                (try b.objects.coldFor(at)).constant_bits = bits;
            if (found == null) {
                const all = try std.mem.concat(b.arena, ObjId, &.{ b.objects.coldOf(parent).attributes, &.{at} });
                (try b.objects.coldFor(parent)).attributes = all;
            }
        }
    }
}
