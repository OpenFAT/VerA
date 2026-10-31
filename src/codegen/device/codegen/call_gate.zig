//! A §9.4/§9.5/§9.7 task call outside the printing artifact's per-pass
//! schedule -> its text: the void result a dropped task renders, the
//! `if (<pass>)` gate a printing display unit wraps around a per-pass call, and
//! a §9.5 call rendered outside the display unit (its descriptor or result
//! type's zero, with no file effect).
//! Cites: §9.4, §9.4.6, §9.5, §9.5.9, §9.7.
//!
//! Contents:
//! - `pub fn voidTask(self: *Gen) Error!void`
//! - `pub fn gateOpen(self: *Gen, c: Mir.Callee, inst: Mir.Inst) Error!bool`
//! - `pub fn gateClose(self: *Gen) Error!void`
//! - `pub fn emitFileCallDropped(self: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const Mir = @import("ir").Mir;
const Error = codegen.Error;

/// Writes the void result of a §9.4/§9.7 task outside the printing unit.
/// Every such callee is real-valued, so one answer serves all. (§9.5
/// descriptors go through `emitFileCallDropped`, which respects their type.)
pub fn voidTask(self: *Gen) Error!void {
    const len_before = self.out.items.len;
    try self.b("S.con(0.0)", .{});
    assert(self.out.items.len == len_before + "S.con(0.0)".len);
}

/// §9.4.6/§9.5.9 opens `(if (<cond>) ` around call `inst` in a printing
/// display unit that runs in passes (`Gen.passes`), where `<cond>` names the
/// passes of `contract.SayPass` that perform it; the caller writes the call,
/// then ` else ` and what the call answers when it is not performed, then
/// `)`. Returns false, writing nothing, outside such a unit and for a
/// §9.5.4 reader, which only reads what its count's call latched.
///   `$debug`, `$fdebug`: every pass but `.accepted` (§9.4.1 "for each
///     iteration of the analog solver"; §9.5.9 "the write operation shall
///     occur even if the evaluation occurred during an iteration that was
///     rejected").
///   one of those or a §9.5 call in `analog initial`: `.all`, and `.iteration`
///     at the first iterate, since §5.2.1 executes the block once per
///     analysis, "before a matrix solution is available".
///   every other task: every pass but `.iteration` (§9.4.6, §9.5.9).
/// `pass` is comptime, so a pass that does not perform the call compiles
/// only its other answer.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn gateOpen(self: *Gen, c: Mir.Callee, inst: Mir.Inst) Error!bool {
    if (!self.passes or !self.cur.emitting_display or Mir.callee.family(c) == .file_read) return false;
    assert(self.display == .emit);
    assert(self.cur.emitting_display);
    self.cur.uses.pass = true;
    // §9.7.3: `$fatal` "terminates the simulation without checking whether the
    // iteration would be rejected", so it is performed at the iterate like
    // `$debug`, not held back to the accepted point with the display tasks.
    const every = c == .@"$debug" or c == .@"$fdebug" or c == .@"$fatal";
    const init = std.mem.findScalar(Mir.Inst, self.init_calls, inst) != null and (every or Mir.callee.isFileCall(c));
    if (init) self.cur.uses.sim = true;
    // §9.7.1/§9.7.2: a `$finish`/`$stop` that already ran means the run ends
    // at the enclosing wrapper (`zFinishPass`); no later task of this pass
    // may print, the way an immediate exit would have stopped them.
    try self.b("(if (zFinish == 0 and ({s})) ", .{if (init)
        "pass == .all or (pass == .iteration and sim.iteration == 1)"
    else if (every)
        "pass != .accepted"
    else
        "pass != .iteration"});
    return true;
}

/// Closes `gateOpen`'s `if` for a void task: not performed, it is the
/// `S.con(0.0)` every void call renders.
pub fn gateClose(self: *Gen) Error!void {
    assert(self.passes);
    assert(self.cur.uses.pass);
    try self.b(" else ", .{});
    try voidTask(self);
    return self.b(")", .{});
}

/// Writes a §9.5 call outside the display unit (every §9.5 call in a
/// `.drop` build). The result has `Mir.callee.ty`'s type; a descriptor is
/// an integer (§9.5.1).
/// Asserts that `c` is a §9.5 callee.
pub fn emitFileCallDropped(self: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    assert(Mir.callee.isFileCall(c));
    _ = args; // `UnitPlan.dispHere` did not mark them: there is nothing here to read them
    // In a printing artifact the display unit performed the call and latched
    // its integer result, so read it back.
    if (self.display == .emit and Mir.callee.ty(c) == .int)
        return self.b("zFRes({d}).*", .{site});
    // Zero is the LRM's answer: §9.5.1 `$fopen` failure, §9.5.4.1 read
    // error, §9.5.8 no EOF, §9.5.7 no error.
    try self.b("{s}", .{switch (Mir.callee.ty(c)) {
        .real => "S.con(0.0)",
        .int => "@as(i64, 0)",
        .str => "\"\"",
        .wide => unreachable, // `Callee.table` types no file call wide
    }});
}
