//! Clause 9 system functions in analog context, and their arguments.
//!
//! In: a `$`-call in expression position. Out: a MIR call or a folded value, and
//! the host field (`$simparam`) it reads. Statement-position tasks are
//! `analog/systask.zig`'s, and the §9.13 distributions `analog/random.zig`'s; the
//! argument helpers here serve both. The §9.2 context tables
//! (`isDigitalOnlySysFunc` and its siblings) end the file.
//!
//! LRM clauses this file's code cites: §2.8.3, §2.9, §3.3, §3.4.7, §4.2.1.1, §4.3,
//! §4.3.1, §4.4, §4.5.13, §4.5.15, §4.6.1, §4.7, §4.7.2, §5.6.1.2, §6.6.3, §6.7, §7,
//! §7.6, §9.2, §9.4, §9.4.1, §9.4.2, §9.5, §9.5.1, §9.5.2, §9.5.3, §9.5.4, §9.5.4.1,
//! §9.5.4.2, §9.5.7, §9.6, §9.7, §9.8, §9.9, §9.10, §9.11, §9.12, §9.13, §9.14, §9.15,
//! §9.17, §9.17.3, §9.18, §9.19, §9.20, §9.21, §9.22, §9.22.1, §9.22.2, §9.22.3, §9.23,
//! §9.23.1, §9.23.4, §12.32.1.
//! IEEE 1364-2005 clauses cited: §17.1.1.1, §17.10, §17.11.1.

const std = @import("std");
const hier_param = @import("elab").hier_param;
const Lower = @import("lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_random = @import("random.zig");
const lower_expr = @import("expr.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_limit = @import("limit.zig");
const lower_systask = @import("systask.zig");
const lower_table_model = @import("table_model.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Elaborate = @import("elab").Elaborate;
const Lexer = @import("frontend").Lexer;
const simparam = @import("ir").simparam;
const fopen_types = @import("kernels").fopen_types;
const simparamValueIn = simparam.simparamValueIn;
const simparamIsRuntime = simparam.simparamIsRuntime;
const host_simparams = simparam.host_simparams;
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;

// ---- ch9 system functions ---------------------------------------------------

/// E1014: a source call spells a name VerA mints for itself
/// (`Callee.synthetic`). True when refused.
pub fn refuseReserved(self: *Lower, tok: u32, name: []const u8) Oom!bool {
    if (!Mir.Callee.fromName(name).synthetic()) return false;
    try self.err(tok, .E1014, "`{s}`", .{name});
    return true;
}

/// Lowers a Clause 9 system function in expression position. The context and
/// validity rules are checked here; what survives becomes a `call` whose simulator
/// semantics codegen's `emitCall` owns, or a folded value.
pub fn lowerSysCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    if (try refuseReserved(self, ex.mainTok(e), name)) return poison;
    if (isDigitalOnlySysFunc(name)) { // §9.2
        try self.err(self.file.exprs.mainTok(e), .E0806, "`{s}`", .{name});
        return poison;
    }
    // §9.22/§9.23 the driver access family, refused outside a connect module
    // (see `isConnectModuleOnlySysFunc`).
    if (isConnectModuleOnlySysFunc(name)) {
        // Tables 9-19 and 9-20 split the connect module in two: every driver
        // function reads "Supported in analog context of connectmodule: No"
        // ($receiver_count alone reads Yes). This call is in a connect module's
        // analog block, so the fence it hits is §9.2's analog column.
        const in_cm = self.cur_unit < self.unit_paths.len and self.unit_paths[self.cur_unit].decl.is_connect;
        if (in_cm and !std.mem.eql(u8, name, "$receiver_count")) {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0806);
            b.msg("`{s}` in the analog block of a connect module", .{name});
            b.note("§9.2 Tables 9-19/9-20: \"Supported in analog context of connectmodule: No\"; call it from an `always` or `initial` block of the connect module", .{});
            try b.emit();
            return poison;
        }
        var b = self.errWith(self.file.exprs.mainTok(e), .E0818);
        b.msg("`{s}` can only be called from a connect module", .{name});
        b.note("§9.22: \"Driver access functions can only be called from connect modules.\" This is a `module`", .{});
        try b.emit();
        return poison;
    }
    // §4.6.1 "The analysis() function takes one or more string arguments", and
    // A.8.2 puts the quotation marks in the production:
    // `analysis ( " analysis_identifier " { , " analysis_identifier " } )`.
    // So each argument is a string literal and there is at least one.
    if (std.mem.eql(u8, name, "analysis")) {
        const args = ex.args(e);
        if (args.len == 0) {
            try self.err(ex.mainTok(e), .E0574, "`analysis()` names no analysis", .{});
            return poison;
        }
        for (args) |a| if (a == .none or ex.tag(a) != .str_literal) {
            try self.err(if (a != .none) ex.mainTok(a) else ex.mainTok(e), .E0574, "each argument of `analysis()` is a quoted analysis name", .{});
            return poison;
        };
    }
    // §9.19: "The $param_given() function takes a single argument, which must
    // be a parameter identifier", and $port_connected's "must be a port
    // identifier". Elaboration already answered every call whose argument was
    // one of an instance's own parameters or ports (`rewriteSysCall`), so what
    // reaches here is the top module's, or an argument of the wrong kind.
    const is_pg = std.mem.eql(u8, name, "$param_given");
    if (is_pg or std.mem.eql(u8, name, "$port_connected")) {
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
    }
    // §4.3.1 Table 4-14 gives these system spellings the same operand-sensitive
    // result types as their traditional spellings. A generic call's name-only
    // sysFuncTy cannot express that: it would turn integer division into real
    // division. Use typed arithmetic opcodes, after the context checks above.
    if (std.mem.eql(u8, name, "$abs") or std.mem.eql(u8, name, "$min") or
        std.mem.eql(u8, name, "$max")) return lower_expr.lowerBuiltin(self, e);
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
    // §9.17.3 fixes the arity of the two algorithms it names outright: fetlim
    // takes a third argument (the threshold voltage) and pnjlim a third and a
    // fourth (vte and vcrit). Checked here, not in codegen, because codegen may
    // silently decline any limiting call (§4.5.15) while a wrong arity is a source
    // error. Only these two literal names: an unknown string is treated "just as
    // if no string had been supplied".
    if (std.mem.eql(u8, name, "$limit")) {
        // VerA's `vera_timepoint` (§2.9): a limiter reads the iterate.
        if (self.tp_cur != null) {
            try self.err(ex.mainTok(e), .E0530, "`$limit` (§9.17.3)", .{});
            return poison;
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
            return poison;
        }
        if (args.len >= 2) {
            if (lower_constfold.constEval(self, args[1])) |c| switch (c) {
                .str => |s| {
                    const need: usize = if (std.mem.eql(u8, s, "pnjlim"))
                        4
                    else if (std.mem.eql(u8, s, "fetlim")) 3 else 0;
                    if (need != 0 and args.len < need) {
                        try self.err(self.file.exprs.mainTok(e), .E0809, "`\"{s}\"` needs {d} arguments to `$limit`, got {d}", .{ s, need, args.len });
                        return poison;
                    }
                },
                else => {},
            };
        }
    }
    // §9.15: "If param_name is not known, and the optional expression is not
    // supplied, then an error is generated." Only for a literal name: a string
    // parameter or variable is not known until the solve.
    if (std.mem.eql(u8, name, "$simprobe")) return lower_hier_name.lowerSimprobe(self, e);
    // §9.15 Table 9-28's hierarchy rows are elaboration facts, answered here from
    // `cur_unit`, the instance that wrote this block: "module" is "the name of the
    // module from which $simparam$str is called" and "instance" is "the
    // hierarchical name of the instance". Codegen only sees the flattened module.
    if (std.mem.eql(u8, name, "$simparam$str") and (self.cur_unit < self.unit_paths.len or self.module != null)) {
        const a = ex.args(e);
        if (a.len >= 1) if (constStrArg(self, a[0])) |nm| {
            // A design with no instances has no unit table: its one unit is the
            // top module, at the root.
            const u: struct { module: []const u8, path: []const u8 } = if (self.cur_unit < self.unit_paths.len)
                .{ .module = self.unit_paths[self.cur_unit].module, .path = self.unit_paths[self.cur_unit].path }
            else
                .{ .module = self.file.str(self.module.?.name), .path = "" };
            if (std.mem.eql(u8, nm, "module"))
                return .{ .v = try self.mir.addStrConst(self.arena, u.module), .ty = .string };
            // §9.15's worked example produces "testbench.dut1": a top-level
            // module's instance name is its module name, and the path is joined
            // to it by §6.7's period. `path` already carries the separator.
            if (std.mem.eql(u8, nm, "instance") or std.mem.eql(u8, nm, "path")) {
                const top = if (self.unit_paths.len != 0) self.unit_paths[0].module else u.module;
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
    // §9.15 Table 9-28 "cwd" and "analysis_name" describe the host's run, which
    // writes them into the instance; a name read at run time may be either.
    if (std.mem.eql(u8, name, "$simparam$str")) {
        const a = ex.args(e);
        const nm = if (a.len >= 1) constStrArg(self, a[0]) else null;
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
    if (std.mem.eql(u8, name, "$simparam")) {
        const args = ex.args(e);
        if (args.len == 1) {
            if (lower_constfold.constEval(self, args[0])) |c| switch (c) {
                .str => |s| if (simparamValueIn(self.directives.timescale(), s) == null and !simparamIsRuntime(s)) {
                    var b = self.errWith(self.file.exprs.mainTok(e), .E0811);
                    b.msg("`\"{s}\"`", .{s});
                    b.note("$simparam(\"{s}\", <expression>) supplies the value to use instead, and §9.15 makes that form legal for any name", .{s});
                    try b.emit();
                    return poison;
                },
                else => {},
            };
        }
        // The Newton-iterate counter costs an `Instance` field plus an
        // `updateState`/`stateCtl` pair, so it is emitted only for a model that
        // reads `iteration`.
        if (args.len >= 1) if (constStrArg(self, args[0])) |s| {
            if (std.mem.eql(u8, s, "iteration")) self.out.uses.insert(.newton_iter);
            for (host_simparams) |h| if (std.mem.eql(u8, h.name, s)) self.out.uses.insert(h.use);
        };
    }
    const sys_args = if (ex.extraOf(e) < ex.poolLen()) ex.args(e) else &[_]Ast.ExprId{};
    if (try checkArity(self, ex.mainTok(e), name, sys_args)) return poison;
    if (Mir.Callee.fromName(name) == .@"$clog2") return lowerClog2(self, ex.mainTok(e), sys_args[0]);
    if (Mir.Callee.fromName(name) == .@"$fopen" and try checkFopenType(self, sys_args)) return poison;
    // §9.20 the two alias functions: checked and applied in lowering
    // (`checkAliasCall`), returning a constant; the call never reaches codegen.
    if (std.mem.eql(u8, name, "$analog_node_alias") or std.mem.eql(u8, name, "$analog_port_alias")) {
        return switch (try lower_hier_name.checkAliasCall(self, e, name, sys_args)) {
            .refused => poison,
            .bound => .{ .v = try self.mir.addIntConst(self.arena, 1), .ty = .integer },
            .unresolved => .{ .v = try self.mir.addIntConst(self.arena, 0), .ty = .integer },
        };
    }
    // §9.17.3 Syntax 9-12's THIRD form, `$limit(access, analog_function_identifier,
    // arg_list)`. The second argument names a §4.7 function, not a value.
    if (std.mem.eql(u8, name, "$limit") and sys_args.len >= 2) {
        if (lower_limit.limitUserFunc(self, sys_args[1])) |fd| {
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
    }
    // §9.21 Syntax 9-16 carries a data source and a control string, neither a
    // value; `lowerTableModel` rewrites the call into one whose operands are.
    if (std.mem.eql(u8, name, "$table_model")) return lower_table_model.lowerTableModel(self, e);
    // §9.12 / IEEE 1364 §17.10: both search the host's `Instance.plusargs`, and
    // `$value$plusargs` writes its variable on a match (`lowerValuePlusargs`).
    if (std.mem.eql(u8, name, "$test$plusargs") or std.mem.eql(u8, name, "$value$plusargs"))
        self.out.uses.insert(.plusargs);
    if (std.mem.eql(u8, name, "$value$plusargs") and sys_args.len == 2 and sys_args[0] != .none and sys_args[1] != .none)
        return .{ .v = try lower_systask.lowerValuePlusargs(self, sys_args), .ty = .integer };
    // §9.5.4.2 `$sscanf` writes through its arguments, which a `call` cannot do;
    // `lowerScan` turns it into the assignments it means.
    if (std.mem.eql(u8, name, "$sscanf"))
        return .{ .v = try lower_systask.lowerScan(self, ex.mainTok(e), sys_args), .ty = .integer };
    // §9.5.4/§9.5.7 the same, for the three §9.5 calls with a destination
    // argument. Both halves are integer-valued (§9.5.4.1's character count,
    // §9.5.4.2's item count, §9.5.7's errno).
    if (try lower_systask.lowerFileRead(self, ex.mainTok(e), name, sys_args)) |v|
        return .{ .v = v, .ty = .integer };
    // §9.5.3 the two writers are tasks: their whole content is the assignment to
    // the string variable, and in expression position there is nothing to assign.
    if (std.mem.eql(u8, name, "$swrite") or std.mem.eql(u8, name, "$sformat")) {
        try self.err(self.file.exprs.mainTok(e), .E0813, "`{s}` is a task and has no value; call it as a statement", .{name});
        return poison;
    }
    // Engine extension (no LRM basis): `$prev(e)` is e at the last accepted
    // solve, through the `path_prev` latch §5.6.1.2 plants on ddt operands
    // (0.0 before the first commit). It lets a model write SPICE's Meyer
    // capacitance averaging `(C + C_prev)/2`. A value with no unknown dependence
    // is its own past value (same rule as `coeffIsConst`).
    if (std.mem.eql(u8, name, "$prev")) {
        const args = ex.args(e);
        if (args.len != 1 or args[0] == .none) {
            try self.err(self.file.exprs.mainTok(e), .E0809, "`$prev` takes exactly 1 argument, got {d}", .{args.len});
            return poison;
        }
        const v = try self.toReal(try lower_expr.lowerExpr(self, args[0]));
        return .{
            .v = if (lower_contrib.coeffIsConst(self, v)) v else try self.emit(.path_prev, &.{v}),
            .ty = .real,
        };
    }
    const written = if (Mir.callee.family(Mir.Callee.fromName(name)) == .display)
        sys_args.len
    else
        try writtenArgs(self, e, name, sys_args) orelse return poison;
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (sys_args[0..written], 0..) |a, i| {
        if (a == .none) continue;
        const tv = try lowerSysArg(self, a, takesNetRef(name));
        if (try checkDescriptor(self, name, i, a, tv)) return poison;
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
    if (Mir.callee.family(.fromName(name)) == .file_func) try lower_systask.sequenceFileCall(self, ex.mainTok(e), name, v);
    // §12.32.1 "The sysfunctype field ... shall define the type of value
    // which a system function shall return": a vpiIntFunc's call is an
    // integer, the host's value rounded as §4.2.1.1 converts a real.
    if (Mir.Callee.fromName(name) == .systf) for (self.int_systfs) |n| if (std.mem.eql(u8, n, name))
        return .{ .v = try self.emit(.fi_cast, &.{v}), .ty = .integer };
    return .{ .v = v, .ty = sysFuncTy(name) };
}

/// §9.14 / IEEE 1364-2005 §17.11.1's integral argument and its source width,
/// shared by expression and statement calls (the latter discard the result).
pub fn lowerClog2(self: *Lower, tok: u32, arg: Ast.ExprId) Oom!TypedValue {
    const tv = try lower_expr.lowerClog2Arg(self, arg, null);
    if (tv.ty != .integer or arg == .none) {
        // A poisoned argument was reported where it failed (E0130).
        if (tv.v != .undef or arg == .none) try self.err(tok, .E0892, "got {s}", .{@tagName(tv.ty)});
        return poison;
    }
    const width = lower_constfold.clog2Width(self, arg) orelse 64;
    if (width > 64 and !lower_constfold.clog2WideCarrier(self, arg, 0)) {
        try self.err(tok, .E0893, "the {d}-bit operand has no exact wide carrier", .{width});
        return poison;
    }
    // The second MIR operand is source metadata, not a second source
    // argument. The unsigned conversion needs it after lowering.
    var v = tv.v;
    var w = try self.mir.addIntConst(self.arena, width);
    // VD-089: a card-set `hostSizedParam` is an unsized integer, 32 bits, or
    // 64 when a card value needs them, so the operand is lowered again under
    // that width and the card's `$param_given` picks which reading counts.
    // ponytail: one `given` and one `fits` for all such parameters of the
    // operand; a mix of set and unset ones reads every one as set.
    var host: HostSized = .{};
    try hostSized(self, arg, &host);
    if (host.given) |given| {
        self.clog2_host = 32;
        const v32 = try lower_expr.lowerClog2Arg(self, arg, null);
        self.clog2_host = 64;
        const v64 = try lower_expr.lowerClog2Arg(self, arg, null);
        self.clog2_host = 0;
        const fits = host.fits orelse unreachable; // set with `given`
        v = try self.emit(.select, &.{ given, try self.emit(.select, &.{ fits, v32.v, v64.v }), v });
        const w_host = try self.emit(.select, &.{ fits, try self.mir.addIntConst(self.arena, 32), try self.mir.addIntConst(self.arena, 64) });
        w = try self.emit(.select, &.{ given, w_host, w });
    }
    return .{ .v = try self.call("$clog2", &.{ v, w }), .ty = .integer };
}

/// `lowerClog2`'s card facts over the `hostSizedParam`s an operand reads:
/// whether the card set any of them, and whether every value fits 32 bits.
const HostSized = struct { given: ?Mir.Value = null, fits: ?Mir.Value = null };

fn hostSized(self: *Lower, e: Ast.ExprId, acc: *HostSized) Oom!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .ident) if (lower_constfold.hostSizedParam(self, self.file.str(ex.strOf(e)))) |pi| {
        const p = self.param_values.items[pi];
        const given = try self.toBool(.{ .v = try self.call("$param_given", &.{p}), .ty = .integer });
        const fits = try self.emit(.logand, &.{
            try self.emit(.ige, &.{ p, try self.mir.addIntConst(self.arena, std.math.minInt(i32)) }),
            try self.emit(.ile, &.{ p, try self.mir.addIntConst(self.arena, std.math.maxInt(i32)) }),
        });
        acc.given = if (acc.given) |g| try self.emit(.logor, &.{ g, given }) else given;
        acc.fits = if (acc.fits) |f| try self.emit(.logand, &.{ f, fits }) else fits;
        return;
    };
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| try hostSized(self, c, acc);
}

/// Returns how many leading arguments of a system call were written, or null
/// after reporting E0894. A.8.2's analog_system_function_call admits an empty
/// slot anywhere, but only the function's own clause gives one a meaning:
/// trailing empty slots are optional arguments not supplied, while one before a
/// written argument would shift every later argument into the wrong position
/// (`$hypot(x, , y)` is not `$hypot(x, y)`), and dropping a trailing one must
/// still leave an arity the function admits. The §9.4 display family is not
/// judged here: IEEE 1364 §17.1.1.1 gives its empty argument a meaning.
pub fn writtenArgs(self: *Lower, e: Ast.ExprId, name: []const u8, args: []const Ast.ExprId) Oom!?usize {
    var n = args.len;
    while (n > 0 and args[n - 1] == .none) n -= 1;
    for (args[0..n], 1..) |a, pos| if (a == .none) {
        try self.err(self.file.exprs.mainTok(e), .E0894, "argument {d} of `{s}` is empty", .{ pos, name });
        return null;
    };
    if (n != args.len and !Mir.callee.arity(Mir.Callee.fromName(name)).admits(n)) {
        try self.err(self.file.exprs.mainTok(e), .E0894, "argument {d} of `{s}` is empty", .{ n + 1, name });
        return null;
    }
    return n;
}

/// Checks a system call's argument count against `callee.Info.args` and returns
/// true when it reported an error. `args.len` counts A.6.9 empty slots too:
/// `$fflush(,)` has two arguments, both null. §9.14's `$` math spellings report
/// E0506, the code of the §4.3 operators they alias.
pub fn checkArity(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!bool {
    const c = Mir.Callee.fromName(name);
    const a = Mir.callee.arity(c);
    if (a.admits(args.len)) return false;
    // `$log10` is Table 9-11's spelling of Table 4-14's `log`.
    const math = c == .@"$log10" or lower_expr.unaryMathOp(name[1..]) != null or
        lower_expr.binaryMathOp(name[1..]) != null;
    const want: u8 = if (args.len < a.min) a.min else a.max;
    if (math) {
        try self.err(tok, .E0506, "`{s}()` takes {d}", .{ name, want });
        return true;
    }
    var b = self.errWith(tok, .E0887);
    if (a.min == a.max)
        b.msg("`{s}` takes {d} argument{s}, got {d}", .{ name, want, if (want == 1) "" else "s", args.len })
    else if (args.len < a.min)
        b.msg("`{s}` takes at least {d} argument{s}, got {d}", .{ name, want, if (want == 1) "" else "s", args.len })
    else
        b.msg("`{s}` takes at most {d} argument{s}, got {d}", .{ name, want, if (want == 1) "" else "s", args.len });
    try b.emit();
    return true;
}

/// Checks that descriptor argument `i` (`callee.Info.fd`) lowered to an integer,
/// "a 32-bit integer" (LRM §9.5.1, §9.5.2), and returns true when it reported an
/// error. Takes the already lowered operand so a `$fopen` in it runs once.
pub fn checkDescriptor(self: *Lower, name: []const u8, i: usize, arg: Ast.ExprId, tv: TypedValue) Oom!bool {
    const at = Mir.callee.fdArg(Mir.Callee.fromName(name)) orelse return false;
    if (i != at or tv.ty == .integer) return false;
    try self.err(self.file.exprs.mainTok(arg), .E0888, "`{s}`'s descriptor argument is {s}", .{
        name,
        switch (tv.ty) {
            .real => "a real",
            .string => "a string",
            .integer => unreachable,
            .wide => unreachable, // `lowerExpr` types no value `.wide`: a whole wide `reg` read is E0222
        },
    });
    return true;
}

/// §9.5.1 Table 9-24: "type is a string expression containing a character
/// string of one of the forms in Table 9-24". Only a literal can be judged.
fn checkFopenType(self: *Lower, args: []const Ast.ExprId) Oom!bool {
    if (args.len != 2 or args[1] == .none) return false;
    const s = constStrArg(self, args[1]) orelse return false;
    if (fopen_types.has(s)) return false;
    try self.err(self.file.exprs.mainTok(args[1]), .E0889, "`\"{s}\"`", .{s});
    return true;
}

/// Returns `name`'s position in the module's port list (§9.19's "port
/// identifier"), or null.
fn portOrdinal(self: *const Lower, name: []const u8) ?i64 {
    const m = self.module orelse return null;
    for (m.ports, 0..) |p, k| if (std.mem.eql(u8, self.file.str(p.name), name)) return @intCast(k);
    return null;
}

/// Returns the constant string an argument folds to, or null for any other expression.
pub fn constStrArg(self: *Lower, e: Ast.ExprId) ?[]const u8 {
    if (e == .none) return null;
    const c = lower_constfold.constEval(self, e) orelse return null;
    return switch (c) {
        .str => |s| s,
        else => null,
    };
}

/// The Clause 9 names whose argument is a net or port reference: §9.19
/// `$port_connected`, §9.20 `$analog_node_alias`/`$analog_port_alias`. The §9.22/§9.23
/// driver functions are refused before their arguments lower, so they are not listed.
fn takesNetRef(name: []const u8) bool {
    const fns = [_][]const u8{ "$port_connected", "$analog_node_alias", "$analog_port_alias" };
    for (fns) |f| if (std.mem.eql(u8, name, f)) return true;
    return false;
}

/// Returns a string literal's lexical bytes for direct output (LRM §9.4.2), which
/// keep what string storage (§3.3) drops, or null when `e` is not a quoted source
/// token. The bytes are arena-owned.
pub fn outputLiteral(self: *Lower, e: Ast.ExprId) Oom!?[]const u8 {
    if (e == .none or self.file.exprs.tag(e) != .str_literal) return null;
    const span = self.tokenSpan(self.file.exprs.mainTok(e));
    const raw = self.src[span.start..span.end];
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"' or
        std.mem.findScalar(u8, raw, '\\') == null) return null;
    return try Lexer.stringContents(self.arena, raw);
}

/// Lowers a format-string argument, keeping a literal's lexical bytes (see `outputLiteral`).
pub fn lowerFormatArg(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (try outputLiteral(self, e)) |bytes|
        return .{ .v = try self.mir.addStrConst(self.arena, bytes), .ty = .string };
    return lower_expr.lowerExpr(self, e);
}

/// Lowers argument `e` of system task `name`: as a format string when the task takes
/// one, otherwise through `lowerSysArg`.
pub fn lowerTaskArg(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!TypedValue {
    // Display/file-output operands run in the accepted-point task phase, not
    // the per-iteration residual. An unused remainder in an inlined function
    // argument still checks, but only on the display phase's effect root.
    const phase = self.runtime_error_phase;
    defer self.runtime_error_phase = phase;
    switch (Mir.callee.family(.fromName(name))) {
        .display, .simctl, .file_out => self.runtime_error_phase = .display,
        .none, .file_func, .file_read => {},
    }
    if (Mir.callee.takesFormat(.fromName(name))) return lowerFormatArg(self, e);
    return lowerSysArg(self, e, takesNetRef(name));
}

/// Lowers a system call argument. With `net_ok` (the `takesNetRef` names), a bare
/// net name lowers to its `nodes` row; otherwise it goes through `lowerExpr`,
/// which reports §4.4's E0315 for a net used as a value.
pub fn lowerSysArg(self: *Lower, e: Ast.ExprId, net_ok: bool) Oom!TypedValue {
    const ex = &self.file.exprs;
    if (net_ok and ex.tag(e) == .ident) {
        const name = self.file.str(ex.strOf(e));
        const is_value = self.vars.contains(name) or self.param_index.contains(name) or
            self.consts.contains(name);
        if (!is_value) {
            if (self.node_voltages.get(name)) |idx|
                return .{ .v = try self.mir.addIntConst(self.arena, idx), .ty = .integer };
        }
    }
    return lower_expr.lowerExpr(self, e);
}

/// Returns a system function's result type from `callee.zig`'s `ty` column, the
/// list `callee.ty` reads too. An unlisted name, including a user `$name`, is real.
fn sysFuncTy(name: []const u8) Ty {
    return switch (Mir.callee.ty(Mir.Callee.fromName(name))) {
        .real => .real,
        .int => .integer,
        .str => .string,
        .wide => .wide,
    };
}

// ---- §9.2 which context a system function belongs to -----------------------

/// Whether `name` is a system function whose §9.2 "supported in analog
/// context" cell says No, across the seven Chapter 9 tables (E0806).
///
/// A name test, with no context flag: every statement lowering sees is in the
/// analog context (A.6.2 `analog_construct`, with §4.7.2 function bodies
/// inlined into one).
pub fn isDigitalOnlySysFunc(name: []const u8) bool {
    // ponytail: add the flag when a §7 digital block is lowered here.
    const digital_only = comptime nameSet(&.{
        // Table 9-1 (§9.4.1) — radix variants and the $monitor mode switches.
        "$displayb",         "$displayh",         "$displayo",
        "$strobeb",          "$strobeh",          "$strobeo",
        "$writeb",           "$writeh",           "$writeo",
        "$monitorb",         "$monitorh",         "$monitoro",
        "$monitoron",        "$monitoroff",
        // Table 9-2 (§9.5) — the same radix story against a descriptor, plus
        // the byte/vector reads and the two digital-netlist loaders.
              "$fdisplayb",
        "$fdisplayh",        "$fdisplayo",        "$fwriteb",
        "$fwriteh",          "$fwriteo",          "$fstrobeb",
        "$fstrobeh",         "$fstrobeo",         "$fmonitorb",
        "$fmonitorh",        "$fmonitoro",        "$swriteb",
        "$swriteh",          "$swriteo",          "$fgetc",
        "$ungetc",           "$fread",            "$readmemb",
        "$readmemh",         "$sdf_annotate",
        // Table 9-3 (§9.6) — the timescale tick, which the analog kernel has
        // no notion of.
            "$printtimescale",
        "$timeformat",
        // Table 9-5 (§9.8) — "Verilog AMS HDL does not extend the PLA modeling
        // tasks defined in IEEE Std 1364 Verilog." All sixteen spellings; the
        // `$` inside the name is an ordinary identifier character (§2.8.3), so
        // each of these is one token.
              "$async$and$array",  "$async$and$plane",
        "$async$nand$array", "$async$nand$plane", "$async$or$array",
        "$async$or$plane",   "$async$nor$array",  "$async$nor$plane",
        "$sync$and$array",   "$sync$and$plane",   "$sync$nand$array",
        "$sync$nand$plane",  "$sync$or$array",    "$sync$or$plane",
        "$sync$nor$array",   "$sync$nor$plane",
        // Table 9-6 (§9.9) — "Verilog AMS HDL does not extend the stochastic
        // analysis tasks defined in IEEE Std 1364 Verilog."
          "$q_initialize",
        "$q_remove",         "$q_exam",           "$q_add",
        "$q_full",
        // Table 9-7 (§9.10) — tick counts. $abstime is the analog spelling and
        // is the one row of that table with Yes in both columns; §9.10's NOTE
        // additionally deprecates $realtime in the analog context.
                  "$time",             "$stime",
        "$realtime",
        // Table 9-8 (§9.11) — the extension is four names, not two:
        // "$bitstoreal and $realtobits,$rtoi and $itor can be used in the
        // analog context". Table 9-8's analog column agrees — only $signed and
        // $unsigned read No, and both presuppose a sized vector.
                "$signed",           "$unsigned",
    });
    return digital_only.has(name);
}

/// Whether `name` is analog-only: its §9.2 "Supported in digital context" cell
/// is No and its analog cell Yes. §9.7 says it of the severity tasks in prose.
pub fn isAnalogOnlySysFunc(name: []const u8) bool {
    const analog_only = comptime nameSet(&.{
        "$debug", "$fdebug", // Tables 9-1/9-2
        "$fatal", "$warning", "$error", "$info", // Table 9-4
        "$simprobe", // §9.15
        "$discontinuity", "$limit", "$bound_step", // §9.17
        "$vera_reject_step", // VerA's step rejection
        "$param_given", "$port_connected", // §9.19
        "$analog_node_alias", "$analog_port_alias", // §9.20
    });
    return analog_only.has(name);
}

/// §9.22 paragraph 3, second sentence: "Driver access functions can only be
/// called from connect modules." §9.23 repeats the fence for its four
/// supplementary functions ("supported in the digital context of
/// connectmodules"), and Table 9-19 gives every name below "Supported in analog
/// context of connectmodule: No".
///
/// A rule about the call site: an ordinary module is not a connect module, so
/// the call is illegal on sight. Answering 0 in codegen would look right and be
/// wrong, since §9.22.2/§9.22.3/§9.23.x index "between 0 and N-1".
///
/// A name test like `isDigitalOnlySysFunc`: every call site lowering reaches is
/// inside the elaborated device, and `elaborate.pickTop` never picks a connect
/// module (§7.6), so a driver call inside one is never lowered here.
///
/// `$receiver_count` is listed because its "Non-normative" §9.22.1 paragraph
/// sits inside §9.22, takes the same `signal_name` argument, and Table 9-19
/// carries it with the rest.
fn isConnectModuleOnlySysFunc(name: []const u8) bool {
    const cm_only = comptime nameSet(&.{
        // §9.22.1–§9.22.3 and the §9.22.1 non-normative paragraph.
        "$driver_count",         "$receiver_count", "$driver_state",
        "$driver_strength",
        // §9.23.1–§9.23.4, the supplementary pending-event queries.
             "$driver_delay",   "$driver_next_state",
        "$driver_next_strength", "$driver_type",
    });
    return cm_only.has(name);
}

/// `names` as a comptime set, so each list above keeps its per-table comments.
fn nameSet(comptime names: []const []const u8) std.StaticStringMap(void) {
    var kvs: [names.len]struct { []const u8 } = undefined;
    for (names, &kvs) |n, *kv| kv.* = .{n};
    return .initComptime(kvs);
}

/// §9.15 Table 9-28: the string parameter names `$simparam$str` "shall"
/// support, and the only ones VerA knows.
const simparam_str_names = [_][]const u8{ "analysis_name", "analysis_type", "cwd", "module", "instance", "path" };

test isDigitalOnlySysFunc {
    try std.testing.expect(isDigitalOnlySysFunc("$time")); // Table 9-7
    try std.testing.expect(isDigitalOnlySysFunc("$async$and$array")); // Table 9-5, one token (§2.8.3)
    try std.testing.expect(isDigitalOnlySysFunc("$displayb")); // Table 9-1
    try std.testing.expect(!isDigitalOnlySysFunc("$abstime")); // Yes in both columns
    try std.testing.expect(!isDigitalOnlySysFunc("$realtobits")); // §9.11 extends it to analog
    try std.testing.expect(!isDigitalOnlySysFunc("$strobe"));
}

test isAnalogOnlySysFunc {
    try std.testing.expect(isAnalogOnlySysFunc("$bound_step"));
    try std.testing.expect(isAnalogOnlySysFunc("$fatal"));
    try std.testing.expect(!isAnalogOnlySysFunc("$display"));
}

test isConnectModuleOnlySysFunc {
    try std.testing.expect(isConnectModuleOnlySysFunc("$driver_count"));
    try std.testing.expect(isConnectModuleOnlySysFunc("$receiver_count"));
    try std.testing.expect(isConnectModuleOnlySysFunc("$driver_type"));
    try std.testing.expect(!isConnectModuleOnlySysFunc("$port_connected"));
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
