//! An expression in its scope in, its §5.4/§5.5 self-determined width and signedness out (`Run.types`), checked once before any process runs.
//! Cites: IEEE 1364-2005 §4.8.1, §5.1.1, §5.1.14, §5.4, §5.5.1 Table 5-22, §5.5.2, A.8.
//!
//! Contents:
//! - `pub fn literalWidth(n: IntLiteral) u32`
//! - `pub fn stringWidth(text: []const u8) u32`
//! - `pub fn common(a: Type, b: Type) Type`
//! - `pub fn typeOf(self: *Run, e: Ast.ExprId) Type`
//! - `pub fn checkExpr(self: *Run, e: Ast.ExprId) Error!void`
//! - `pub fn rememberVpiArgument(self: *Run, e: Ast.ExprId) Error!void`
//! - `pub fn infer(self: *Run, e: Ast.ExprId) Error!Type`
//! AST -> bytecode: one process body or driver expression, in its instance
//! scope, -> `Instruction` rows in `Run.code`, each expression's type in
//! `Run.types`, and the static slot lists drivers and `@*` wait on; or E1100
//! before any process has run.
//! Clauses: IEEE 1364-2005 §4.8.1, §5.1.1, §5.1.14, §5.2.1/§5.2.2, §5.5.1
//! Table 5-22, §5.10.4, §6.1, §8.5.3.3/§8.5.3.4, §9.3, §9.5, §9.6, §9.7.1 to
//! §9.7.7, §9.8.2, §10.2.2/§10.2.3, §10.4.4/§10.4.5, §12.7, §17.1 to §17.11,
//! §20.4, A.6.5; VAMS §7.3.6.3 analog probes, §9.14 Table 9-11 `$clog2`,
//! §9.22 driver access.
const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const exec = @import("exec.zig");
const evaluate = @import("evaluate.zig");
const deep = @import("base").deep_stack;
const display = @import("display.zig");
const driver = @import("driver.zig");
const system = @import("system.zig");
const elab = @import("elab.zig");
const evcd = @import("evcd.zig");
const vcd = @import("vcd.zig");
const root = @import("root.zig");
const Error = root.Error;
const Run = root.Run;
const SpecExpr = root.SpecExpr;
const expectRun = root.expectRun;
const expectRejected = root.expectRejected;
const filled = @import("net.zig").filled;
const bytecode = @import("bytecode.zig");
const compile = @import("compile.zig");
const constness = @import("constness.zig");
const system_functions = @import("system_functions.zig");
const wait_lists = @import("wait_lists.zig");
const Type = bytecode.Type;
const checkArgs = compile.checkArgs;
const checkTarget = wait_lists.checkTarget;
const constantExpression = constness.constantExpression;
const element = compile.element;
const enabledTask = compile.enabledTask;
const probeTerminal = wait_lists.probeTerminal;
const real_type = bytecode.real_type;
const subIn = compile.subIn;
const sys_fns = system_functions.sys_fns;
const unsizedConcatOperand = constness.unsizedConcatOperand;
const vams_digital_unrun = system_functions.vams_digital_unrun;

/// The lexer's literal row, which the frontend does not re-export.
const IntLiteral = @typeInfo(@TypeOf(Ast.ExprStore.intLiteral)).@"fn".return_type.?;

/// A decimal literal's width: its size, or for an unsized one 32 bits, which
/// §3.5.1 makes a minimum: a value that does not fit keeps the frontend's 64.
pub fn literalWidth(n: IntLiteral) u32 {
    if (n.width != 0) return n.width;
    // VD-131: an unsized based one is as wide as its digits past 32 bits.
    if (n.digit_bits != 0) return @max(32, n.digit_bits);
    const fits = if (n.signed) n.value >= std.math.minInt(i32) and n.value <= std.math.maxInt(i32) else n.value >= 0 and n.value <= std.math.maxInt(u32);
    return if (fits) 32 else 64;
}

/// §3.6 a string literal's width: eight bits per character, and 8 for "".
pub fn stringWidth(text: []const u8) u32 {
    return @intCast(@max(1, text.len) * 8);
}

/// §5.5.1/§4.8.1: an operator with a real operand is real.
pub fn common(a: Type, b: Type) Type {
    if (a.real or b.real) return real_type;
    return .{ .width = @max(a.width, b.width), .signed = a.signed and b.signed };
}

/// The natural type `checkExpr` gave `e` in the executing scope's
/// specialization (`Run.specOf`). Asserts `e` was checked: an untyped row is
/// unreachable.
pub fn typeOf(self: *Run, e: Ast.ExprId) Type {
    assert(e != .none);
    const i = @backingInt(e);
    return switch (self.ty_state[i]) {
        .one => self.types[i],
        .many => self.spec_types.get(.{ .spec = self.specOf(self.scope), .e = e }).?,
        .untyped => unreachable, // infer runs before any evaluation
    };
}

/// Types `e` and every operand under it in the executing scope (§5.5.1),
/// recording each in `Run.types`/`spec_types`, or fails with E1100 on a
/// form digital execution does not implement. Must run before `typeOf` or
/// any evaluation of `e`.
pub fn checkExpr(self: *Run, e: Ast.ExprId) Error!void {
    assert(e != .none);
    _ = try inferValue(self, e);
}

pub fn rememberVpiArgument(self: *Run, e: Ast.ExprId) Error!void {
    if (e == .none) return;
    if (deep.exhausted()) return self.deepFail(self.file.exprs.mainTok(e));
    try rememberVpiScope(self, e);
    var buf: [3]Ast.ExprId = undefined;
    for (self.file.exprs.children(e, &buf)) |arg| try rememberVpiArgument(self, arg);
}

// IEEE1364-2005 Table 5-22, §5.5.1: infer natural size/type bottom-up. Its
// recursion is bounded by the stack `deep.runGuarded` reserved (`deep.exhausted`).
pub fn infer(self: *Run, e: Ast.ExprId) Error!Type {
    if (e == .none) return self.fail(0, "omitted expressions are not implemented", .{});
    if (deep.exhausted()) return self.deepFail(self.file.exprs.mainTok(e));
    if (self.host.systf != null) try rememberVpiScope(self, e);
    const key: SpecExpr = .{ .spec = self.specOf(self.scope), .e = e };
    if (self.spec_types.get(key)) |ty| return ty;
    const ex = &self.file.exprs;
    const ty: Type = switch (ex.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .real_literal, .ident, .hier_ident => try leafType(self, e),
        // §3.9 an array element has the element's declared type; the index
        // is self-determined and never widens the result.
        .index => blk: {
            if (try self.indexedArray(e) == null) {
                // IEEE 1364-2005 §5.2.1 a bit- or part-select of a vector, or
                // §5.2.2 of an array element: unsigned, as wide as it
                // selects; the index is self-determined, a part-select's
                // bounds and an indexed one's width constant.
                const lhs = ex.lhs(e);
                if (ex.tag(lhs) != .ident and ex.tag(lhs) != .hier_ident and try self.indexedArray(lhs) == null)
                    return self.exprFail(e, "a select is of a whole vector or an unpacked array element");
                if (ex.tag(lhs) == .index) _ = try inferValue(self, lhs);
                const at = try self.baseSlot(lhs);
                if (self.reals.contains(at)) return self.exprFail(e, "§4.8: a real has no bits to select");
                if (self.isScalar(at)) return self.exprFail(e, "§5.2.1: a scalar has no bits to select");
                const rg = ex.rhs(e);
                switch (ex.tag(rg)) {
                    .range => {
                        const msb = try partBound(self, ex.lhs(rg));
                        const lsb = try partBound(self, ex.rhs(rg));
                        if (@abs(@as(i128, msb) - lsb) >= std.math.maxInt(u32)) return self.exprFail(rg, "part-select width is outside the supported u32 range");
                        // "The first expression has to address a more
                        // significant bit than the second expression."
                        const range = self.vecRange(at);
                        if (msb != lsb and (msb > lsb) != (range.msb >= range.lsb))
                            return self.exprFail(rg, "§5.2.1: a part-select names its more significant bit first");
                        try self.part_selects.put(self.arena, key, .{ .msb = msb, .lsb = lsb });
                        break :blk .{ .width = @intCast(@abs(msb - lsb) + 1), .signed = false };
                    },
                    .indexed_range => {
                        const base = try inferValue(self, ex.lhs(rg));
                        if (base.real) return self.exprFail(ex.lhs(rg), "§4.8.1: a real is not a part-select index");
                        // "the width_expr shall be a positive constant
                        // integer expression". Kept as the part-select
                        // `[width-1:0]`, which only its width is read from.
                        const width = try partBound(self, ex.rhs(rg));
                        if (width < 1 or width >= std.math.maxInt(u32)) return self.exprFail(ex.rhs(rg), "§5.2.1: an indexed part-select's width is a positive constant");
                        try self.part_selects.put(self.arena, key, .{ .msb = width - 1, .lsb = 0 });
                        break :blk .{ .width = @intCast(width), .signed = false };
                    },
                    else => { // else: any other expression is a bit-select's index
                        const index = try inferValue(self, rg);
                        if (index.real) return self.exprFail(rg, "§4.8.1: a real is not a bit-select index");
                        break :blk .{ .width = 1, .signed = false };
                    },
                }
            }
            var x = e;
            while (ex.tag(x) == .index) : (x = ex.lhs(x)) {
                // §5.2.2: "the desired word shall first be selected by
                // supplying an address for each dimension".
                if (ex.tag(ex.rhs(x)) == .range or ex.tag(ex.rhs(x)) == .indexed_range)
                    return self.exprFail(ex.rhs(x), "§5.2.2: each array dimension takes an index, not a part-select");
                // §4.8.1 refuses a real index of a vector's select; an array
                // address is refused the same way (iverilog's
                // array_index_real_fail; 1364 lists only the vector case).
                if ((try inferValue(self, ex.rhs(x))).real) return self.exprFail(ex.rhs(x), "§4.8.1: a real is not an array index");
            }
            const base = try self.slot(x);
            if (self.events.contains(base)) return self.exprFail(e, "§9.7.3: a named event holds no data; it can only be triggered and waited on");
            if (self.reals.contains(base)) break :blk real_type;
            const v = self.values[base];
            break :blk .{ .width = v.width, .signed = v.signed };
        },
        .unary => blk: {
            const operand = try inferValue(self, ex.lhs(e));
            const op = ex.unOp(e);
            // IEEE 1364-2005 §5.1.1 Table 5-2: a real takes the arithmetic,
            // relational and logical operators, and none of the bitwise ones.
            if (operand.real and op != .plus and op != .minus and op != .logical_not) return self.exprFail(e, "§5.1.1: this operator does not take a real operand");
            break :blk switch (op) {
                .plus, .minus, .bit_not => operand,
                .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => .{ .width = 1, .signed = false },
            };
        },
        .binary => blk: {
            const lhs = try inferValue(self, ex.lhs(e));
            const rhs = try inferValue(self, ex.rhs(e));
            const op = ex.binOp(e);
            if (lhs.real or rhs.real) switch (op) {
                .add, .sub, .mul, .div, .pow, .eq, .neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => {},
                .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr, .case_eq, .case_neq => return self.exprFail(e, "§5.1.1: this operator does not take a real operand"),
            };
            break :blk switch (op) {
                .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => common(lhs, rhs),
                .pow => if (rhs.real) real_type else lhs,
                .shl, .shr, .ashl, .ashr => lhs,
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => .{ .width = 1, .signed = false },
            };
        },
        .ternary => blk: {
            _ = try inferValue(self, ex.lhs(e));
            const yes = try inferValue(self, ex.rhs(e));
            const no = try inferValue(self, ex.ternaryElse(e));
            break :blk common(yes, no);
        },
        .sys_call => blk: {
            const name = self.file.str(ex.strOf(e));
            // IEEE 1364-2005 §20.4: an application's function replaces the
            // built-in of its name. A task called here keeps the built-in, for
            // the host to refuse (§20.3).
            if (self.host.systf) |u| if (u.kind(name)) |k| switch (k) {
                .func => |t| {
                    for (ex.args(e)) |arg| try rememberVpiArgument(self, arg);
                    self.sys_calls[@backingInt(e)] = .user;
                    break :blk t;
                },
                .task => {},
            };
            const f = sys_fns.get(name) orelse {
                // VAMS §9.2: a name whose "Supported in digital context"
                // cell is Yes, which this engine does not run (#58).
                if (vams_digital_unrun.get(name)) |table|
                    return self.failWith(.E0829, ex.mainTok(e), "VAMS §9.2 Table {s}: `{s}` is supported in the digital context, and VerA's digital engine does not run it", .{ table, name });
                return self.exprFail(e, "this digital expression form is not implemented");
            };
            self.sys_calls[@backingInt(e)] = f;
            const args = ex.args(e);
            switch (f) {
                // §17.7.1 gives `$time` the 64-bit `time` type and
                // `$stime` its low 32 bits. Both unsigned: simulation
                // time has no negative half.
                .time, .stime => {
                    if (args.len != 0) return self.exprFail(e, "$time and $stime take no arguments");
                    break :blk .{ .width = if (f == .time) 64 else 32, .signed = false };
                },
                // §17.11's result is an `integer`, which §3.2 makes 32-bit
                // signed: `$clog2(x) - 1` at x = 0 is -1, not 4294967295.
                .clog2 => {
                    if (args.len != 1 or args[0] == .none) return self.exprFail(e, "$clog2 takes exactly one argument");
                    // "The argument can be an integer or an arbitrary sized
                    // vector value" (§17.11.1).
                    if ((try inferValue(self, args[0])).real) return self.exprFail(args[0], "§17.11.1: $clog2 takes an integer or vector argument, not a real");
                    break :blk .{ .width = 32, .signed = true };
                },
                .make_signed, .make_unsigned => {
                    if (args.len != 1 or args[0] == .none) return self.exprFail(e, "$signed/$unsigned require exactly one integral argument");
                    const operand = try inferValue(self, args[0]);
                    if (operand.real) return self.exprFail(e, "$signed/$unsigned require exactly one integral argument");
                    break :blk .{ .width = operand.width, .signed = f == .make_signed };
                },
                // §17.6.5 `(q_id, status)`, an integer; `status` is written.
                .q_full => {
                    if (args.len != 2 or args[0] == .none or args[1] == .none) return self.exprFail(e, "$q_full takes (q_id, status)");
                    _ = try inferValue(self, args[0]);
                    try checkTarget(self, args[1]);
                    break :blk .{ .width = 32, .signed = true };
                },
                // §17.2: every file function returns an integer; the
                // descriptor of `$fopen` is 32 bits with the MSB set.
                .fopen, .fgetc, .ungetc, .fgets, .fscanf, .fread, .ftell, .fseek, .rewind, .feof, .ferror, .sscanf => {
                    const lo: usize, const hi: usize = switch (f) {
                        .fopen => .{ 1, 2 },
                        .ungetc, .fgets, .ferror => .{ 2, 2 },
                        .fseek => .{ 3, 3 },
                        .fread => .{ 2, 4 },
                        .sscanf, .fscanf => .{ 2, std.math.maxInt(usize) },
                        else => .{ 1, 1 },
                    };
                    if (args.len < lo or args.len > hi) return self.exprFail(e, "wrong number of arguments to a §17.2 file function");
                    for (args, 0..) |arg, i| {
                        // §17.2.4.4 `$fread(mem, fd, , count)` omits start.
                        if (arg == .none and f == .fread and i == 2) continue;
                        if (arg == .none) return self.exprFail(e, "wrong number of arguments to a §17.2 file function");
                        // §17.2.4.4 "the reg myreg or the memory mem".
                        if (f == .fread and i == 0 and ex.tag(arg) == .ident) if (self.arrays.get(try self.slot(arg))) |arr| {
                            if (arr.rest.len != 0) return self.exprFail(arg, "§17.2.4.4: $fread loads a one-dimensional memory");
                            continue;
                        };
                        const written = switch (f) {
                            .sscanf, .fscanf => i >= 2,
                            .fgets, .fread => i == 0,
                            .ferror => i == 1,
                            else => false, // else: every other file function only reads its arguments
                        };
                        if (written) try checkTarget(self, arg) else _ = try inferValue(self, arg);
                        // A word the file ends inside keeps the target's bits
                        // no character reached (`system.overWord`): read too.
                        if (f == .fread and i == 0) _ = try inferValue(self, arg);
                    }
                    // §17.2.1: "The type is a character string ... of one of
                    // the forms in Table 17-7".
                    if (f == .fopen and args.len == 2 and ex.tag(args[1]) == .str_literal and !system.fileType(self.file.str(ex.strOf(args[1]))))
                        return self.exprFail(args[1], "§17.2.1: an $fopen type is one of Table 17-7's r, w, a, r+, w+, a+ (with b)");
                    break :blk .{ .width = 32, .signed = f != .fopen };
                },
                .realtime, .abstime => {
                    if (args.len != 0) return self.exprFail(e, "$realtime and $abstime take no arguments");
                    break :blk real_type;
                },
                .rtoi, .itor, .realtobits, .bitstoreal => {
                    if (args.len != 1 or args[0] == .none) return self.exprFail(e, "a §17.8 conversion takes exactly one argument");
                    const operand = try inferValue(self, args[0]);
                    const wants_real = f == .rtoi or f == .realtobits;
                    // VD-130: §17.8's `$rtoi`/`$itor` prototypes are not a
                    // "shall"; an argument of the other type converts first,
                    // as iverilog does. The bit conversions stay strict.
                    if (operand.real != wants_real and (f == .realtobits or f == .bitstoreal)) return self.exprFail(e, "$rtoi and $realtobits convert a real; $itor and $bitstoreal an integral value");
                    break :blk switch (f) {
                        .rtoi => .{ .width = 32, .signed = true },
                        .realtobits => .{ .width = 64, .signed = false },
                        else => real_type,
                    };
                },
                // §17.10: `(string)` and `(format, variable)`, returning
                // an integer. The variable is written only on a match,
                // so it is checked as a target and never read.
                .test_plusargs, .value_plusargs => {
                    const want: usize = if (f == .test_plusargs) 1 else 2;
                    if (args.len != want or args[0] == .none) return self.exprFail(e, "$test$plusargs takes (string) and $value$plusargs (format, variable)");
                    // §17.10.1: "either a string or a nonreal variable".
                    if ((try inferValue(self, args[0])).real) return self.exprFail(args[0], "§17.10: the plusarg string is a string or a nonreal variable");
                    if (f == .value_plusargs and ex.tag(args[0]) == .str_literal) try plusargFormat(self, args[0]);
                    if (f == .value_plusargs) {
                        if (args[1] == .none) return self.exprFail(e, "$value$plusargs needs a variable to write");
                        try checkTarget(self, args[1]);
                    }
                    break :blk .{ .width = 32, .signed = true };
                },
                .driver_count, .receiver_count, .driver_state, .driver_strength, .driver_delay, .driver_next_state, .driver_next_strength, .driver_type => break :blk try driver.infer(self, e, driver.of(f).?),
                // §17.9: `$random [ ( seed ) ]` and `$dist_*( seed, ... )`,
                // every argument an integer and the result a signed
                // 32-bit integer (§17.9.1).
                .random, .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => {
                    const want: usize = switch (f) {
                        .random => @min(args.len, 1),
                        .dist_uniform, .dist_normal, .dist_erlang => 3,
                        else => 2, // else: the one-parameter distributions
                    };
                    if (args.len != want) return self.exprFail(e, "wrong number of arguments to a §17.9 distribution function");
                    for (args, 0..) |arg, i| {
                        if (arg == .none) return self.exprFail(e, "wrong number of arguments to a §17.9 distribution function");
                        const t = try inferValue(self, arg);
                        if (i == 0) {
                            // §17.9.1: "The seed argument shall be either a
                            // reg, an integer, or a time variable."
                            if (ex.tag(arg) != .ident or t.real) return self.exprFail(arg, "§17.9.1: the seed argument shall be a reg, integer or time variable");
                            try checkTarget(self, arg);
                        } else if (t.real) return self.exprFail(arg, "§17.9.2: the arguments of a $dist_ function are integer values");
                    }
                    break :blk .{ .width = 32, .signed = true };
                },
                // §17.11.2: every argument is read as a real and the
                // result is real.
                else => {
                    if (args.len != f.mathArity().?) return self.exprFail(e, "wrong number of arguments to a §17.11.2 math function");
                    for (args) |arg| {
                        if (arg == .none) return self.exprFail(e, "wrong number of arguments to a §17.11.2 math function");
                        _ = try inferValue(self, arg);
                    }
                    break :blk real_type;
                }, // else: Table 17-17's math functions, mathArity's rows
            }
        },
        // §10.4 a function call: the function's result variable is its type,
        // so the call site's context never reaches inside it.
        .call => blk: {
            const inst = self.instanceOf(self.scope);
            // §12.5: `block.f(0)` names a function by a hierarchical name,
            // resolved as a task enable's is (A.8.2 hierarchical_function_identifier).
            const idx = (if (std.mem.findScalar(u8, self.file.str(ex.strOf(e)), '.') == null)
                subIn(self, self.scope, ex.strOf(e))
            else
                try enabledTask(self, self.scope, ex.strOf(e), ex.mainTok(e), false)) orelse return self.exprFail(e, "undeclared function");
            // A call site records an index relative to its own instance's
            // subroutines (`Run.sub_base`).
            // ponytail: a function of another instance is refused; an
            // absolute index in `call_subs` is the upgrade.
            if (self.instanceOf(self.routines.rows.items[idx].inst) != inst) return self.exprFail(e, "§12.5: a hierarchical call of a function in another module instance is not implemented by digital execution");
            if (!self.routines.rows.items[idx].decl.is_function) return self.exprFail(e, "§10.2: a task is enabled as a statement, not called in an expression");
            if (!self.routines.rows.items[idx].framed) try elab.earlyFrame(self, idx, ex.mainTok(e));
            const sub = self.routines.rows.items[idx];
            try checkArgs(self, sub.decl, ex.args(e), ex.mainTok(e));
            try self.routines.calls.put(self.arena, e, idx - self.routines.base.get(inst).?);
            if (self.reals.contains(sub.frame.result)) break :blk real_type;
            const result = self.values[sub.frame.result];
            break :blk .{ .width = result.width, .signed = result.signed };
        },
        .concat => blk: {
            var width: u32 = 0;
            for (ex.args(e)) |arg| {
                const operand = try infer(self, arg);
                if (operand.real) return self.exprFail(arg, "§5.1.1: a real cannot be a concatenation operand");
                if (unsizedConcatOperand(self, arg)) {
                    if (ex.tag(arg) == .int_literal or ex.tag(arg) == .logic_literal)
                        return self.exprFail(arg, "unsized constant numbers are not allowed as concatenation operands");
                    return self.exprFail(arg, "concatenation operands with unsized arithmetic are not implemented");
                }
                width = std.math.add(u32, width, operand.width) catch return self.exprFail(e, "concatenation width exceeds the supported u32 range");
            }
            if (width == 0) return self.exprFail(e, "a concatenation requires a positive-width operand; zero-only and empty concatenations are invalid");
            break :blk .{ .width = width, .signed = false };
        },
        .multi_concat => blk: {
            _ = try inferValue(self, ex.lhs(e));
            const operand = try inferValue(self, ex.rhs(e));
            const count = try replicationCount(self, ex.lhs(e));
            const width = std.math.mul(u32, count, operand.width) catch return self.exprFail(e, "replication width exceeds the supported u32 range");
            try self.replications.put(self.arena, key, count);
            break :blk .{ .width = width, .signed = false };
        },
        // VAMS §7.3.3 / §7.3.6.3 a potential probe of a continuous net, read
        // from the analog solution through the mixed-signal kernel's hook.
        .branch_access => blk: {
            if (!self.analog.mixed or !std.mem.eql(u8, self.file.str(ex.strOf(e)), "V") or !probeTerminal(ex, ex.lhs(e)) or
                (ex.rhs(e) != .none and !probeTerminal(ex, ex.rhs(e))))
                return self.exprFail(e, "only a V(net), V(net, net) or V(branch) probe of the analog solution is implemented in a digital expression");
            self.analog.has_probes = true;
            break :blk real_type;
        },
        else => return self.exprFail(e, "this digital expression form is not implemented"), // else: the analog-only forms (access functions, filters, patterns, events), refused out loud
    };
    try self.spec_types.put(self.arena, key, ty);
    const i = @backingInt(e);
    switch (self.ty_state[i]) {
        .untyped => {
            self.types[i] = ty;
            self.ty_state[i] = .one;
        },
        .one => if (!std.meta.eql(self.types[i], ty)) {
            self.ty_state[i] = .many;
        },
        .many => {},
    }
    return ty;
}

// ---- private ----

fn leafType(self: *Run, e: Ast.ExprId) Error!Type {
    assert(e != .none);
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .ident, .hier_ident => blk: {
            const at = try self.scalarSlot(e);
            // §5.10: events "do not hold any data", so a named event has no
            // value an expression could read.
            if (self.events.contains(at)) return self.exprFail(e, "§5.10: a named event holds no data; it can only be triggered and waited on");
            // IEEE 1364-2005 §4.10.3: "A specify parameter declared outside a
            // specify block shall be declared before it is referenced."
            if (self.specparams.get(at)) |decl| if (ex.tag(e) == .ident and ex.mainTok(e) < decl)
                return self.exprFail(e, "§4.10.3: a specify parameter is declared before it is referenced");
            if (self.reals.contains(at)) break :blk real_type;
            const v = self.values[at];
            const own = if (ex.tag(e) == .ident) self.port_signed.get(.{ .scope = self.scope, .str = ex.strOf(e) }) else null;
            break :blk .{ .width = v.width, .signed = own orelse v.signed };
        },
        .int_literal => blk: {
            const n = ex.intLiteral(e);
            break :blk .{ .width = literalWidth(n), .signed = n.signed };
        },
        // An unsized based constant is an integer-sized operand (Table
        // 5-22) whose x/z fill is decided in context (`evaluate.unsizedFill`).
        // VD-131: past 32 bits it is as wide as its digits.
        .logic_literal => blk: {
            const n = ex.logicValue(e);
            // ponytail: one with an x/z digit and 33 to 64 digit bits
            // ('h0000000000x) reads as 32: the frontend holds it in 64 and
            // keeps no digit count for it. Keep one if such a literal shows up.
            const wide = !n.hasUnknown() or n.width > 64;
            break :blk .{ .width = if (n.sized) n.width else if (wide) @max(32, n.width) else 32, .signed = n.signed };
        },
        // IEEE 1364-2005 §3.6: a string operand is an unsigned number of
        // eight bits per character, and §5.2.3.3's "" is one NUL byte.
        .str_literal => .{ .width = stringWidth(self.file.str(ex.strOf(e))), .signed = false },
        .real_literal => real_type,
        else => self.exprFail(e, "this expression requires digital context typing beyond the implemented leaf operands"), // else: infer calls this for the leaves above only
    };
}

/// IEEE 1364-2005 §26.6.19(e): an application's argument may be read after
/// its calltf returns. Remember its lexical context without evaluating or
/// requiring a value from scope/array/event arguments.
fn rememberVpiScope(self: *Run, e: Ast.ExprId) Error!void {
    assert(e != .none);
    try self.hier.vpi_expr_scopes.put(self.arena, .{ self.instanceOf(self.scope), @backingInt(e) }, self.scope);
}

fn inferValue(self: *Run, e: Ast.ExprId) Error!Type {
    assert(e != .none);
    const ty = try infer(self, e);
    if (ty.width == 0) return self.exprFail(e, "zero replication requires an immediately enclosing concatenation with a positive-width operand");
    return ty;
}

fn replicationCount(self: *Run, e: Ast.ExprId) Error!u32 {
    assert(e != .none);
    if (!constantExpression(self, e)) return self.exprFail(e, "integral replication requires a constant expression");
    var scratch = std.heap.ArenaAllocator.init(self.arena);
    defer scratch.deinit();
    const value = try evaluate.eval(self, scratch.allocator(), e, 0);
    if (value.hasUnknown()) return self.exprFail(e, "replication count cannot contain X or Z");
    if (value.signed and value.bit(value.width - 1) == .one) return self.exprFail(e, "replication count cannot be negative");
    for (value.values()[1..]) |word| if (word != 0) return self.exprFail(e, "replication count exceeds the supported u32 range");
    if (value.values()[0] > std.math.maxInt(u32)) return self.exprFail(e, "replication count exceeds the supported u32 range");
    return @intCast(value.values()[0]);
}

/// A part-select bound or an indexed part-select's width: §5.2.1's constant
/// integer expression, which §4.8.1 keeps a real out of.
fn partBound(self: *Run, e: Ast.ExprId) Error!i64 {
    assert(e != .none);
    const v = try self.constant(e, self.file.exprs.mainTok(e));
    if (typeOf(self, e).real) return self.exprFail(e, "§4.8.1: a real is not a part-select bound");
    if (v.hasUnknown()) return self.exprFail(e, "a part-select bound cannot contain x or z");
    return evaluate.indexInt(v) orelse self.exprFail(e, "a part-select bound is outside the supported i64 range");
}

/// §17.10.2: a literal user_string's conversions are "the only valid ones",
/// `%d %o %h %b %e %f %g %s` in either case, with a leading 0 allowed.
fn plusargFormat(self: *Run, e: Ast.ExprId) Error!void {
    assert(e != .none);
    const text = self.file.str(self.file.exprs.strOf(e));
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, text, i, '%')) |at| {
        i = at + 1;
        while (i < text.len and text[i] == '0') i += 1;
        if (i == text.len or std.mem.findScalar(u8, "dohbefgsDOHBEFGS", text[i]) == null)
            return self.fail(self.file.exprs.mainTok(e), "§17.10.2: a $value$plusargs format is one of %d %o %h %b %e %f %g %s, not `%{s}`", .{text[@min(i, text.len)..@min(i + 1, text.len)]});
        i += 1;
    }
}
