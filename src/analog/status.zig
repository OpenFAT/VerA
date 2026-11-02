//! §9.7.3 `$fatal`/`$error` as a device status: a call in, a
//! `Lowered.status_sites` row and the status channel's code and argument
//! places out, the first site an evaluation reaches winning.
//!
//! Cites: §9.7.3.
//!
//! Contents:
//! - `pub fn badFinishNumber(self: *Lower, args: []const Ast.ExprId) Oom!bool`
//! - `pub fn lowerStatus(self: *Lower, tok: u32, fatal: bool, args: []const Ast.ExprId) Oom!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const Ssa = @import("ssa.zig");
const lower_sysfunc_args = @import("sysfunc_args.zig");
const Oom = Lower.Oom;
const Lowered = Lower.Lowered;

/// The last 0-based site `siteCode` packs: `site + 1` fills the low 24 bits.
const site_max = 0xff_ffff - 1;

/// §9.7.3 Syntax 9-7 `finish_number ::= 0 | 1 | 2`: reports E0824 and returns
/// true when `$fatal`'s first argument is a number that is not one of the
/// three. A string first argument is a message with the number omitted
/// (`cg_display.emitDisplayTask` keeps its text), not a finish_number.
pub fn badFinishNumber(self: *Lower, args: []const Ast.ExprId) Oom!bool {
    assert(self.blockValid(self.cur));
    if (args.len == 0 or args[0] == .none) return false;
    const cv = try lower_constfold.constEval(self, args[0]);
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
    assert(self.blockValid(self.cur));
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0);
    const site = self.out.status_sites.items.len;
    const code = siteCode(fatal, site) orelse
        return self.err(tok, .E1022, "this is site {d}, and a device's status code holds {d}", .{ site + 1, site_max + 1 });
    // §9.7.3 `$fatal(finish_number, "…", …)`: the format is the first
    // argument that is a string literal, as `checkFormatPairing` reads it.
    var fmt: []const u8 = "";
    var first = args.len;
    for (args, 0..) |a, i| {
        if (a == .none) continue;
        const text = try lower_sysfunc_args.outputLiteral(self, a) orelse
            if (try lower_constfold.constEval(self, a)) |cv| switch (cv) {
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

// ---- private ----

/// The status code site `site` (0-based) latches, packed as
/// `contract.statusCode` packs it: 1 (fatal) or 2 (error) in the top byte,
/// `site + 1` below. Null past `site_max`, where it would spill into the
/// severity byte; the source decides how many sites there are.
fn siteCode(fatal: bool, site: usize) ?f64 {
    if (site > site_max) return null;
    const code = (@as(u32, if (fatal) 1 else 2) << 24) | @as(u32, @intCast(site + 1));
    assert(code & 0xff_ffff != 0); // 0 is "nothing latched"
    return @floatFromInt(code);
}

test "siteCode packs the severity over site + 1, and refuses the site that would spill (§9.7.3)" {
    // Oracle: `contract.statusSite`'s decode, written out: the top byte is the
    // severity, the low 24 bits less one the site.
    for ([_]usize{ 0, 1, 1000, site_max }) |site| for ([_]bool{ true, false }) |fatal| {
        const code: u32 = @intFromFloat(siteCode(fatal, site).?);
        try std.testing.expectEqual(@as(u32, if (fatal) 1 else 2), code >> 24);
        try std.testing.expectEqual(site, (code & 0xff_ffff) - 1);
    };
    try std.testing.expectEqual(@as(?f64, null), siteCode(true, site_max + 1));
    try std.testing.expectEqual(@as(?f64, null), siteCode(false, 1 << 24));
}
