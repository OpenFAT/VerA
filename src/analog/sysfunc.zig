//! Clause 9 system functions in expression position: a `$`-call in, a MIR
//! `call` or a folded value out. `lowerSysCall` reads as its steps: the
//! context rules (§9.2), the name-specific rules (§4.6.1, §9.15, §9.17.3,
//! §9.19), then the generic call over its written arguments.
//!
//! Cites: §2.9, §3.4.7, §4.2.1.1, §4.3.1, §4.5.13, §4.5.15, §4.6.1, §4.7,
//! §5.6.1.2, §6.6.3, §6.7, A.8.2, §9.2, §9.5, §9.5.3, §9.5.4, §9.5.4.1,
//! §9.5.4.2, §9.5.7, §9.12, §9.13, §9.15, §9.17.3, §9.18, §9.19, §9.20,
//! §9.21, §9.22, §9.23, §12.32.1, §17.10; IEEE 1364-2005 §17.10.
//!
//! Contents:
//! - `pub fn refuseReserved(self: *Lower, tok: u32, name: []const u8) Oom!bool`
//! - `pub fn lowerSysCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue`

const std = @import("std");
const assert = std.debug.assert;
const hier_param = @import("elab").hier_param;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Elaborate = @import("elab").Elaborate;
const simparam = @import("ir").simparam;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_random = @import("random.zig");
const lower_expr = @import("expr.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_limit = @import("limit.zig");
const lower_table_model = @import("table_model.zig");
const lower_math = @import("math.zig");
const lower_reactive = @import("reactive.zig");
const lower_string_io = @import("string_io.zig");
const lower_clog2 = @import("clog2.zig");
const lower_sysfunc_args = @import("sysfunc_args.zig");
const lower_sysfunc_context = @import("sysfunc_context.zig");
const simparamValueIn = simparam.simparamValueIn;
const simparamIsRuntime = simparam.simparamIsRuntime;
const host_simparams = simparam.host_simparams;
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;

/// §9.15 Table 9-28: the string parameter names `$simparam$str` "shall"
/// support, and the only ones VerA knows.
const simparam_str_names = [_][]const u8{ "analysis_name", "analysis_type", "cwd", "module", "instance", "path" };

/// E1014: a source call spells a name VerA mints for itself
/// (`Callee.synthetic`). True when refused.
pub fn refuseReserved(self: *Lower, tok: u32, name: []const u8) Oom!bool {
    assert(name.len != 0);
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0);
    if (!Mir.Callee.fromName(name).synthetic()) return false;
    try self.err(tok, .E1014, "`{s}`", .{name});
    return true;
}

/// Lowers a Clause 9 system function in expression position. The context and
/// validity rules are checked here; what survives becomes a `call` whose simulator
/// semantics codegen's `emitCall` owns, or a folded value.
pub fn lowerSysCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.tag(e) == .sys_call);
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    if (try refuseReserved(self, ex.mainTok(e), name)) return poison;
    if (try refuseContext(self, e, name)) return poison; // §9.2, §9.22
    if (std.mem.eql(u8, name, "analysis") and try refuseAnalysisArgs(self, e)) return poison; // §4.6.1
    if (std.mem.eql(u8, name, "$param_given") or std.mem.eql(u8, name, "$port_connected"))
        if (try genvarQuery(self, e, name)) |tv| return tv; // §9.19
    // §4.3.1 Table 4-14 gives these system spellings the same operand-sensitive
    // result types as their traditional spellings. A generic call's name-only
    // sysFuncTy cannot express that: it would turn integer division into real
    // division. Use typed arithmetic opcodes, after the context checks above.
    if (std.mem.eql(u8, name, "$abs") or std.mem.eql(u8, name, "$min") or
        std.mem.eql(u8, name, "$max")) return lower_math.lowerBuiltin(self, e);
    // §3.4.7/§9.18 aliases and the original system spelling denote the
    // same top-level value. Instance-local reads were resolved in elaboration.
    if (hier_param.Kind.fromName(name)) |kind| if (self.hier_params.get(kind)) |pi|
        return .{ .v = self.param_values.items[pi], .ty = .real };
    // §9.13 Table 9-10. Before everything below, because the seed is an inout
    // argument and the write-back is not something a `call` result can express.
    if (try lower_random.lowerRandom(self, ex.mainTok(e), name, ex.args(e))) |tv| return tv;
    // Annex G Table G.1: the OVI Verilog-A v1.0 spelling `$limexp` was replaced
    // in v2.0 by the bare `limexp` (§4.5.13). `$limexp` is in neither Table 9-11
    // nor A.8.2, so the name does not exist; this is the only retired `$` spelling
    // VerA diagnoses specially.
    if (std.mem.eql(u8, name, "$limexp")) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0808);
        b.msg("`$limexp`", .{});
        b.suggestHere("limexp");
        try b.emit();
        return poison;
    }
    if (std.mem.eql(u8, name, "$limit") and try refuseLimitCall(self, e)) return poison; // §9.17.3
    // §9.15: "If param_name is not known, and the optional expression is not
    // supplied, then an error is generated." Only for a literal name: a string
    // parameter or variable is not known until the solve.
    if (std.mem.eql(u8, name, "$simprobe")) return lower_hier_name.lowerSimprobe(self, e);
    if (std.mem.eql(u8, name, "$simparam$str")) if (try simparamStr(self, e)) |tv| return tv; // §9.15 Table 9-28
    if (std.mem.eql(u8, name, "$simparam") and try refuseSimparam(self, e)) return poison; // §9.15
    return lowerCall(self, e, name);
}

// ---- private ----

/// §9.2 and §9.22/§9.23: reports E0806 for a name whose analog column says
/// No and E0818 for a driver access function outside a connect module, and
/// returns whether it did.
fn refuseContext(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!bool {
    assert(name.len != 0);
    assert(self.exprValid(e)); // `analysis` (§4.6.1) is a system call spelled without `$`
    if (lower_sysfunc_context.isDigitalOnlySysFunc(name)) { // §9.2
        try self.err(self.file.exprs.mainTok(e), .E0806, "`{s}`", .{name});
        return true;
    }
    // §9.22/§9.23 the driver access family, refused outside a connect module
    // (see `isConnectModuleOnlySysFunc`).
    if (lower_sysfunc_context.isConnectModuleOnlySysFunc(name)) {
        // Tables 9-19 and 9-20 split the connect module in two: every driver
        // function reads "Supported in analog context of connectmodule: No"
        // ($receiver_count alone reads Yes). This call is in a connect module's
        // analog block, so the fence it hits is §9.2's analog column.
        const in_cm = self.cur_unit < self.design.units.len and self.design.units[self.cur_unit].decl.is_connect;
        if (in_cm and !std.mem.eql(u8, name, "$receiver_count")) {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0806);
            b.msg("`{s}` in the analog block of a connect module", .{name});
            b.note("§9.2 Tables 9-19/9-20: \"Supported in analog context of connectmodule: No\"; call it from an `always` or `initial` block of the connect module", .{});
            try b.emit();
            return true;
        }
        var b = self.errWith(self.file.exprs.mainTok(e), .E0818);
        b.msg("`{s}` can only be called from a connect module", .{name});
        b.note("§9.22: \"Driver access functions can only be called from connect modules.\" This is a `module`", .{});
        try b.emit();
        return true;
    }
    return false;
}

/// §4.6.1 "The analysis() function takes one or more string arguments", and
/// A.8.2 puts the quotation marks in the production:
/// `analysis ( " analysis_identifier " { , " analysis_identifier " } )`.
/// So each argument is a string literal and there is at least one. Reports
/// E0574 and returns true otherwise.
fn refuseAnalysisArgs(self: *Lower, e: Ast.ExprId) Oom!bool {
    const ex = &self.file.exprs;
    assert(ex.tag(e) == .sys_call);
    const args = ex.args(e);
    if (args.len == 0) {
        try self.err(ex.mainTok(e), .E0574, "`analysis()` names no analysis", .{});
        return true;
    }
    for (args) |a| if (a == .none or ex.tag(a) != .str_literal) {
        try self.err(if (a != .none) ex.mainTok(a) else ex.mainTok(e), .E0574, "each argument of `analysis()` is a quoted analysis name", .{});
        return true;
    };
    assert(ex.args(e).len != 0);
    return false;
}

/// §9.19: "The $param_given() function takes a single argument, which must
/// be a parameter identifier", and $port_connected's "must be a port
/// identifier". Elaboration already answered every call whose argument was
/// one of an instance's own parameters or ports (`rewriteSysCall`), so what
/// reaches here is the top module's, or an argument of the wrong kind.
/// Returns the call's value when it is decided here, `poison` after E0822,
/// or null for the generic call.
fn genvarQuery(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!?TypedValue {
    const ex = &self.file.exprs;
    assert(ex.tag(e) == .sys_call);
    const is_pg = std.mem.eql(u8, name, "$param_given");
    assert(is_pg or std.mem.eql(u8, name, "$port_connected"));
    const args = ex.args(e);
    const arg: Ast.ExprId = if (args.len == 1) args[0] else .none;
    const id: ?[]const u8 = if (arg != .none and ex.tag(arg) == .ident) self.file.str(ex.strOf(arg)) else null;
    const ok = if (is_pg)
        id != null and (self.param_index.contains(id.?) or self.consts.contains(id.?))
    else if (id) |n| portOrdinal(self, n) != null else arg != .none; // §9.19 port_scalar_expression: an element is judged elsewhere
    if (!ok) {
        try self.err(if (arg != .none) ex.mainTok(arg) else ex.mainTok(e), .E0822, "{s}", .{if (is_pg)
            "$param_given requires a parameter identifier"
        else
            "$port_connected requires a port identifier"});
        return poison;
    }
    // A top-level device's own port: whether the host connected it is a
    // property of the card the host builds (a 4-terminal card for a
    // 6-port model), so the call carries the port's ordinal and codegen
    // reads that bit of the host-written `Model.port_connected__`.
    if (!is_pg) if (id) |n| if (portOrdinal(self, n)) |k| {
        self.out.uses.insert(.port_mask);
        return .{ .v = try self.call("$port_connected", &.{try self.mir.addIntConst(self.arena, k)}), .ty = .integer };
    };
    return null;
}

/// §9.17.3's argument rules for `$limit`, checked here, not in codegen,
/// because codegen may silently decline any limiting call (§4.5.15) while a
/// wrong arity is a source error: the first argument is an access function
/// reference (E0891), and fetlim takes a third argument (the threshold
/// voltage), pnjlim a third and a fourth (vte and vcrit, E0809). Only those
/// two literal names: an unknown string is treated "just as if no string had
/// been supplied". Also E0530 inside a `vera_timepoint` statement. Returns
/// whether it reported.
fn refuseLimitCall(self: *Lower, e: Ast.ExprId) Oom!bool {
    const ex = &self.file.exprs;
    assert(ex.tag(e) == .sys_call);
    // VerA's `vera_timepoint` (§2.9): a limiter reads the iterate.
    if (self.tp_cur != null) {
        try self.err(ex.mainTok(e), .E0530, "`$limit` (§9.17.3)", .{});
        return true;
    }
    const args = ex.args(e);
    // Syntax 9-12 spells every form's first argument access_function_reference,
    // and the prose says what it is for: "It returns a real value that is
    // derived from its first argument (the access function reference, such as
    // a branch voltage)". A.8.2's generic analog_system_function_call admits
    // any expression; the clause's own syntax narrows it. Parentheses leave no
    // node, so `(V(a,b))` passes.
    if (args.len >= 1 and (args[0] == .none or
        (ex.tag(args[0]) != .branch_access and ex.tag(args[0]) != .port_access)))
    {
        var b = self.errWith(ex.mainTok(e), .E0891);
        b.msg("its first argument is not an access function reference", .{});
        b.help("scale the result, not the probe: `type * $limit(V(a,b), ...)`, or pass the polarity as the trailing sign argument", .{});
        try b.emit();
        return true;
    }
    if (args.len >= 2) {
        if (lower_constfold.constEval(self, args[1])) |c| switch (c) {
            .str => |s| {
                const need: usize = if (std.mem.eql(u8, s, "pnjlim"))
                    4
                else if (std.mem.eql(u8, s, "fetlim")) 3 else 0;
                if (need != 0 and args.len < need) {
                    try self.err(self.file.exprs.mainTok(e), .E0809, "`\"{s}\"` needs {d} arguments to `$limit`, got {d}", .{ s, need, args.len });
                    return true;
                }
            },
            else => {},
        };
    }
    assert(self.tp_cur == null);
    return false;
}

/// §9.15 `$simparam$str`. Table 9-28's hierarchy rows are elaboration facts,
/// answered here from `cur_unit`, the instance that wrote this block:
/// "module" is "the name of the module from which $simparam$str is called"
/// and "instance" is "the hierarchical name of the instance"; codegen only
/// sees the flattened module. "cwd" and "analysis_name" describe the host's
/// run, which writes them into the instance; a name read at run time may be
/// either. An unknown literal name is E0811. Returns the folded string,
/// `poison` after E0811, or null for the generic call.
fn simparamStr(self: *Lower, e: Ast.ExprId) Oom!?TypedValue {
    const ex = &self.file.exprs;
    assert(ex.tag(e) == .sys_call);
    assert(self.file.strings.eql(ex.strOf(e), "$simparam$str"));
    if (self.cur_unit < self.design.units.len or self.module != null) {
        const a = ex.args(e);
        if (a.len >= 1) if (lower_sysfunc_args.constStrArg(self, a[0])) |nm| {
            // A design with no instances has no unit table: its one unit is the
            // top module, at the root.
            const u: struct { module: []const u8, path: []const u8 } = if (self.cur_unit < self.design.units.len)
                .{ .module = self.design.units[self.cur_unit].module, .path = self.design.units[self.cur_unit].path }
            else
                .{ .module = self.file.str(self.module.?.name), .path = "" };
            if (std.mem.eql(u8, nm, "module"))
                return .{ .v = try self.mir.addStrConst(self.arena, u.module), .ty = .string };
            // §9.15's worked example produces "testbench.dut1": a top-level
            // module's instance name is its module name, and the path is joined
            // to it by §6.7's period. `path` already carries the separator.
            if (std.mem.eql(u8, nm, "instance") or std.mem.eql(u8, nm, "path")) {
                const top = if (self.design.units.len != 0) self.design.units[0].module else u.module;
                const inst = if (u.path.len == 0)
                    top
                else
                    try self.arena.print("{s}{c}{s}", .{ top, Elaborate.sep, u.path[0 .. u.path.len - 1] });
                // "path" is "the hierarchical path to the $simparam$str
                // function": the instance, then every scope inside it that
                // encloses the call (§6.7 named blocks, §6.6.3 generate blocks
                // by their external names). The example's "testbench.dut1.mytask"
                // is the task form of the same thing.
                // ponytail: an analog function body is not a scope here (its
                // calls are inlined), so a call inside one reports the caller's path.
                const full = if (std.mem.eql(u8, nm, "instance") or self.scope_path.len == 0)
                    inst
                else
                    try self.arena.print("{s}{c}{s}", .{ inst, Elaborate.sep, self.scope_path });
                return .{ .v = try self.mir.addStrConst(self.arena, full), .ty = .string };
            }
        };
    }
    {
        const a = ex.args(e);
        const nm = if (a.len >= 1) lower_sysfunc_args.constStrArg(self, a[0]) else null;
        if (nm == null or std.mem.eql(u8, nm.?, "cwd") or std.mem.eql(u8, nm.?, "analysis_name"))
            self.out.uses.insert(.host_strings);
        // "$simparam$str is similar to $simparam", and an unknown name with
        // no fallback is an error there; $simparam$str has no fallback, and
        // Table 9-28 is the set it supports.
        if (nm) |s| if (for (simparam_str_names) |known| {
            if (std.mem.eql(u8, s, known)) break false;
        } else true) {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0811);
            b.msg("`\"{s}\"` is not a Table 9-28 string parameter", .{s});
            b.note("$simparam$str supports \"analysis_name\", \"analysis_type\", \"cwd\", \"module\", \"instance\" and \"path\"", .{});
            try b.emit();
            return poison;
        };
    }
    return null;
}

/// §9.15 `$simparam`: "If param_name is not known, and the optional
/// expression is not supplied, then an error is generated" (E0811; only for a
/// literal name, a string parameter or variable is not known until the
/// solve). Records the host fields and the Newton-iterate counter a read
/// needs (`Lowered.uses`). Returns whether it reported.
fn refuseSimparam(self: *Lower, e: Ast.ExprId) Oom!bool {
    assert(self.file.exprs.tag(e) == .sys_call);
    assert(self.file.strings.eql(self.file.exprs.strOf(e), "$simparam"));
    const args = self.file.exprs.args(e);
    if (args.len == 1) {
        if (lower_constfold.constEval(self, args[0])) |c| switch (c) {
            .str => |s| if (simparamValueIn(self.opts.directives.timescale(), s) == null and !simparamIsRuntime(s)) {
                var b = self.errWith(self.file.exprs.mainTok(e), .E0811);
                b.msg("`\"{s}\"`", .{s});
                b.note("$simparam(\"{s}\", <expression>) supplies the value to use instead, and §9.15 makes that form legal for any name", .{s});
                try b.emit();
                return true;
            },
            else => {},
        };
    }
    // The Newton-iterate counter costs an `Instance` field plus an
    // `updateState`/`stateCtl` pair, so it is emitted only for a model that
    // reads `iteration`.
    if (args.len >= 1) if (lower_sysfunc_args.constStrArg(self, args[0])) |s| {
        if (std.mem.eql(u8, s, "iteration")) self.out.uses.insert(.newton_iter);
        for (host_simparams) |h| if (std.mem.eql(u8, h.name, s)) self.out.uses.insert(h.use);
    };
    return false;
}

/// The generic system call, after `lowerSysCall`'s name-specific rules:
/// arity, the calls with their own lowering (`$clog2`, the §9.20 aliases,
/// `$table_model`, the §9.5 readers and writers, `$prev`), then one `call`
/// over the written arguments, typed by `callee.zig`'s `ty` column.
fn lowerCall(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!TypedValue {
    const ex = &self.file.exprs;
    assert(ex.tag(e) == .sys_call);
    assert(self.blockValid(self.cur));
    const sys_args = if (ex.extraOf(e) < ex.poolLen()) ex.args(e) else &[_]Ast.ExprId{};
    if (try lower_sysfunc_args.checkArity(self, ex.mainTok(e), name, sys_args)) return poison;
    if (Mir.Callee.fromName(name) == .@"$clog2") return lower_clog2.lowerClog2(self, ex.mainTok(e), sys_args[0]);
    if (Mir.Callee.fromName(name) == .@"$fopen" and try lower_sysfunc_args.checkFopenType(self, sys_args)) return poison;
    // §9.20 the two alias functions: checked and applied in lowering
    // (`checkAliasCall`), returning a constant; the call never reaches codegen.
    if (std.mem.eql(u8, name, "$analog_node_alias") or std.mem.eql(u8, name, "$analog_port_alias")) {
        return switch (try lower_hier_name.checkAliasCall(self, e, name, sys_args)) {
            .refused => poison,
            .bound => .{ .v = try self.mir.addIntConst(self.arena, 1), .ty = .integer },
            .unresolved => .{ .v = try self.mir.addIntConst(self.arena, 0), .ty = .integer },
        };
    }
    // §9.17.3 Syntax 9-12's third form: the second argument names a function.
    if (std.mem.eql(u8, name, "$limit") and sys_args.len >= 2) if (lower_limit.limitUserFunc(self, sys_args[1])) |fd|
        return lowerLimitUser(self, e, fd, sys_args);
    // §9.21 Syntax 9-16 carries a data source and a control string, neither a
    // value; `lowerTableModel` rewrites the call into one whose operands are.
    if (std.mem.eql(u8, name, "$table_model")) return lower_table_model.lowerTableModel(self, e);
    // §9.12 / IEEE 1364 §17.10: both search the host's `Instance.plusargs`, and
    // `$value$plusargs` writes its variable on a match (`lowerValuePlusargs`).
    if (std.mem.eql(u8, name, "$test$plusargs") or std.mem.eql(u8, name, "$value$plusargs"))
        self.out.uses.insert(.plusargs);
    if (std.mem.eql(u8, name, "$value$plusargs") and sys_args.len == 2 and sys_args[0] != .none and sys_args[1] != .none)
        return .{ .v = try lower_string_io.lowerValuePlusargs(self, sys_args), .ty = .integer };
    // §9.5.4.2 `$sscanf` writes through its arguments, which a `call` cannot do;
    // `lowerScan` turns it into the assignments it means.
    if (std.mem.eql(u8, name, "$sscanf"))
        return .{ .v = try lower_string_io.lowerScan(self, ex.mainTok(e), sys_args), .ty = .integer };
    // §9.5.4/§9.5.7 the same, for the three §9.5 calls with a destination
    // argument. Both halves are integer-valued (§9.5.4.1's character count,
    // §9.5.4.2's item count, §9.5.7's errno).
    if (try lower_string_io.lowerFileRead(self, ex.mainTok(e), name, sys_args)) |v|
        return .{ .v = v, .ty = .integer };
    // §9.5.3 the two writers are tasks: their whole content is the assignment to
    // the string variable, and in expression position there is nothing to assign.
    if (std.mem.eql(u8, name, "$swrite") or std.mem.eql(u8, name, "$sformat")) {
        try self.err(self.file.exprs.mainTok(e), .E0813, "`{s}` is a task and has no value; call it as a statement", .{name});
        return poison;
    }
    if (std.mem.eql(u8, name, "$prev")) return lowerPrev(self, e);
    const written = if (Mir.callee.family(Mir.Callee.fromName(name)) == .display)
        sys_args.len
    else
        try lower_sysfunc_args.writtenArgs(self, e, name, sys_args) orelse return poison;
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (sys_args[0..written], 0..) |a, i| {
        if (a == .none) continue;
        const tv = try lower_sysfunc_args.lowerSysArg(self, a, lower_sysfunc_args.takesNetRef(name));
        if (try lower_sysfunc_args.checkDescriptor(self, name, i, a, tv)) return poison;
        // §9.17.3 Syntax 9-12: a second argument is a string or an
        // analog_function_identifier, and the function form returned above.
        if (i == 1 and tv.ty != .string and tv.v != .undef and std.mem.eql(u8, name, "$limit")) {
            try self.err(ex.mainTok(a), .E0891, "its second argument is neither a string nor an analog function", .{});
            return poison;
        }
        try vals.append(self.arena, tv.v);
    }
    const v = try self.call(name, vals.items);
    // §9.5 the remaining descriptor functions ($fopen, $ftell, $fseek, $rewind,
    // $feof): ordinary values, but each one moves or creates state the next call
    // observes, so it is sequenced into the I/O phase like the tasks.
    if (Mir.callee.family(.fromName(name)) == .file_func) try lower_string_io.sequenceFileCall(self, ex.mainTok(e), name, v);
    // §12.32.1 "The sysfunctype field ... shall define the type of value
    // which a system function shall return": a vpiIntFunc's call is an
    // integer, the host's value rounded as §4.2.1.1 converts a real.
    if (Mir.Callee.fromName(name) == .systf) for (self.opts.int_systfs) |n| if (std.mem.eql(u8, n, name))
        return .{ .v = try self.emit(.fi_cast, &.{v}), .ty = .integer };
    return .{ .v = v, .ty = sysFuncTy(name) };
}

/// §9.17.3 Syntax 9-12's third form, `$limit(access, analog_function_identifier,
/// arg_list)`: the second argument names a §4.7 function, not a value. "The
/// arguments of the user-defined function shall all be declared input"
/// (E0814): the simulator supplies all of them, so an `output` formal would
/// write into the solver's iteration history.
fn lowerLimitUser(self: *Lower, e: Ast.ExprId, fd: *const Ast.FuncDecl, sys_args: []const Ast.ExprId) Oom!TypedValue {
    assert(sys_args.len >= 2);
    assert(self.file.exprs.tag(e) == .sys_call);
    // "The arguments of the user-defined function shall all be declared
    // input." The simulator supplies all of them, so an `output` formal
    // would write into the solver's iteration history.
    for (fd.args) |formal| {
        if (formal.direction == .input) continue;
        var b = self.errWith(self.file.exprs.mainTok(e), .E0814);
        b.msg("formal `{s}` of the `$limit` limiter `{s}` is declared `{s}`", .{
            self.file.str(formal.name), self.file.str(fd.name), @tagName(formal.direction),
        });
        b.note("§9.17.3: \"The arguments of the user-defined function shall all be declared input\"", .{});
        try b.emit();
        return poison;
    }
    return lower_limit.lowerLimitUser(self, e, fd, sys_args);
}

/// Engine extension (no LRM basis): `$prev(e)` is e at the last accepted
/// solve, through the `path_prev` latch §5.6.1.2 plants on ddt operands (0.0
/// before the first commit). It lets a model write SPICE's Meyer capacitance
/// averaging `(C + C_prev)/2`. A value with no unknown dependence is its own
/// past value (the same rule as `coeffIsConst`).
fn lowerPrev(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    const ex = &self.file.exprs;
    assert(ex.tag(e) == .sys_call);
    const args = ex.args(e);
    if (args.len != 1 or args[0] == .none) {
        try self.err(self.file.exprs.mainTok(e), .E0809, "`$prev` takes exactly 1 argument, got {d}", .{args.len});
        return poison;
    }
    const v = try self.toReal(try lower_expr.lowerExpr(self, args[0]));
    return .{
        .v = if (lower_reactive.coeffIsConst(self, v)) v else try self.emit(.path_prev, &.{v}),
        .ty = .real,
    };
}

/// Returns `name`'s position in the module's port list (§9.19's "port
/// identifier"), or null.
fn portOrdinal(self: *const Lower, name: []const u8) ?i64 {
    assert(name.len != 0);
    const m = self.module orelse return null;
    for (m.ports, 0..) |p, k| if (std.mem.eql(u8, self.file.str(p.name), name)) return @intCast(k);
    return null;
}

/// Returns a system function's result type from `callee.zig`'s `ty` column, the
/// list `callee.ty` reads too. An unlisted name, including a user `$name`, is real.
fn sysFuncTy(name: []const u8) Ty {
    assert(name.len != 0);
    const ty: Ty = switch (Mir.callee.ty(Mir.Callee.fromName(name))) {
        .real => .real,
        .int => .integer,
        .str => .string,
        .wide => .wide,
    };
    if (Mir.Callee.fromName(name) == .systf) assert(ty == .real); // §12.32.1: a host function is real unless registered integer
    return ty;
}

test "Clause 9 system functions: context and argument rules" {
    try Lower.expectBodies(&.{
        // §9.2 Table 9-7: `$time` reads No in the analog column.
        .{ .src = "analog begin x = $time; I(p) <+ x; end", .code = .E0806 },
        // §9.22 "Driver access functions can only be called from connect modules."
        .{ .src = "analog begin x = $driver_count(p); I(p) <+ x; end", .code = .E0818 },
        // Annex G: `$limexp` became §4.5.13's `limexp`.
        .{ .src = "analog begin x = $limexp(1.0); I(p) <+ x; end", .code = .E0808 },
        // §9.17.3: pnjlim takes vte and vcrit.
        .{ .src = "analog I(p) <+ $limit(V(p), \"pnjlim\", 0.025);", .code = .E0809 },
        // §9.15: an unknown name is an error only without the fallback.
        .{ .src = "analog begin x = $simparam(\"vera_no_such\"); I(p) <+ x; end", .code = .E0811 },
        .{ .src = "analog begin x = $simparam(\"vera_no_such\", 1.0); I(p) <+ x * V(p); end", .code = null },
        .{ .src = "analog begin sv = $simparam$str(\"vera_no_such\"); I(p) <+ V(p); end", .code = .E0811 },
        // §9.19: "a single argument, which must be a parameter identifier".
        .{ .src = "analog begin x = $param_given(x); I(p) <+ x; end", .code = .E0822 },
        .{ .src = "analog begin x = $param_given(g); I(p) <+ x * V(p); end", .code = null },
        // §4.6.1 / A.8.2: each analysis name is a quoted string.
        .{ .src = "analog begin x = analysis(dc); I(p) <+ x; end", .code = .E0574 },
        .{ .src = "analog begin x = analysis(\"dc\"); I(p) <+ x * V(p); end", .code = null },
    });
}
