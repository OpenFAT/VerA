//! MIR speculation guards: a (row, condition, polarity) literal in, a chain
//! in `guard_lits` headed from `guard_of` out, and the chain back as the
//! conditions it reads. `prove/ifconv.zig`'s `.speculate` pass writes them;
//! codegen renders a guarded row on a safe argument while a literal fails.
//!
//! Cites: §4.2.12 (`?:` arms), §4.3.1/§4.3.2 (the domain-restricted
//! functions a guard protects).
//!
//! Contents:
//! - `pub const GuardIter = struct`, `GuardIter.next(it: *GuardIter) ?Value`
//! - `pub fn guardOf(mir: *const Mir, inst: Inst) ?u32`
//! - `pub fn guardConds(mir: *const Mir, inst: Inst) GuardIter`
//! - `pub fn addGuardLit(mir: *Mir, gpa: Allocator, inst: Inst, cond: Value, taken: bool) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("Mir.zig");
const Inst = Mir.Inst;
const Value = Mir.Value;
const GuardLit = Mir.GuardLit;

/// Walks one guard chain in chain order (`guard_lits`).
pub const GuardIter = struct {
    mir: *const Mir,
    lit: u32,
    /// Literals returned so far; a chain longer than the pool is a cycle.
    steps: u32 = 0,

    /// Returns the next literal's condition, or null past the chain's end.
    /// Asserts that the chain does not cycle.
    pub fn next(it: *GuardIter) ?Value {
        if (it.lit == GuardLit.end) return null;
        const lits = it.mir.guard_lits.items;
        assert(it.lit < lits.len);
        assert(it.steps < lits.len); // more literals than exist ⇒ a cycle
        const l = lits[it.lit];
        it.lit = l.next;
        it.steps += 1;
        return l.cond;
    }
};

/// Returns the first literal of `inst`'s speculation guard (a `guard_lits`
/// index), or null when the row runs wherever it stands.
pub fn guardOf(mir: *const Mir, inst: Inst) ?u32 {
    assert(inst != .none);
    const lit = mir.guard_of.get(inst) orelse return null;
    assert(lit < mir.guard_lits.items.len);
    return lit;
}

/// Returns an iterator over the conditions `inst`'s guard reads. Codegen
/// renders them with the row, so they are operands to every analysis that
/// asks what the row reads.
pub fn guardConds(mir: *const Mir, inst: Inst) GuardIter {
    const it: GuardIter = .{ .mir = mir, .lit = guardOf(mir, inst) orelse GuardLit.end };
    if (it.lit != GuardLit.end) assert(it.lit < mir.guard_lits.items.len);
    return it;
}

/// Prepends the literal (`cond`, `taken`) to `inst`'s speculation guard, so
/// the newest conversion heads the chain. On error the guard is unchanged.
/// Asserts that `inst` is a row and the pool has room for one more literal.
pub fn addGuardLit(mir: *Mir, gpa: Allocator, inst: Inst, cond: Value, taken: bool) Allocator.Error!void {
    assert(@backingInt(inst) < mir.insts.len);
    const at: u32 = @intCast(mir.guard_lits.items.len);
    assert(at != GuardLit.end);
    try mir.guard_lits.ensureUnusedCapacity(gpa, 1); // no `guard_of` entry without its literal
    const gop = try mir.guard_of.getOrPut(gpa, inst);
    const next = if (gop.found_existing) gop.value_ptr.* else GuardLit.end;
    mir.guard_lits.appendAssumeCapacity(.{ .cond = cond, .taken = taken, .next = next });
    gop.value_ptr.* = at;
    assert(guardOf(mir, inst).? == at);
}

test "mir: a speculation guard chain reads back newest literal first" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);
    const entry = try mir.addBlock(gpa);
    const v = try mir.emit(gpa, entry, .fneg, &.{.f_one});
    const inst = mir.valueDef(v).inst_result;

    // An unguarded row has no chain.
    try std.testing.expectEqual(@as(?u32, null), mir.guardOf(inst));
    var none = mir.guardConds(inst);
    try std.testing.expectEqual(@as(?Value, null), none.next());

    // `addGuardLit` prepends: the outer conversion runs last, so it heads
    // the chain (`guard_lits`: outermost first).
    try mir.addGuardLit(gpa, inst, .one, true);
    try mir.addGuardLit(gpa, inst, .zero, false);
    var it = mir.guardConds(inst);
    try std.testing.expectEqual(Value.zero, it.next().?);
    try std.testing.expectEqual(Value.one, it.next().?);
    try std.testing.expectEqual(@as(?Value, null), it.next());
    const head = mir.guard_lits.items[mir.guardOf(inst).?];
    try std.testing.expect(!head.taken);
    try std.testing.expect(mir.guard_lits.items[head.next].taken);
}
