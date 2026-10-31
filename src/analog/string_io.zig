//! §9.5 string and file I/O that writes through an argument: `$swrite`,
//! `$sformat`, `$sscanf`, `$fgets`, `$fscanf`, `$ferror` and §9.12's
//! `$value$plusargs` in, the count call plus one assignment per destination
//! out, every file call sequenced into the per-point I/O phase.
//!
//! Cites: §4.2.1.1, §5.10, §9.4.3, §9.5, §9.5.3, §9.5.4.1, §9.5.4.2, §9.5.7,
//! §9.5.9, §9.7.3, §9.12, §17.10.2; IEEE 1364-2005 §17.10.2.
//!
//! Contents:
//! - `pub fn lowerStringWrite(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!void`
//! - `pub fn lowerScan(self: *Lower, tok: u32, args: []const Ast.ExprId) Oom!Mir.Value`
//! - `pub fn lowerValuePlusargs(self: *Lower, args: []const Ast.ExprId) Oom!Mir.Value`
//! - `pub fn sequenceFileCall(self: *Lower, tok: u32, name: []const u8, v: Mir.Value) Oom!void`
//! - `pub fn lowerFileRead(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!?Mir.Value`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_lvalue = @import("lvalue.zig");
const lower_display = @import("display.zig");
const lower_format = @import("format.zig");
const lower_sysfunc_args = @import("sysfunc_args.zig");
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const Lowered = Lower.Lowered;

/// §9.5.3 `$swrite(str, …)` / `$sformat(str, fmt, …)` — the §9.4.3 formatter
/// with a string variable where the transcript would be: "the first argument to
/// $swrite shall be a string variable to which the resulting string shall be
/// written, instead of a variable specifying the file to which to write".
///
/// Lowered as an assignment, not a void call, because the write is the task: a
/// call whose result nothing reads is dead code once codegen slices a unit out
/// of the MIR. `cg_display` renders it like a `$display`.
pub fn lowerStringWrite(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!void {
    assert(self.blockValid(self.cur));
    assert(name.len != 0);
    if (args.len == 0 or args[0] == .none) {
        try self.err(tok, .E0813, "`{s}` needs a string variable to write into", .{name});
        return;
    }
    const slot = try lower_lvalue.resolveLvalue(self, args[0]) orelse return;
    if (slot.ty != .string) {
        try self.err(self.file.exprs.mainTok(args[0]), .E0813, "`{s}` writes into a `string` variable, and this one is {s}", .{ name, @tagName(slot.ty) });
        return;
    }
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    // §9.5.3: "$sformat always interprets its second argument, and only its
    // second argument, as a format string. This format argument can be a
    // static string ... or can be a string variable whose content is
    // interpreted as the format string." A literal is translated at compile
    // time; anything else is formatted at run time (`$sformat$rt`).
    if (std.mem.eql(u8, name, "$sformat") and args.len > 1 and args[1] != .none and
        try lower_sysfunc_args.outputLiteral(self, args[1]) == null and
        (if (lower_constfold.constEval(self, args[1])) |cv| cv != .str else true))
    {
        const f = try lower_expr.lowerExpr(self, args[1]);
        if (f.ty != .string) {
            try self.err(self.file.exprs.mainTok(args[1]), .E0813, "`$sformat`'s format_string is a string, and this one is {s}", .{@tagName(f.ty)});
            return;
        }
        try vals.append(self.arena, f.v);
        for (args[2..]) |a|
            try vals.append(self.arena, (if (a == .none) try lower_display.nullArg(self) else try lower_sysfunc_args.lowerFormatArg(self, a)).v);
        self.out.uses.insert(.str_tasks);
        return lower_lvalue.writeLvalue(self, slot, try self.call("$sformat$rt", vals.items));
    }
    var live: std.ArrayList(Ast.ExprId) = .empty;
    defer live.deinit(self.arena);
    var tys: std.ArrayList(Ty) = .empty;
    defer tys.deinit(self.arena);
    // Types are preserved, not coerced: the conversion `cg_display.appendConv`
    // picks depends on the operand's own type (§9.4.3 `%d` on a real is a
    // §4.2.1.1 conversion, `%s` on a string is the text).
    for (args[1..]) |a| {
        const tv = if (a == .none) try lower_display.nullArg(self) else try lower_sysfunc_args.lowerFormatArg(self, a);
        try vals.append(self.arena, tv.v);
        try live.append(self.arena, a);
        try tys.append(self.arena, tv.ty);
    }
    try lower_format.checkFormatPairing(self, tok, args[1..]);
    try lower_format.prepareFormatArgs(self, tok, live.items, tys.items, vals.items, 0);
    self.out.uses.insert(.str_tasks);
    const v = try self.call("$sformat", vals.items);
    try lower_lvalue.writeLvalue(self, slot, v);
}

/// §9.5.4.2 `code = $sscanf( str, format, args )`. One source call becomes one
/// `$sscanf` (the count) plus one `$sscanf$<ty>` assignment per output argument,
/// each naming the item it wants by index among the ASSIGNED items — so a `%*d`
/// suppressed field shifts nothing, because it is not assigned.
///
/// An out-parameter has no spelling in an SSA expression tree, and the scan is a
/// pure function of the two strings, so N+1 evaluations compute what one call
/// with N writes would. `str_scan.zig` says the same from the runtime side.
///
/// Returns the count value; a statement-position call drops it.
pub fn lowerScan(self: *Lower, tok: u32, args: []const Ast.ExprId) Oom!Mir.Value {
    assert(self.blockValid(self.cur));
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0);
    if (args.len < 2 or args[0] == .none or args[1] == .none) {
        try self.err(tok, .E0813, "$sscanf needs a string to read and a format string", .{});
        return self.mir.addIntConst(self.arena, 0);
    }
    const src_tv = try lower_expr.lowerExpr(self, args[0]);
    // §9.5.4.2: "$sscanf reads from the string str (which shall be a string
    // variable, string parameter, or string literal)". A number has no
    // characters to scan.
    if (src_tv.ty != .string) {
        try self.err(self.file.exprs.mainTok(args[0]), .E0813, "`$sscanf` reads from a string variable, string parameter or string literal, and this one is {s}", .{@tagName(src_tv.ty)});
        return self.mir.addIntConst(self.arena, 0);
    }
    const src = src_tv.v;
    const fmt = (try lower_expr.lowerExpr(self, args[1])).v;
    // Only a literal format can be checked, and only a literal one is worth
    // checking: a conversion code the scanner does not implement would consume
    // nothing and still be counted, so the model would read a plausible number.
    if (lower_constfold.constEval(self, args[1])) |c| switch (c) {
        .str => |s| if (try checkScanFormat(self, tok, s)) return self.mir.addIntConst(self.arena, 0),
        else => {},
    };
    self.out.uses.insert(.str_tasks);
    // Snapshot the count from the original input/format before any destination
    // assignment, including destinations aliasing either string argument.
    const count = try self.call("$sscanf", &.{ src, fmt });
    var item: i64 = 0;
    for (args[2..]) |a| {
        if (a == .none) continue;
        const slot = try lower_lvalue.resolveLvalue(self, a) orelse continue;
        const index = try self.mir.addIntConst(self.arena, item);
        const v = try self.call(sscanfCallee(slot.ty), &.{ src, fmt, index });
        // Read the current SSA value per assignment: if a destination occurs
        // twice, a failed later conversion retains the earlier successful one.
        const old = try lower_lvalue.readLvalue(self, slot);
        const assigned = try self.emit(.igt, &.{ count, index });
        try lower_lvalue.writeLvalue(self, slot, try self.emit(.select, &.{ assigned, v, old }));
        item += 1;
    }
    return count;
}

/// §9.12 / IEEE 1364 §17.10.2 `found = $value$plusargs(user_string, variable)`:
/// "If no string is found matching, the function returns the integer value
/// zero, and the variable provided is not modified" — so, as in `lowerScan`,
/// the write is a `select` on the result over the variable's incoming value.
/// The value is `$sscanf` of the matched plusarg against the whole user_string
/// (the device's `zPlusarg` says why that is the clause's conversion).
/// Asserts that `args` is the user string and the variable, both written.
pub fn lowerValuePlusargs(self: *Lower, args: []const Ast.ExprId) Oom!Mir.Value {
    assert(self.blockValid(self.cur));
    assert(args.len == 2);
    assert(args[0] != .none);
    assert(args[1] != .none);
    const user = (try lower_expr.lowerExpr(self, args[0])).v;
    const found = try self.call("$value$plusargs", &.{user});
    const slot = try lower_lvalue.resolveLvalue(self, args[1]) orelse return found;
    self.out.uses.insert(.str_tasks);
    const zero = try self.mir.addIntConst(self.arena, 0);
    const v = try self.call(sscanfCallee(slot.ty), &.{ try self.call("$plusarg$str", &.{user}), user, zero });
    const old = try lower_lvalue.readLvalue(self, slot);
    const hit = try self.emit(.igt, &.{ found, zero });
    try lower_lvalue.writeLvalue(self, slot, try self.emit(.select, &.{ hit, v, old }));
    return found;
}

/// Sequences one §9.5 file-family call into the per-point I/O phase.
///
/// Every §9.5 call has a side effect on a descriptor, and §9.5.9 puts those at
/// the accepted point ("the file write operations shall not be performed unless
/// the iteration is accepted"). The display chain is that phase: codegen keeps
/// it out of the shared core so its side effects cannot run per Newton
/// iteration. So a file call joins the chain whether or not its value is read
/// (a discarded `$fgets` count still moves what `$ftell` measures).
///
/// The chain carries reals (`fadd`) and every §9.5 function is integer-valued,
/// so the carrier is `$itor`.
pub fn sequenceFileCall(self: *Lower, tok: u32, name: []const u8, v: Mir.Value) Oom!void {
    assert(self.valueValid(v));
    assert(self.blockValid(self.cur));
    assert(name.len != 0);
    self.out.uses.insert(.file_tasks);
    const carrier = try self.call("$itor", &.{v});
    const cond = self.cond_depth != 0;
    if (cond) try lower_display.chainCondDisplay(self, carrier);
    try self.out.displays.append(self.arena, .{
        .val = carrier,
        .name = name,
        .tok = tok,
        .conditional = cond,
        .analog_initial = self.in_analog_initial,
    });
}

/// §9.5.4.1 `code = $fgets( str, fd )`, §9.5.4.2 `code = $fscanf( fd, format,
/// args )` and §9.7.3-adjacent §9.5.7 `errno = $ferror( fd, str )` — the three
/// §9.5 calls that write through an argument as well as returning a value.
///
/// Same rewrite as `lowerScan`: an out-parameter has no spelling in an SSA
/// expression tree. One source call becomes the count (or errno) plus one
/// reader per destination, each taking the count as its first operand, which
/// sequences the pair and carries the "nothing was assigned" rule into the
/// reader. Returns null when `name` is not one of the three.
pub fn lowerFileRead(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!?Mir.Value {
    assert(self.blockValid(self.cur));
    assert(name.len != 0);
    const eq = std.mem.eql;
    const gets = eq(u8, name, "$fgets");
    const scan = eq(u8, name, "$fscanf");
    const ferr = eq(u8, name, "$ferror");
    if (!gets and !scan and !ferr) return null;
    self.out.uses.insert(.file_tasks);
    // §9.5.4.2's conversions are §9.5.3's conversions, so the scanner is the
    // string one and the string kernels have to be there.
    if (scan) self.out.uses.insert(.str_tasks);

    // Syntax 9-6/9-7/9-9: `$fgets` takes the destination first, `$ferror`
    // second; `$fscanf` takes the descriptor, the format, then the destinations.
    const fd_at: usize = if (gets) 1 else 0;
    if (args.len <= fd_at or args[fd_at] == .none) {
        try self.err(tok, .E0813, "`{s}` needs a file descriptor", .{name});
        return try self.mir.addIntConst(self.arena, 0);
    }
    const fd_tv = try lower_sysfunc_args.lowerSysArg(self, args[fd_at], false); // a descriptor, never a net
    if (try lower_sysfunc_args.checkDescriptor(self, name, fd_at, args[fd_at], fd_tv)) return try self.mir.addIntConst(self.arena, 0);
    const fd = fd_tv.v;
    // §9.5.4.2 alone has a control string, and it is an operand of every reader
    // as well as of the count.
    const fmt: ?Mir.Value = if (scan) blk: {
        if (args.len < 2 or args[1] == .none) {
            try self.err(tok, .E0813, "`$fscanf` needs a format string", .{});
            break :blk null;
        }
        // Only a literal format can be checked — `lowerScan`'s reasoning, and
        // its diagnostic, apply verbatim to the file source of the same scan.
        if (lower_constfold.constEval(self, args[1])) |c| switch (c) {
            .str => |s| if (try checkScanFormat(self, tok, s)) break :blk null,
            else => {},
        };
        break :blk (try lower_expr.lowerExpr(self, args[1])).v;
    } else null;
    if (scan and fmt == null) return try self.mir.addIntConst(self.arena, 0);

    const n = if (gets)
        try self.call("$fgets", &.{fd})
    else if (ferr)
        try self.call("$ferror", &.{fd})
    else
        try self.call("$fscanf", &.{ fd, fmt.? });
    try sequenceFileCall(self, tok, name, n);

    const dests = if (gets) args[0..1] else if (ferr) args[1..] else args[2..];
    var item: i64 = 0;
    for (dests) |a| {
        if (a == .none) continue;
        const slot = try lower_lvalue.resolveLvalue(self, a) orelse continue;
        // §9.5.4.1/§9.5.7 write a string; only §9.5.4.2 has typed items, and
        // there the destination's declared type picks the callee as in
        // `lowerScan`: the name is the type, so `sysFuncTy` and
        // `callee.ty` cannot disagree.
        if (gets or ferr) {
            if (slot.ty != .string) {
                try self.err(self.file.exprs.mainTok(a), .E0813, "`{s}` writes into a `string` variable, and this one is {s}", .{ name, @tagName(slot.ty) });
                continue;
            }
            const v = try self.call(if (gets) "$fgets$str" else "$ferror$str", &.{ n, fd });
            try lower_lvalue.writeLvalue(self, slot, v);
            continue;
        }
        const callee: []const u8 = switch (slot.ty) {
            .integer => "$fscanf$int",
            .string => "$fscanf$str",
            .real => "$fscanf$real",
            .wide => unreachable, // `resolveLvalue` types a wide `reg` `.integer` (`Lvalue.at.wide`)
        };
        const index = try self.mir.addIntConst(self.arena, item);
        const v = try self.call(callee, &.{ n, fd, fmt.?, index });
        // Only successful assignments change destinations. Reuse the count
        // from the sequenced file read; never consume another input window.
        const old = try lower_lvalue.readLvalue(self, slot);
        const assigned = try self.emit(.igt, &.{ n, index });
        try lower_lvalue.writeLvalue(self, slot, try self.emit(.select, &.{ assigned, v, old }));
        item += 1;
    }
    return n;
}

// ---- private ----

/// The `$sscanf` reader for a destination of type `ty`. The destination's
/// declared type picks the callee, exactly as §5.10's `holdSlot` does: the
/// name IS the type, so `callee.ty` and `sysFuncTy` cannot disagree about it.
fn sscanfCallee(ty: Ty) []const u8 {
    assert(ty != .wide); // `resolveLvalue` types a wide `reg` `.integer`
    return switch (ty) {
        .integer => "$sscanf$int",
        .string => "$sscanf$str",
        .real => "$sscanf$real",
        .wide => unreachable, // `resolveLvalue` types a wide `reg` `.integer` (`Lvalue.at.wide`)
    };
}

/// §9.5.4.2's conversion codes, and nothing else. True when the format was
/// refused. The suppression `*` and the maximum field width are part of the
/// specification and are read past here; `str_scan.zScan` implements them.
///
/// Case-sensitive, unlike §9.4.3's display table: §9.5.4.2 spells each scan
/// code once, in lower case, and leaves an invalid one implementation
/// dependent. `zScan` compares the raw byte, so `%D` would silently match
/// nothing; refusing it is the useful implementation-dependent result.
fn checkScanFormat(self: *Lower, tok: u32, fmt: []const u8) Oom!bool {
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0);
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, fmt, i, '%')) |p| {
        i = p + 1;
        if (i >= fmt.len) break;
        if (fmt[i] == '%') { // a literal percent, matched not converted
            i += 1;
            continue;
        }
        if (fmt[i] == '*') i += 1;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
        if (i >= fmt.len) break;
        const conv = fmt[i];
        i += 1;
        // §9.5.4.2's code table has SIX rows, and `r` and `m` are two of them:
        // "r Matches a 'real' number in engineering notation, using the scale
        // factors defined in 2.6.2" and "m Returns the current hierarchical
        // path as a string. Does not read data from the input file or str
        // argument".
        if (std.mem.findScalar(u8, "dohxbcfegsrm", conv) != null) continue;
        assert(i <= fmt.len);
        var b = self.errWith(tok, .E0813);
        b.msg("$sscanf does not support the conversion `%{c}`", .{conv});
        b.note("§9.5.4.2's codes are %d %o %h %x %b %c %f %e %g %s %r %m", .{});
        try b.emit();
        return true;
    }
    return false;
}
