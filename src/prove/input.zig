//! What the setup tiers and every codegen `plan/` function read: the lowered
//! module and the facts derived from it, as a value rather than the emitter,
//! so a plan takes inputs and returns a value. Field names match codegen's
//! `Gen`. Also the one argument fact the tiers share with codegen, `strArg`.
//! No clause of its own; each planner cites the clauses it decides.
//!
//! Contents:
//! - `pub const Input = struct { arena: Allocator, mir: *const Mir, an: *const Analysis, lowered: *const Lowered }`
//! - `pub fn strArg(in: Input, args: []const Mir.Value, i: usize) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Analysis = @import("Analysis.zig");
const Fixture = @import("fixture.zig").Fixture;

/// The lowered module and the analysis over it, borrowed for one
/// compilation. Every pointer must outlive the plans built from it, and none
/// of the three may change while a plan is being built: the planners index
/// `an`'s tables by the `mir` values they were built over.
pub const Input = struct {
    /// The per-compilation arena: every plan is allocated here and freed with it.
    arena: Allocator,
    mir: *const Mir,
    an: *const Analysis,
    lowered: *const Lowered,
};

/// Returns the literal string at argument `i`, or null when it is not one (or
/// `i` is past the end). The slice borrows the MIR's string table.
pub fn strArg(in: Input, args: []const Mir.Value, i: usize) ?[]const u8 {
    assert(in.an.mir == in.mir); // the analysis is over this MIR
    if (i >= args.len) return null;
    assert(@backingInt(args[i]) < in.an.nv);
    const def = in.mir.valueDef(in.an.rv(args[i]));
    return if (def == .str_const) def.str_const else null;
}

test strArg {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const s = try f.mir.addStrConst(a, "pnjlim");
    const x = try f.mir.addFloatConst(a, 0.5);
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    const args = [_]Mir.Value{ x, s };
    try std.testing.expectEqualStrings("pnjlim", strArg(in, &args, 1).?);
    // A number is not a string, and a position past the end is not either.
    try std.testing.expectEqual(@as(?[]const u8, null), strArg(in, &args, 0));
    try std.testing.expectEqual(@as(?[]const u8, null), strArg(in, &args, 2));
}
