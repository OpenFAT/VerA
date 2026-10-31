const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const Ssa = @import("ssa.zig");
const lower_sysfunc_args = @import("sysfunc_args.zig");
const Oom = Lower.Oom;
const Lowered = Lower.Lowered;

/// §9.7.3 Syntax 9-7 `finish_number ::= 0 | 1 | 2`: reports E0824 and returns
/// true when `$fatal`'s first argument is a number that is not one of the
/// three. A string first argument is a message with the number omitted
/// (`cg_display.emitDisplayTask` keeps its text), not a finish_number.
pub fn badFinishNumber(self: *Lower, args: []const Ast.ExprId) Oom!bool {
    if (args.len == 0 or args[0] == .none) return false;
    const cv = lower_constfold.constEval(self, args[0]);
    if (cv) |v| switch (v) {
        .str => return false,
        .int => |n| if (n >= 0 and n <= 2) return false,
        .real => |x| if (x == 0 or x == 1 or x == 2) return false,
    };
    if (cv == null and try lower_sysfunc_args.outputLiteral(self, args[0]) != null) return false;
    try self.err(self.file.exprs.mainTok(args[0]), .E0824, "`$fatal`'s finish_number shall be 0, 1 or 2", .{});
    return true;
}

/// §9.7.3 `$fatal`/`$error` as a STATUS for a device, which cannot print or
/// stop its host (`Lowered.status`). Records the site, then makes the site the
/// evaluation's status unless an earlier one already is: the code place
/// keeps its value when nonzero, and each argument place moves only with it.
/// Runs at the statement, under its guards, so a call on an arm that did not
/// run reports nothing. The printing artifact ignores the result.
pub fn lowerStatus(self: *Lower, tok: u32, fatal: bool, args: []const Ast.ExprId) Oom!void {
    const site: u32 = @intCast(self.out.status_sites.items.len);
    // §9.7.3 `$fatal(finish_number, "…", …)`: the format is the first
    // argument that is a string literal, as `checkFormatPairing` reads it.
    var fmt: []const u8 = "";
    var first = args.len;
    for (args, 0..) |a, i| {
        if (a == .none) continue;
        const text = try lower_sysfunc_args.outputLiteral(self, a) orelse
            if (lower_constfold.constEval(self, a)) |cv| switch (cv) {
                .str => |s| s,
                else => null,
            } else null;
        if (text) |t| {
            fmt = t;
            first = i + 1;
            break;
        }
    }
    try self.out.status_sites.append(self.arena, .{ .fatal = fatal, .fmt = fmt, .tok = tok });

    const ps = self.systask_state.status_places orelse blk: {
        var ps: [1 + Lowered.status_arg_max]Ssa.Place = undefined;
        for (&ps) |*p| {
            p.* = self.builder.newPlace();
            try self.builder.writeVariable(p.*, .entry, .f_zero);
        }
        self.systask_state.status_places = ps;
        break :blk ps;
    };
    const cur = try self.builder.readVariable(ps[0], self.cur);
    const first_here = try self.emit(.feq, &.{ cur, .f_zero });
    const code: f64 = @floatFromInt((@as(u32, if (fatal) 1 else 2) << 24) | (site + 1));
    try self.builder.writeVariable(ps[0], self.cur, try self.emit(.select, &.{ first_here, try self.mir.addFloatConst(self.arena, code), cur }));
    var k: usize = 0;
    for (args[@min(first, args.len)..]) |a| {
        if (a == .none) continue;
        if (k == Lowered.status_arg_max) break;
        const tv = try lower_sysfunc_args.lowerTaskArg(self, a, if (fatal) "$fatal" else "$error");
        // A string argument has no numeric slot; `contract.formatStatus`
        // prints `%s` as `?`.
        const v = if (tv.ty == .string) Mir.Value.f_zero else try self.toReal(tv);
        const old = try self.builder.readVariable(ps[1 + k], self.cur);
        try self.builder.writeVariable(ps[1 + k], self.cur, try self.emit(.select, &.{ first_here, v, old }));
        k += 1;
    }
}
