const std = @import("std");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lexer = @import("frontend").Lexer;
const fopen_types = @import("kernels").fopen_types;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_math = @import("math.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;

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
    const math = c == .@"$log10" or lower_math.unaryMathOp(name[1..]) != null or
        lower_math.binaryMathOp(name[1..]) != null;
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
pub fn checkFopenType(self: *Lower, args: []const Ast.ExprId) Oom!bool {
    if (args.len != 2 or args[1] == .none) return false;
    const s = constStrArg(self, args[1]) orelse return false;
    if (fopen_types.has(s)) return false;
    try self.err(self.file.exprs.mainTok(args[1]), .E0889, "`\"{s}\"`", .{s});
    return true;
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
pub fn takesNetRef(name: []const u8) bool {
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
