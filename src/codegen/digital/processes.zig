//! The bytecode of an elaborated `Run` -> one Zig function per process,
//! `fn proc<entry>(s, pc)`, a labeled switch over the pcs the process can
//! reach, and the dispatch table that maps every pc to its function. The
//! walk is the interpreter's control flow: a suspension resumes at the pc it
//! names, a `.continuous` at itself.
//! Cites: IEEE 1364-2005 §9.9 (structured procedures), §6.1 (continuous
//! assignments), §9.3, §9.8.2, §10.2.3 (a timed body is a process of its
//! own), §10.3 (disable).
//!
//! Contents:
//! - `pub fn reach(em: *Emitter, entry: u32, seen: []bool) Error![]const u32`
//! - `pub fn process(em: *Emitter, pcs: []const u32) Error!void`
//! - `pub fn usesS(text: []const u8) bool`
//! - `pub fn dispatchTable(em: *Emitter, entry_of: []const ?u32, time0: []const bool, activations: bool, settles: bool) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const instruction = @import("instruction.zig");

/// Returns every pc the process entered at `entry` can reach, ascending,
/// marked in `seen`; queues each timed task a `.call_timed` reaches
/// (§10.2.3), whose body becomes a process of its own.
pub fn reach(em: *Emitter, entry: u32, seen: []bool) Error![]const u32 {
    const r = em.r;
    const code = r.program.code.items;
    assert(seen.len == code.len);
    assert(!seen[entry]);
    var pcs: std.ArrayList(u32) = .empty;
    var work: std.ArrayList(u32) = .empty;
    try work.append(em.arena, entry);
    // Every pc enters `pcs` once (`seen`), and only an unseen pc pushes its
    // successors, so the loop ends.
    while (work.pop()) |pc| {
        if (seen[pc]) continue;
        seen[pc] = true;
        try pcs.append(em.arena, pc);
        assert(pcs.items.len <= code.len);
        try work.appendSlice(em.arena, em.block_ends.of(pc));
        const next = pc + 1;
        switch (code[pc]) {
            .stop, .continuous => {},
            .jump => |t| try work.append(em.arena, t),
            .restart => |x| try work.append(em.arena, x.target),
            .branch => |b| try work.appendSlice(em.arena, &.{ next, b.otherwise }),
            .case_select => |c| {
                try work.append(em.arena, c.fallback);
                const arms = r.file.stmt(c.statement).case_stmt.arms.len;
                try work.appendSlice(em.arena, r.program.case_targets.items[c.targets..][0..arms]);
            },
            .repeat_start => |x| try work.appendSlice(em.arena, &.{ next, x.end }),
            .repeat_next => |x| try work.appendSlice(em.arena, &.{ next, x.body }),
            .task => |t| if (t.task != .finish) try work.append(em.arena, next),
            .assign, .init_var, .delay, .wait_event, .wait_slots, .wait_level, .trigger, .sample, .deposit, .call, .copy_out => try work.append(em.arena, next),
            // A disable inside the block it names continues after it.
            .disable_block => |b| try work.appendSlice(em.arena, if (pc >= b.start and pc < b.end) &.{ next, b.end } else &.{next}),
            .disable_task => |idx| {
                try work.append(em.arena, next);
                for (r.routines.rows.items[idx].ranges.items) |rg| if (pc >= rg.start and pc < rg.end) try work.append(em.arena, rg.end);
            },
            // §10.2.3 the body is a process of its own (`timed`); its
            // `.task_return` jumps back to the call site, which then
            // continues past it.
            .call_timed => |c| {
                if (em.target == .device) return em.refuse("a §10.2.3 timed task that reaches itself");
                if (std.mem.findScalar(u32, em.timed.items, c.sub) == null) try em.timed.append(em.arena, c.sub);
                try work.append(em.arena, next);
            },
            .task_return => {},
            .pla_start => |p| try work.appendSlice(em.arena, &.{ next, p.at }),
            .fork => |f| try work.appendSlice(em.arena, if (f.arms.len == 0) &.{f.end} else r.program.wordsOf(f.arms)),
            .join_arm => |j| try work.append(em.arena, j.end),
            // §9.3 the held slot's own process, started by its `.override_on`.
            .override_on => |o| try work.appendSlice(em.arena, &.{ next, o.start }),
            .override_eval, .override_off => try work.append(em.arena, next),
            .switch_ctrl => {},
        }
    }
    std.mem.sort(u32, pcs.items, {}, std.sort.asc(u32));
    assert(pcs.items.len != 0);
    return pcs.items;
}

/// Writes `fn proc<entry>`: the process whose reachable pcs are `pcs`, with
/// `pcs[0]` its name. Sets `em.r`'s scope and pc to each instruction's.
pub fn process(em: *Emitter, pcs: []const u32) Error!void {
    const r = em.r;
    assert(pcs.len != 0);
    const head = em.out.written().len;
    // Every kernel call folds its widths at compile time, which Zig counts
    // against one quota per function.
    try em.print("fn proc{d}(s: *S, pc: u32) rt.Error!void {{\n    @setEvalBranchQuota(1 << 30);\n", .{pcs[0]});
    for (pcs) |pc| if (r.program.code.items[pc] == .restart) {
        try em.print("    var restarted = false;\n", .{});
        break;
    };
    const sw = em.out.written().len;
    try em.print("    switch (pc) {{\n", .{});
    for (pcs) |pc| {
        r.scope = r.program.scope_of.items[pc];
        r.pc = pc;
        try em.print("        {d} => {{\n", .{pc});
        if (em.site.in_sub) try em.print("            if (s.unwind != null) return;\n", .{});
        try instruction.instruction(em, pc);
        try em.print("        }},\n", .{});
    }
    try em.print("        else => unreachable,\n    }}\n}}\n\n", .{});
    // Zig refuses an unused label and an unused parameter, so each is
    // declared only when the body uses it.
    const text = em.out.written()[head..];
    if (std.mem.find(u8, text, "continue :sw") != null) try em.insert(sw + 4, "sw: ");
    if (!usesS(em.out.written()[head..])) try em.insert(sw, "    _ = s;\n");
    assert(em.out.written().len > head);
}

/// Returns whether a function's text uses its parameter `s`.
pub fn usesS(text: []const u8) bool {
    assert(text.len != 0);
    return std.mem.find(u8, text, "s.") != null or std.mem.find(u8, text, "(s,") != null;
}

/// Writes `fn none`, the `procs` table of every pc's function (`none` for a
/// pc no process reaches; under `auto` a `time0` entry is left out of the
/// 2-state phase) and `fn dispatch`, which runs a pc, a settle event or a
/// `show` site. With `activations`, a timed call or return continues in
/// another function at once: one after another, not nested on the stack.
pub fn dispatchTable(em: *Emitter, entry_of: []const ?u32, time0: []const bool, activations: bool, settles: bool) Error!void {
    assert(entry_of.len == time0.len);
    try em.print("fn none(_: *S, _: u32) rt.Error!void {{\n    unreachable;\n}}\n\n", .{});
    try em.print("const procs = [_]*const fn (*S, u32) rt.Error!void{{", .{});
    for (entry_of) |t| if (t) |lo| {
        if (time0[lo]) try em.print(" if (two) none else proc{d},", .{lo}) else try em.print(" proc{d},", .{lo});
    } else try em.print(" none,", .{});
    try em.print(" }};\n\n", .{});
    try em.print(
        \\pub fn dispatch(s: *S, pc: u32) rt.Error!void {{
        \\    if (pc < rt.show_base) {s}
        \\
    , .{if (entry_of.len == 0) "unreachable;" else if (activations)
        "{\n        try procs[pc](s, pc);\n        while (s.jump) |j| {\n            s.jump = null;\n            try procs[j](s, j);\n        }\n        return;\n    }"
    else
        "return procs[pc](s, pc);"});
    if (settles) try em.print("    if (pc == rt.settle_pc) return settle(s.view());\n", .{});
    try em.print("    return show(s, pc - rt.show_base);\n}}\n\n", .{});
}
