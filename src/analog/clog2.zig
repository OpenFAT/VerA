//! §9.14 `$clog2`: an integral argument in, a `$clog2(value, width)` call
//! out, the operand lowered at its IEEE 1364-2005 self-determined width and,
//! for a parameter a model card may size, again at 32 and 64 bits (VD-089).
//!
//! Cites: §9.14, §17.11.1; IEEE 1364-2005 §17.11.1.
//!
//! Contents:
//! - `pub fn lowerClog2(self: *Lower, tok: u32, arg: Ast.ExprId) Oom!TypedValue`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;

/// `lowerClog2`'s card facts over the `hostSizedParam`s an operand reads:
/// whether the card set any of them, and whether every value fits 32 bits.
const HostSized = struct { given: ?Mir.Value = null, fits: ?Mir.Value = null };

/// §9.14 / IEEE 1364-2005 §17.11.1's integral argument and its source width,
/// shared by expression and statement calls (the latter discard the result).
pub fn lowerClog2(self: *Lower, tok: u32, arg: Ast.ExprId) Oom!TypedValue {
    assert(arg == .none or self.exprValid(arg));
    assert(self.blockValid(self.cur));
    const tv = try lower_expr.lowerClog2Arg(self, arg, null);
    if (tv.ty != .integer or arg == .none) {
        // A poisoned argument was reported where it failed (E0130).
        if (tv.v != .undef or arg == .none) try self.err(tok, .E0892, "got {s}", .{@tagName(tv.ty)});
        return poison;
    }
    const width = (try lower_constfold.clog2Width(self, arg)) orelse 64;
    if (width > 64 and !try lower_constfold.clog2WideCarrier(self, arg, 0)) {
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

// ---- private ----

fn hostSized(self: *Lower, e: Ast.ExprId, acc: *HostSized) Oom!void {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
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

test "§9.14 a $clog2 operand 10,000 operators deep lowers in time linear in its depth" {
    // Oracle: IEEE 1364-2005 §5.5 sizes every operator of the operand from
    // its operands, so lowering it is one sizing pass plus one lowering
    // pass; it lowers with no diagnostic. Planning each operator by walking
    // its whole operand again was quadratic in the depth: 65 s in Debug here,
    // against 0.24 s sized once.
    const n = 10_000;
    const bound_ms = 2_000;
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "module m(p);\n  inout p;\n  electrical p;\n  integer k, j;\n  analog begin\n    k = V(p);\n    j = $clog2(k");
    for (0..n) |_| try src.appendSlice(gpa, " + 1");
    try src.appendSlice(gpa, ");\n    I(p) <+ j;\n  end\nendmodule\n");
    var h: Lower.Harness = undefined;
    try h.init(gpa, src.items);
    defer h.deinit();
    const io = std.testing.io;
    const start: std.Io.Timestamp = .now(io, .awake);
    // Lowering recurses once per operator: a stack for the depth, not the walk.
    _ = try h.lowerOnStack(256 << 20) orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
    const ms = start.durationTo(.now(io, .awake)).toMilliseconds();
    try std.testing.expectEqual(@as(usize, 0), h.bag.count());
    try std.testing.expect(ms < bound_ms);
}
