//! IEEE 1364-2005 §5.4 wide integers: a `$wide`/`$wide$int` call's
//! `Lowered.wide_nodes` tree in, one Zig expression over
//! `kernels/wide_kernels.zig` out (`zwAdd(72, a, b)`), every node already of
//! the type `analog/wide.zig` sized it to. Also the Zig type of a `.wide`
//! value (`ZW(n)`), which slots, `Instance` fields and the core's cache spell.
//! Cites: §7.3.1; IEEE 1364-2005 §4.8.2, §5.1, §5.1.9, §5.1.12, §5.4.1, §5.5.
//!
//! Contents:
//! - `pub const Read = enum`
//! - `pub fn zigTy(self: *Gen, width: u32) Error![]const u8`
//! - `pub fn emitWide(self: *Gen, args: []const Mir.Value, read: Read) Error!void`
//! - `pub fn emitConstInit(self: *Gen, v: Mir.Value) Error!bool`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const codegen = @import("../codegen.zig");
const float_lanes = @import("float/lanes.zig");
const gen_render = @import("render.zig");
const render_sysfunc = @import("render_sysfunc.zig");
const Gen = codegen.Gen;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;

/// What `emitWide` reads of the tree: the root's bits, or the §7.3.1 integer
/// a select reads (`$wide$int`).
pub const Read = enum { bits, int };

/// Bits per `wide_lits` word and per `leaf_words` operand (`zwLimbs`).
const word_bits = 32;

comptime {
    // A literal's words are `wide_lits` rows, so a word is one row.
    assert(word_bits == @bitSizeOf(std.meta.Elem(@FieldType(@FieldType(Lowered, "wide_lits"), "items"))));
    assert(word_bits % 8 == 0);
}

/// Returns the Zig type of a `.wide` value of `width` bits, arena-owned.
/// Asserts that `width` is nonzero (a width of 0 is a real).
pub fn zigTy(self: *Gen, width: u32) Error![]const u8 {
    assert(width != 0);
    const s = try self.arena.print("ZW({d})", .{width});
    assert(s.len > "ZW()".len);
    return s;
}

/// Writes `$wide(root, operands...)` (the root's bits) or, for `.int`,
/// `$wide$int(root, operands...)` (the §7.3.1 integer a select reads).
/// Asserts that `args` holds the root's node index first and that it names a
/// `Lowered.wide_nodes` row.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn emitWide(self: *Gen, args: []const Mir.Value, read: Read) Error!void {
    assert(args.len >= 1);
    const root = render_sysfunc.intArg(self, args, 0).?;
    assert(root < self.lowered.wide_nodes.items.len);
    const len_before = self.out.items.len;
    const n = self.lowered.wide_nodes.items[root];
    if (read == .int) try self.b("zwInt({d}, {}, ", .{ n.width, n.signed });
    try node(self, args[1..], @intCast(root));
    if (read == .int) try self.b(")", .{});
    assert(self.out.items.len > len_before);
}

/// Writes `v`'s bits as a comptime value when it is a `$wide` call over a
/// tree of literals (a held `reg`'s `Instance` default) and returns true;
/// returns false, writing nothing, otherwise.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn emitConstInit(self: *Gen, v: Mir.Value) Error!bool {
    const len_before = self.out.items.len;
    const def = self.mir.valueDef(self.an.rv(v));
    if (def != .inst_result or self.mir.instOp(def.inst_result) != .call) return false;
    const d = self.mir.instData(def.inst_result).call;
    if (d.callee != .@"$wide" or d.args.len != 1) return false;
    try emitWide(self, d.args, .bits);
    assert(self.out.items.len > len_before);
    return true;
}

// ---- private ----

/// Writes node `i` over the call's operands `ops`. Recurses once per operand;
/// every operand's index is below its parent's, so the depth is under `i`.
fn node(self: *Gen, ops: []const Mir.Value, i: u32) Error!void {
    const nodes = self.lowered.wide_nodes.items;
    assert(i < nodes.len);
    const n = nodes[i];
    const w = n.width;
    // `analog/wide.zig` appends a node after its operands, so every operand
    // index is below its parent's: the walk terminates and cannot cycle.
    if (n.a != none_u32) assert(n.a < i);
    if (n.b != none_u32) assert(n.b < i);
    if (n.c != none_u32) assert(n.c < i);
    const len_before = self.out.items.len;
    switch (n.op) {
        .leaf_int => {
            assert(n.arg < ops.len);
            try self.b("zwLeaf({d}, ", .{w});
            try gen_render.renderVal(self, ops[n.arg], .int);
            try self.b(")", .{});
        },
        .leaf_words => {
            const words = (w + word_bits - 1) / word_bits;
            assert(n.arg + words <= ops.len);
            try self.b("zwWords({d}, .{{ ", .{w});
            for (0..words) |k| {
                if (k != 0) try self.b(", ", .{});
                try gen_render.renderVal(self, ops[n.arg + k], .int);
            }
            try self.b(" }})", .{});
        },
        .leaf_wide => {
            assert(n.arg < ops.len);
            try gen_render.renderVal(self, ops[n.arg], .wide);
        },
        .leaf_real => {
            assert(n.arg < ops.len);
            // The value only: a wide integer carries no derivative.
            float_lanes.pinLanes(self, ops[n.arg]);
            try self.b("(", .{});
            try gen_render.renderVal(self, ops[n.arg], .real);
            try self.b(").val()", .{});
        },
        .lit => {
            const words = (w + word_bits - 1) / word_bits;
            assert(n.arg + words <= self.lowered.wide_lits.items.len);
            try self.b("zwConst({d}, .{{ ", .{w});
            for (self.lowered.wide_lits.items[n.arg..][0..words], 0..) |d, k| {
                if (k != 0) try self.b(", ", .{});
                try self.b("0x{x}", .{d});
            }
            try self.b(" }})", .{});
        },
        .resize => {
            try self.b("zwResize({d}, {d}, {}, ", .{ w, nodes[n.a].width, n.signed });
            try node(self, ops, n.a);
            try self.b(")", .{});
        },
        .to_real => {
            assert(w == 0);
            try self.b("zwToReal({d}, {}, ", .{ nodes[n.a].width, nodes[n.a].signed });
            try node(self, ops, n.a);
            try self.b(")", .{});
        },
        .from_real => {
            assert(nodes[n.a].width == 0);
            try self.b("zwFromReal({d}, ", .{w});
            try node(self, ops, n.a);
            try self.b(")", .{});
        },
        .neg => if (w == 0) try unaryReal(self, ops, "-", n.a) else try call(self, ops, "zwNeg", n, &.{n.a}),
        .not => try call(self, ops, "zwNot", n, &.{n.a}),
        .add => if (w == 0) try binaryReal(self, ops, "+", n) else try call(self, ops, "zwAdd", n, &.{ n.a, n.b }),
        .sub => if (w == 0) try binaryReal(self, ops, "-", n) else try call(self, ops, "zwSub", n, &.{ n.a, n.b }),
        .mul => if (w == 0) try binaryReal(self, ops, "*", n) else try call(self, ops, "zwMul", n, &.{ n.a, n.b }),
        .div => if (w == 0) try binaryReal(self, ops, "/", n) else try signedCall(self, ops, "zwDiv", n),
        .rem => if (w == 0) try fnReal(self, ops, "@rem", n) else try signedCall(self, ops, "zwRem", n),
        .@"and" => try call(self, ops, "zwAnd", n, &.{ n.a, n.b }),
        .@"or" => try call(self, ops, "zwOr", n, &.{ n.a, n.b }),
        .xor => try call(self, ops, "zwXor", n, &.{ n.a, n.b }),
        .xnor => try call(self, ops, "zwXnor", n, &.{ n.a, n.b }),
        .shl => {
            try self.b("zwShl({d}, ", .{w});
            try node(self, ops, n.a);
            try self.b(", {d}, ", .{nodes[n.b].width});
            try node(self, ops, n.b);
            try self.b(")", .{});
        },
        .shr, .ashr => {
            // §5.1.12: `>>>` fills with the sign of a signed operand only.
            try self.b("zwShr({d}, {}, ", .{ w, n.op == .ashr and n.signed });
            try node(self, ops, n.a);
            try self.b(", {d}, ", .{nodes[n.b].width});
            try node(self, ops, n.b);
            try self.b(")", .{});
        },
        .pow => if (w == 0) try fnReal(self, ops, "std.math.pow(f64, ", n) else {
            // A real exponent makes the operator real (`analog/wide.zig`).
            const e = nodes[n.b];
            try self.b("zwPow({d}, {}, ", .{ w, n.signed });
            try node(self, ops, n.a);
            try self.b(", {d}, {}, ", .{ e.width, e.signed });
            try node(self, ops, n.b);
            try self.b(")", .{});
        },
        .eq, .lt, .le => try compare(self, ops, n),
        .land, .lor => {
            try self.b("@as(u1, @intFromBool(", .{});
            try truth(self, ops, n.a);
            try self.b(" {s} ", .{if (n.op == .land) "and" else "or"});
            try truth(self, ops, n.b);
            try self.b("))", .{});
        },
        .lnot => {
            try self.b("@as(u1, @intFromBool(!", .{});
            try truth(self, ops, n.a);
            try self.b("))", .{});
        },
        .red_and, .red_or, .red_xor => {
            const a = nodes[n.a];
            try self.b("@as(u1, @intFromBool({s}{s}({d}, ", .{
                if (n.op == .red_or) "!" else "",
                switch (n.op) {
                    .red_and => "zwAll",
                    .red_or => "zwIsZero",
                    .red_xor => "zwParity",
                    else => unreachable, // else: the enclosing prong
                },
                a.width,
            });
            try node(self, ops, n.a);
            try self.b(")))", .{});
        },
        .cond => {
            try self.b("(if (", .{});
            try truth(self, ops, n.a);
            try self.b(") ", .{});
            try node(self, ops, n.b);
            try self.b(" else ", .{});
            try node(self, ops, n.c);
            try self.b(")", .{});
        },
    }
    assert(self.out.items.len > len_before);
}

/// Writes an `eq`/`lt`/`le` node as a `u1`: a real comparison over two reals,
/// else `zwEq`/`zwLt` at the operands' width.
fn compare(self: *Gen, ops: []const Mir.Value, n: Lowered.WideNode) Error!void {
    assert(n.op == .eq or n.op == .lt or n.op == .le);
    assert(n.b != none_u32);
    const a = self.lowered.wide_nodes.items[n.a];
    try self.b("@as(u1, @intFromBool(", .{});
    if (a.width == 0) {
        try self.b("(", .{});
        try node(self, ops, n.a);
        try self.b(") {s} (", .{switch (n.op) {
            .eq => "==",
            .lt => "<",
            .le => "<=",
            else => unreachable, // else: asserted on entry
        }});
        try node(self, ops, n.b);
        try self.b(")", .{});
    } else {
        // `le` is `!(b < a)`: an integer order is total.
        const swap = n.op == .le;
        try self.b("{s}{s}({d}, ", .{ if (swap) "!" else "", if (n.op == .eq) "zwEq" else "zwLt", a.width });
        if (n.op != .eq) try self.b("{}, ", .{a.signed});
        try node(self, ops, if (swap) n.b else n.a);
        try self.b(", ", .{});
        try node(self, ops, if (swap) n.a else n.b);
        try self.b(")", .{});
    }
    try self.b("))", .{});
}

/// §5.1.9 the truth of node `i`: nonzero (an integer has no x here).
fn truth(self: *Gen, ops: []const Mir.Value, i: u32) Error!void {
    assert(i != none_u32);
    assert(i < self.lowered.wide_nodes.items.len);
    const n = self.lowered.wide_nodes.items[i];
    if (n.width == 0) {
        try self.b("((", .{});
        try node(self, ops, i);
        return self.b(") != 0.0)", .{});
    }
    try self.b("!zwIsZero({d}, ", .{n.width});
    try node(self, ops, i);
    try self.b(")", .{});
}

/// Writes `name(width, operands...)`.
fn call(self: *Gen, ops: []const Mir.Value, name: []const u8, n: Lowered.WideNode, operands: []const u32) Error!void {
    assert(n.width != 0); // a real node takes its real spelling
    assert(operands.len >= 1);
    try self.b("{s}({d}", .{ name, n.width });
    for (operands) |o| {
        try self.b(", ", .{});
        try node(self, ops, o);
    }
    try self.b(")", .{});
}

/// Writes `name(width, signed, a, b)`, for the operators that read a sign.
fn signedCall(self: *Gen, ops: []const Mir.Value, name: []const u8, n: Lowered.WideNode) Error!void {
    assert(n.width != 0);
    assert(n.b != none_u32);
    try self.b("{s}({d}, {}, ", .{ name, n.width, n.signed });
    try node(self, ops, n.a);
    try self.b(", ", .{});
    try node(self, ops, n.b);
    try self.b(")", .{});
}

/// Writes `(op(a))` over a real.
fn unaryReal(self: *Gen, ops: []const Mir.Value, op: []const u8, a: u32) Error!void {
    assert(op.len != 0);
    assert(a != none_u32);
    try self.b("({s}(", .{op});
    try node(self, ops, a);
    try self.b("))", .{});
}

/// Writes `((a) op (b))` over two reals.
fn binaryReal(self: *Gen, ops: []const Mir.Value, op: []const u8, n: Lowered.WideNode) Error!void {
    assert(n.width == 0);
    assert(n.b != none_u32);
    try self.b("((", .{});
    try node(self, ops, n.a);
    try self.b(") {s} (", .{op});
    try node(self, ops, n.b);
    try self.b("))", .{});
}

/// `f(a, b)` over two reals; `f` ends where its first operand begins.
fn fnReal(self: *Gen, ops: []const Mir.Value, f: []const u8, n: Lowered.WideNode) Error!void {
    assert(n.width == 0);
    assert(n.b != none_u32);
    try self.b("{s}{s}", .{ f, if (std.mem.endsWith(u8, f, " ")) "" else "(" });
    try node(self, ops, n.a);
    try self.b(", ", .{});
    try node(self, ops, n.b);
    try self.b(")", .{});
}
