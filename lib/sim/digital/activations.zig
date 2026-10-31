//! A subroutine call in, its §10 activation out: the synchronous call of a function or untimed task run to its return, and the timed task activation whose caller resumes later; an automatic subroutine's frame set aside while another activation of it is resident (§10.2.3).
//! Cites: IEEE 1364-2005 §10.2.2, §10.2.3, §10.3, §10.4.2.
//!
//! Contents:
//! - `pub const Act = struct`
//! - `pub fn callSync(self: *Run, a: std.mem.Allocator, idx: u32, args: []const Ast.ExprId) Error!Int.Literal`
//! - `pub fn makeResident(self: *Run, ctx: u32) Error!void`
//! - `pub fn callTimed(self: *Run, a: std.mem.Allocator, idx: u32, args: []const Ast.ExprId, pc: u32) Error!u32`
//! - `pub fn returnTimed(self: *Run, a: std.mem.Allocator, idx: u32) Error!u32`

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const compile = @import("compile.zig");
const deep = @import("base").deep_stack;
const display = @import("display.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const Handle = @import("../scheduler.zig").Handle;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const wordMask = @import("net.zig").wordMask;
const Show = display.Show;
const Overrides = @import("root.zig").Overrides;
const Frame = @import("root.zig").Frame;
const PcRange = @import("root.zig").PcRange;
const Delay = @import("net.zig").Delay;
const Tran = @import("net.zig").Tran;
const system = @import("system.zig");
const vcd = @import("vcd.zig");
const evcd = @import("evcd.zig");
const driver = @import("driver.zig");
const evaluate = @import("evaluate.zig");
const resolution = @import("resolution.zig");
const waiters = @import("waiters.zig");
const exec = @import("exec.zig");
const Scratch = exec.Scratch;
const execute = exec.execute;

// ---- scheduler rows (§6.1.3, §17.1.2, §17.1.3) -------------------------------
/// `evaluate.address`: the element an lvalue names right now.
/// `waiters.store`: the one write path, which wakes what watches the slot.
/// `waiters.trigger`: §5.10.4 `-> e`.
/// `waiters.release`: §9.3 `deassign` or `release`.
/// `waiters.forceValue`: a VPI force of a constant.
/// One activation of a task that suspends and reaches itself: where its
/// caller resumes, the actuals its outputs copy back to, and its own storage,
/// saved while another activation of the same automatic task is resident.
pub const Act = struct { sub: u32, ret_pc: u32, ret_ctx: u32, args: []const Ast.ExprId, storage: []u64 = &.{} };

/// §10 a run's subroutine activations: §10.3 the disable unwinding synchronous
/// ones, the automatic frames set aside, and §10.2.3 the timed activations of
/// recursive tasks with their `fork` counters.
pub const Calls = struct {
    /// §10.3 a `disable` of a subroutine with synchronous activations in
    /// progress: every activation returns at once until the outermost one.
    unwind: ?u32 = null,
    /// The saved storage of the automatic activations in progress.
    saved: std.ArrayList(u64) = .empty,
    /// §10.2.3 the activations of recursive timed tasks: the one the
    /// executing process is in (0 for none), every one in progress, and the
    /// rows free for reuse.
    ctx: u32 = 0,
    acts: std.ArrayList(Act) = .empty,
    free: std.ArrayList(u32) = .empty,
    joins: std.AutoHashMapUnmanaged(struct { join: u32, ctx: u32 }, u32) = .empty,
};

/// Runs subroutine `idx` to completion as one activation (§10.2.2, §10.4) and
/// returns a function's result, in `a`. The arguments are evaluated in the
/// caller before anything of the callee's changes (a recursive call's argument
/// reads the calling activation), copied into the formals, the body runs on a
/// scratch arena of its own, and the outputs are copied back. An automatic
/// subroutine's frame is saved, set to x, and restored after (§10.2.3, §10.4.2).
/// Nests as deep as the stack `deep.runGuarded` reserved (`deep.exhausted`). After
/// a §10.3 `disable` of the subroutine, outputs are not copied back.
pub fn callSync(self: *Run, a: std.mem.Allocator, idx: u32, args: []const Ast.ExprId) Error!Int.Literal {
    // ponytail: `repeat` counters are per site, so a recursive body that loops
    // with `repeat` across its own recursion shares one.
    // §10.4.5: a constant function call folded before pass two compiles the
    // bodies (a generate condition calling a function already framed).
    if (!self.subs.items[idx].compiled) {
        const saved = self.scope;
        defer self.scope = saved;
        try compile.compileSub(self, idx);
    }
    const sub = &self.subs.items[idx];
    const decl = sub.decl;
    const f = sub.frame;
    // An activation's frames are large: the bound is the stack itself.
    if (deep.exhausted()) return self.deepFail(decl.main_tok);
    const inputs = try a.alloc(?Int.Literal, args.len);
    for (decl.ports, args, inputs, f.ports) |p, arg, *in, slot| {
        in.* = null;
        if (p.direction == .output) continue;
        // A copy: an actual that is the callee's own formal (`f(n)` inside
        // `f`) is that frame's storage, which the automatic reset below
        // overwrites.
        in.* = try copyLiteral(a, try evaluate.evalFor(self, a, arg, self.slotType(slot)));
    }
    const saved_len = self.calls.saved.items.len;
    // §10.4.5: a call elaboration folds "has no effect on the initial values
    // of the variables used either at simulation time or among multiple
    // invocations of a function at elaboration time", so it runs as an
    // automatic one does.
    const fresh = decl.automatic or self.growing != null or self.folding_constant;
    if (fresh) {
        for (f.first..f.first + f.count) |s| try self.calls.saved.appendSlice(self.arena, self.values[s].planes);
        try resetFrame(self, a, f);
    }
    for (inputs, f.ports) |in, slot| if (in) |v| @memcpy(self.values[slot].planes, v.planes);
    const caller_scope = self.scope;
    const caller_pc = self.pc;
    sub.active += 1;
    {
        var body = std.heap.ArenaAllocator.init(self.arena);
        defer body.deinit();
        var body_scratch: Scratch = .init(&.{}, &body);
        try execute(self, &body_scratch, sub.entry);
    }
    sub.active -= 1;
    self.scope = caller_scope;
    self.pc = caller_pc;
    const result = if (decl.is_function) try copyLiteral(a, self.values[f.result]) else try filled(a, 1, false, .x);
    // §10.2.2, §10.2.3: capture the callee's outputs before restoring the
    // caller's automatic frame. A recursive actual may name a local in
    // that frame, including a select whose index belongs to the caller.
    // Reuse the input copies, which are no longer needed after the body.
    // §10.3: a disabled task's outputs are not copied back.
    for (decl.ports, inputs, f.ports) |p, *out, slot|
        out.* = if (p.direction != .input and self.calls.unwind == null) try copyLiteral(a, self.values[slot]) else null;
    if (fresh) {
        loadFrame(self, f, self.calls.saved.items[saved_len..]);
        self.calls.saved.shrinkRetainingCapacity(saved_len);
    }
    for (args, inputs, f.ports) |arg, out, slot| if (out) |v|
        try evaluate.put(self, a, arg, try evaluate.convertValue(a, v, self.reals.contains(slot), try evaluate.targetType(self, arg)), false, null);
    if (self.calls.unwind == idx and sub.active == 0) self.calls.unwind = null;
    return result;
}

// ---- activations of a recursive timed task (IEEE 1364-2005 §10.2.3) ---------

/// Put activation `ctx`'s storage in its task's frame, if it is not there.
pub fn makeResident(self: *Run, ctx: u32) Error!void {
    if (ctx == 0) return;
    const act = self.calls.acts.items[ctx];
    const sub = &self.subs.items[act.sub];
    if (!sub.decl.automatic or sub.resident == ctx) return;
    try evict(self, act.sub);
    loadFrame(self, sub.body.?.frame, act.storage);
    sub.resident = ctx;
}

/// §10.2.2 enable task `idx` as a new activation: the inputs are evaluated in
/// the caller, an automatic task's frame is set aside for a fresh one
/// ("initialized to the default initialization value whenever execution
/// enters their scope"), and the body runs in this process from `Sub.body`.
/// Returns the pc to continue at.
pub fn callTimed(self: *Run, a: std.mem.Allocator, idx: u32, args: []const Ast.ExprId, pc: u32) Error!u32 {
    const sub = &self.subs.items[idx];
    const f = sub.body.?.frame;
    const inputs = try a.alloc(?Int.Literal, args.len);
    for (sub.decl.ports, args, inputs, f.ports) |p, arg, *in, slot|
        in.* = if (p.direction == .output) null else try copyLiteral(a, try evaluate.evalFor(self, a, arg, self.slotType(slot)));
    if (self.calls.acts.items.len == 0) try self.calls.acts.append(self.arena, undefined); // 0 is "no activation"
    const act: Act = .{ .sub = idx, .ret_pc = pc + 1, .ret_ctx = self.calls.ctx, .args = args };
    const id: u32 = if (self.calls.free.pop()) |k| blk: {
        self.calls.acts.items[k] = act;
        break :blk k;
    } else blk: {
        try self.calls.acts.append(self.arena, act);
        break :blk @intCast(self.calls.acts.items.len - 1);
    };
    if (sub.decl.automatic) {
        try evict(self, idx);
        try resetFrame(self, a, f);
        sub.resident = id;
    }
    for (inputs, f.ports) |in, slot| if (in) |v| @memcpy(self.values[slot].planes, v.planes);
    self.calls.ctx = id;
    return sub.body.?.entry;
}

/// The end of an activation's body: its outputs are read while its storage
/// is still resident, the caller's activation (if any) becomes resident, and
/// the outputs are copied to the caller's actuals in the caller's scope.
pub fn returnTimed(self: *Run, a: std.mem.Allocator, idx: u32) Error!u32 {
    const sub = &self.subs.items[idx];
    const f = sub.body.?.frame;
    const done = self.calls.ctx;
    const act = self.calls.acts.items[done];
    const outs = try a.alloc(Int.Literal, f.ports.len);
    for (f.ports, outs) |slot, *o| o.* = try copyLiteral(a, self.values[slot]);
    if (sub.resident == done) sub.resident = 0; // dead: nothing to save
    try self.calls.free.append(self.arena, done);
    self.calls.ctx = act.ret_ctx;
    try makeResident(self, self.calls.ctx);
    self.scope = self.code_scope.items[act.ret_pc - 1];
    for (sub.decl.ports, act.args, f.ports, outs) |p, arg, slot, v| if (p.direction != .input)
        try evaluate.put(self, a, arg, try evaluate.convertValue(a, v, self.reals.contains(slot), try evaluate.targetType(self, arg)), false, null);
    return act.ret_pc;
}

// ---- private ----

/// Save the resident activation of automatic task `idx`, freeing its frame.
fn evict(self: *Run, idx: u32) Error!void {
    const sub = &self.subs.items[idx];
    if (sub.resident == 0) return;
    const f = sub.body.?.frame;
    const act = &self.calls.acts.items[sub.resident];
    var len: usize = 0;
    for (f.first..f.first + f.count) |s| len += self.values[s].planes.len;
    if (act.storage.len != len) act.storage = try self.arena.alloc(u64, len);
    var at: usize = 0;
    for (f.first..f.first + f.count) |s| {
        const planes = self.values[s].planes;
        @memcpy(act.storage[at..][0..planes.len], planes);
        at += planes.len;
    }
    sub.resident = 0;
}

/// Copies `from`, frame `f`'s slots' planes laid end to end in slot order
/// (as `evict` and `callSync` save them), back into the slots.
fn loadFrame(self: *Run, f: Frame, from: []const u64) void {
    var at: usize = 0;
    for (f.first..f.first + f.count) |s| {
        const planes = self.values[s].planes;
        @memcpy(planes, from[at..][0..planes.len]);
        at += planes.len;
    }
}

/// Sets every slot of frame `f` to what entering its scope gives it
/// (§10.2.3): x, or 0.0 for a real. `filled` keeps the bits past the width
/// 0, as every slot's are; a whole-word memset would set them.
fn resetFrame(self: *Run, a: std.mem.Allocator, f: Frame) Error!void {
    for (f.first..f.first + f.count) |s| {
        const v = self.values[s];
        const fill: Int.Bit = if (self.reals.contains(@intCast(s))) .zero else .x;
        @memcpy(v.planes, (try filled(a, v.width, v.signed, fill)).planes);
    }
}

fn copyLiteral(a: std.mem.Allocator, v: Int.Literal) Error!Int.Literal {
    const out = try filled(a, v.width, v.signed, .zero);
    @memcpy(out.planes, v.planes);
    return out;
}

// ---- the interpreter loop (A.6.5, §6.1, §8.5.3.3) ---------------------------
