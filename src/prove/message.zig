//! The prover's diagnostic text: a Value or instruction in, the source span
//! it came from and the words the user wrote it in out (a parameter, a node
//! probe, or the unbounded leaf a computed value depends on), and the shared
//! skeleton of every finiteness diagnostic. Only `domain.zig` and
//! `verdict.zig` build diagnostics; this file only phrases them.
//!
//! LRM clauses this file's code cites: §3.4.2, §4.3.2, §4.4.
//!
//! Contents:
//! - `pub const Error = Allocator.Error`
//! - `pub fn span(p: *const Prover, inst: Mir.Inst) diag.Span`
//! - `pub fn valueSpan(p: *const Prover, v: Mir.Value) diag.Span`
//! - `pub fn violation(p: *Prover, inst: Mir.Inst, code: diag.Code, operand: Mir.Value, iv: Interval, what: []const u8) Error!diag.Builder`
//! - `pub fn emitError(p: *Prover, b: *diag.Builder) Error!void`
//! - `pub fn describe(p: *const Prover, v: Mir.Value) Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const Interval = @import("Interval.zig");
const Prover = @import("Prover.zig");
const proof = @import("proof.zig");

/// Fails only on allocation, in the arena or the diagnostics bag.
pub const Error = Allocator.Error;

/// Most values `unboundedLeaf` visits, and the depth of its stack: the leaf
/// only names the culprit in a message, so a miss costs words, not a proof.
const leaf_visits_max: u32 = 256;
const leaf_stack_max: usize = 64;

/// The longest `ivText`: `{d}` spells a double in full, up to ~345 bytes a
/// bound (4.9e-324), so two bounds and the words fit.
const iv_text_max: usize = 768;

/// Returns the source span of `inst`, or none for an unattributed row.
pub fn span(p: *const Prover, inst: Mir.Inst) diag.Span {
    assert(inst != .none);
    assert(@backingInt(inst) < p.mir.instCount());
    const tok = p.mir.instTok(inst);
    // Token 0 is the first line of the annex D prelude, not a location.
    if (tok == Mir.no_tok) return .{};
    return p.lowered.tokenSpan(tok);
}

/// Returns the span of whatever defined `v`, so a label can point at the
/// parameter or the sub-expression the prover is really complaining about.
pub fn valueSpan(p: *const Prover, v: Mir.Value) diag.Span {
    assert(@backingInt(v) < p.an.nv);
    switch (p.mir.valueDef(p.an.rv(v))) {
        .inst_result => |inst| return span(p, inst),
        .param_ref => |pi| {
            if (pi >= p.lowered.params.items.len) return .{};
            const tok = p.lowered.params.items[pi].tok;
            if (tok == Mir.no_tok) return .{};
            return p.lowered.tokenSpan(tok);
        },
        .undef, .float_const, .int_const, .str_const, .block_param => return .{},
    }
}

/// Returns the shared skeleton of every finiteness diagnostic: a caret on
/// `inst`, a label on whatever defined `operand`, and the operand described
/// in the terms the user wrote it in. The caller adds its point and help.
pub fn violation(
    p: *Prover,
    inst: Mir.Inst,
    code: diag.Code,
    operand: Mir.Value,
    iv: Interval,
    what: []const u8,
) Error!diag.Builder {
    assert(what.len != 0);
    assert(p.error_count <= proof.errors_max);
    var buf: [iv_text_max]u8 = undefined;
    const at = span(p, inst);
    var b = p.bag.build(.proof, code, at);
    const who = try describe(p, operand);
    b.msg("{s} is {s}{s}", .{ what, who, ivText(&buf, iv) });
    const def = valueSpan(p, operand);
    if (!def.isNone() and def.start != at.start) b.label(def, "{s} originates here", .{who});
    return b;
}

/// Emits a §4.3.2 error and counts it, or drops it once `proof.errors_max`
/// were counted, so one bad expression does not report a cascade.
pub fn emitError(p: *Prover, b: *diag.Builder) Error!void {
    assert(p.error_count <= proof.errors_max);
    if (p.error_count == proof.errors_max) return;
    try b.emit();
    p.error_count += 1;
    assert(p.error_count <= proof.errors_max);
}

/// Returns `v` named as the user wrote it: a parameter, a node probe, a
/// constant, a call's result, or a computed value by the unbounded leaf it
/// depends on. The text lives in the prover's arena.
pub fn describe(p: *const Prover, v: Mir.Value) Error![]const u8 {
    const rv = p.an.rv(v);
    assert(@backingInt(rv) < p.an.nv);
    return switch (p.mir.valueDef(rv)) {
        .param_ref => |pi| if (pi < p.lowered.params.items.len)
            p.arena.print("parameter `{s}`", .{p.lowered.params.items[pi].name})
        else
            "a parameter",
        .block_param => |n| p.arena.print("a probe of node `{s}`", .{p.lowered.nodeName(@intCast(n))}),
        .float_const => |c| p.arena.print("the constant {d}", .{c}),
        .int_const => |c| p.arena.print("the constant {d}", .{c}),
        .inst_result => |inst| blk: {
            if (p.mir.instOp(inst) == .call)
                break :blk p.arena.print("the result of `{s}()`", .{p.mir.instData(inst).call.name});
            const leaf = unboundedLeaf(p, rv) orelse break :blk "a computed expression";
            // A leaf is a parameter or a probe, so this recursion is one deep.
            assert(p.mir.valueDef(p.an.rv(leaf)) != .inst_result);
            break :blk p.arena.print("an expression of {s}", .{try describe(p, leaf)});
        },
        .undef, .str_const => "an unknown value",
    };
}

// ---- private ----

/// The first leaf in `root`'s backward slice with no bound evidence: the
/// thing the user has to constrain. Budgeted; used only for the message.
fn unboundedLeaf(p: *const Prover, root: Mir.Value) ?Mir.Value {
    assert(p.mir.valueDef(root) == .inst_result); // `describe` asks for computed values only
    var stack: [leaf_stack_max]Mir.Value = undefined;
    var n: usize = 1;
    stack[0] = root;
    var budget: u32 = leaf_visits_max;
    while (n > 0 and budget > 0) {
        budget -= 1;
        n -= 1;
        const v = stack[n];
        const i = p.idxOf(v);
        switch (p.mir.valueDef(@fromBackingInt(@intCast(i)))) {
            .param_ref, .block_param => if (!p.ivAt(i).bounded()) return v,
            .inst_result => |inst| {
                if (p.mir.instOp(inst) == .phi) continue;
                var buf: [3]Mir.Value = undefined;
                for (p.operands(inst, &buf)) |o| {
                    assert(n <= stack.len);
                    if (n == stack.len) break;
                    stack[n] = o;
                    n += 1;
                }
            },
            .undef, .float_const, .int_const, .str_const => {},
        }
    }
    assert(n == 0 or budget == 0); // the slice ran out, or the budget did
    return null;
}

fn ivText(buf: *[iv_text_max]u8, iv: Interval) []const u8 {
    if (iv.lo == -math.inf(f64) and iv.hi == math.inf(f64)) return " with no known bounds";
    // `iv_text_max` holds two doubles spelled in full and the words.
    const r = std.mem.print(buf, " with known range {c}{d}:{d}{c}", .{
        @as(u8, if (iv.lo_open) '(' else '['),
        iv.lo,
        iv.hi,
        @as(u8, if (iv.hi_open) ')' else ']'),
    }) catch unreachable;
    assert(r.len <= buf.len);
    assert(r.len != 0);
    return r;
}
