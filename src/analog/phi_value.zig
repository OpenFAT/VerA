//! A phi's operand pairs in, the one value they all resolve to out (Braun et
//! al.'s trivial-phi rule for a phi that does not exist yet, so there is no
//! self-reference to skip).
//!
//! Cites: none (Braun et al., "Simple and Efficient Construction of Static
//! Single Assignment Form", 2013, §3.1).
//!
//! Contents:
//! - `pub fn sameValue(mir: *const Mir, pairs: []const Mir.PhiPair) ?Mir.Value`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;

/// Returns the one value every pair resolves to through `Mir.resolveAlias`
/// (`.undef` for no pairs), or null when two pairs disagree.
pub fn sameValue(mir: *const Mir, pairs: []const Mir.PhiPair) ?Mir.Value {
    if (pairs.len == 0) return .undef;
    const first = mir.resolveAlias(pairs[0].value);
    for (pairs[1..]) |p| if (mir.resolveAlias(p.value) != first) return null;
    assert(mir.resolveAlias(first) == first); // an alias chain ends at its root
    assert(mir.resolveAlias(pairs[pairs.len - 1].value) == first);
    return first;
}

// ---- private ----

test sameValue {
    // Oracle: the rule's own cases. No pairs is `.undef`; pairs over one
    // constant agree; a second constant disagrees.
    var mir: Mir = .{};
    defer mir.deinit(std.testing.allocator);
    const one = try mir.addFloatConst(std.testing.allocator, 1.5);
    const two = try mir.addFloatConst(std.testing.allocator, 2.5);
    try std.testing.expectEqual(Mir.Value.undef, sameValue(&mir, &.{}).?);
    try std.testing.expectEqual(one, sameValue(&mir, &.{ .{ .block = .entry, .value = one }, .{ .block = .entry, .value = one } }).?);
    try std.testing.expectEqual(null, sameValue(&mir, &.{ .{ .block = .entry, .value = one }, .{ .block = .entry, .value = two } }));
}
