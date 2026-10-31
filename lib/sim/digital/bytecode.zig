//! The interpreter's bytecode: one `Instruction` row per step of a process, and the expression `Type` every row and slot carries.
//! Cites: IEEE 1364-2005 §4.8.1, §5.5.1, §9 (the statements the rows encode).
//!
//! Contents:
//! - `pub const Type = struct`
//! - `pub const real_type: Type`
//! - `pub const ExprList = struct`
//! - `ExprList.empty: ExprList`
//! - `pub const WordList = struct`
//! - `WordList.empty: WordList`
//! - `pub const Instruction = union`
//! - `pub const Program = struct`
//! - `Program.exprs(p: *const Program, list: ExprList) []const Ast.ExprId`
//! - `Program.wordsOf(p: *const Program, list: WordList) []const u32`
//! - `Program.addExprs(p: *Program, gpa: std.mem.Allocator, items: []const Ast.ExprId) std.mem.Allocator.Error!ExprList`
//! - `Program.addWords(p: *Program, gpa: std.mem.Allocator, items: []const u32) std.mem.Allocator.Error!WordList`

const std = @import("std");
const assert = std.debug.assert;
const Name = @import("root.zig").Name;
const Front = @import("frontend");
const Ast = Front.Ast;
const exec = @import("exec.zig");
const evaluate = @import("evaluate.zig");
const deep = @import("base").deep_stack;
const display = @import("display.zig");
const driver = @import("driver.zig");
const system = @import("system.zig");
const elab = @import("elab.zig");
const evcd = @import("evcd.zig");
const vcd = @import("vcd.zig");
const root = @import("root.zig");
const Error = root.Error;
const Run = root.Run;
const SpecExpr = root.SpecExpr;
const expectRun = root.expectRun;
const expectRejected = root.expectRejected;
const filled = @import("net.zig").filled;
const compile_holds = @import("compile_holds.zig");
const Bits = compile_holds.Bits;
const Slice = compile_holds.Slice;

/// An expression's type (§5.5.1): a width and a signedness, or IEEE 1364-2005
/// §4.8's `real`, a double held in a slot as its 64 bits.
pub const Type = struct { width: u32, signed: bool, real: bool = false };

/// §4.8 `real`: 64 bits, signed, `real` set. The one real type there is.
pub const real_type: Type = .{ .width = 64, .signed = true, .real = true };

/// A run of `Program.operands`: the arguments of a task or subroutine call,
/// stored beside the rows so an `Instruction` carries 8 bytes, not a slice.
pub const ExprList = struct {
    start: u32,
    len: u32,

    /// No arguments.
    pub const empty: ExprList = .{ .start = 0, .len = 0 };
};

/// A run of `Program.words`: the slots a wait re-tests on, or a `fork`'s arm pcs.
pub const WordList = struct {
    start: u32,
    len: u32,

    /// No words.
    pub const empty: WordList = .{ .start = 0, .len = 0 };
};

/// One bytecode row, consumed whole by one dispatch; expressions stay in the
/// AST. Each statement kind is decided here, so `exec.execute` is one switch
/// and never goes back to the statement.
pub const Instruction = union(enum(u5)) {
    /// A.6.2 a blocking or nonblocking assignment with no intra-assignment
    /// timing control (those are `sample`/`deposit`).
    assign: struct { target: Ast.ExprId, value: Ast.ExprId, nonblocking: bool },
    /// §9.7.1 `#d stmt`: suspend for the delay, resume at the next pc.
    delay: struct { amount: Ast.ExprId, tok: u32 },
    /// One §17 system task, resolved against `display.tasks` at compile time.
    task: struct { task: display.Task, args: ExprList, tok: u32 },
    /// §6.1 continuous assignment `n`: evaluate, drive, resolve, then suspend
    /// on its own operands, resuming at its own pc.
    continuous: u32,
    /// §9.4 continue at the next pc when `condition` is true, else at
    /// `otherwise`; x and z are false.
    branch: struct { condition: Ast.ExprId, otherwise: u32 },
    /// Continue at this pc.
    jump: u32,
    /// §9.5 the first arm whose label matches `statement`'s scrutinee, both in
    /// `ty`, continues at `Run.case_targets[targets + arm]`; no match continues
    /// at `fallback` (the `default` arm, or past the statement).
    case_select: struct { statement: Ast.StmtId, targets: u32, fallback: u32, ty: Type },
    /// A count of x, z or below 0 runs nothing, at any width; past 64 bits
    /// it saturates (`exec`, `rt.repeatCount`).
    repeat_start: struct { count: Ast.ExprId, counter: u32, end: u32 },
    /// The end of a `repeat` body: one count spent from `Run.repeats[counter]`;
    /// while some remain, the body runs again from `body`.
    repeat_next: struct { counter: u32, body: u32 },
    /// §5.10.1 suspend until one watched variable takes a matching edge.
    wait_event: Ast.ExprId,
    /// A.6.5 `@*`: §9.7.5's implicit list, resolved to slots at compile time.
    /// A resumption is the same `.any` waiter `@(a or b)` installs.
    wait_slots: WordList,
    /// A.6.5 `wait_statement`, level sensitive: `cond` is tested on arrival
    /// and on every resumption, and only a true reading falls through.
    /// `slots` (its operands) says when to re-test.
    wait_level: struct { cond: Ast.ExprId, slots: WordList },
    /// §8.5.3.3 the first half of an intra-assignment timing control: the
    /// right-hand side, evaluated when the statement is reached, is parked in
    /// `cell`, then the timing applies. A nonblocking one schedules its write
    /// here, does not suspend, and has no `deposit`.
    sample: struct { statement: Ast.StmtId, cell: u32 },
    /// The second half: on resumption the target is resolved ("the values at
    /// the time the process resumes are used to determine the target(s)") and
    /// the parked value written.
    deposit: struct { statement: Ast.StmtId, cell: u32 },
    /// A.6.5 `-> named_event`. §5.10 events "do not hold any data", so this
    /// stores nothing: it resumes whoever waits on the slot now, and a
    /// trigger nobody waits for is gone.
    trigger: union(enum) { slot: u32, indexed: Ast.ExprId },
    /// §9.9.2 an `always` body returning to its own start.
    restart: struct { target: u32, tok: u32 },
    /// A.6.5 `disable` of a named block, whose activity is its pc range
    /// [start, end): terminating it drops every resumption into that range.
    /// Patched in after every process is compiled, since a `disable` may
    /// name a block written later.
    disable_block: struct { start: u32, end: u32 },
    /// §6.2.1 a variable declaration assignment: one blocking write of a
    /// whole declared variable, which has a slot and no expression naming it.
    init_var: struct { slot: u32, value: Ast.ExprId },
    /// §10.2.2 a task enable or function call run to completion in place:
    /// copy in, the body at `Sub.entry`, copy out.
    call: struct { sub: u32, args: ExprList, tok: u32 },
    /// §10.2.2 an inlined enable's copy-out: formal `slot` is assigned to
    /// the caller's lvalue `target`, resolved in the caller's scope.
    copy_out: struct { target: Ast.ExprId, slot: u32 },
    /// §10.3 `disable` naming a task: every activation of it ends.
    disable_task: u32,
    /// §10.2.3 enable of a task that suspends and reaches itself: a new
    /// activation of its out-of-line body (`Sub.body`).
    call_timed: struct { sub: u32, args: ExprList },
    /// The end of a `call_timed` activation of task `n`.
    task_return: u32,
    /// Start a process of its own at `at`: §17.5 an asynchronous PLA's, or
    /// §9.7.7 the wait of a nonblocking assignment's event control, which
    /// (`now`) runs at once, up to its wait: "the right-hand expressions are
    /// evaluated when the assignment statements are encountered, but the
    /// assignments are delayed until" the event, so an event the parent
    /// triggers next is one it sees.
    pla_start: struct { at: u32, now: bool = false },
    /// §9.8.2 `fork`: start every arm as a process of its own; join cell
    /// `join` counts them back, and the parent resumes at `end`.
    fork: struct { arms: WordList, join: u32, end: u32 },
    /// One `fork` arm finished; the last one resumes the parent at `end`.
    join_arm: struct { join: u32, end: u32 },
    /// §9.3 install a procedural continuous assignment on `slot`: its
    /// out-of-line process [start, end) keeps the slot equal to its expression.
    /// `bits`: §9.3.2's constant select of a vector net, which the override
    /// holds alone (`override_eval` and `override_off` alike).
    override_on: struct { slot: u32, force: bool, start: u32, end: u32, bits: Bits = .none },
    /// That process's one step: write `value` into `slot` past the guard.
    /// An operand of a §9.3 concatenation target takes bits [lo, lo + its
    /// width) of the value evaluated `of` bits wide.
    override_eval: struct { slot: u32, value: Ast.ExprId, force: bool, slice: Slice = .none, bits: Bits = .none },
    /// §9.3 `deassign` / `release`.
    override_off: struct { slot: u32, force: bool, bits: Bits = .none },
    /// §7.6 a controlled pass switch: read the control, re-resolve both
    /// sides, and wait on the control's operands.
    switch_ctrl: struct { tran: u32, slots: WordList },
    /// The end of a process, a subroutine body or an out-of-line helper.
    stop,

    // Budget: one row per pc, read by every dispatch of `exec.execute`.
    // Lists live in `Program.operands`/`Program.words`, so no payload holds
    // a slice; the largest is `override_eval`'s optional select pair.
    comptime {
        std.debug.assert(@sizeOf(ExprList) == 8);
        std.debug.assert(@sizeOf(Instruction) == 32);
    }
};

/// A design's compiled processes: the `Instruction` rows, the scope each was
/// compiled in, the jump tables of `case` and `disable`, the named blocks'
/// pc ranges, and the processes §9.9 starts first at time 0.
pub const Program = struct {
    /// The always constructs `processes` starts first at time 0
    /// (`levelControlled`), in source order, by the pc each starts at.
    early: std.ArrayList(u32) = .empty,
    code: std.ArrayList(Instruction) = .empty,
    /// The instance scope each instruction was compiled in, one row per `code`
    /// row. A process never leaves the scope it was written in, so `execute`
    /// reads this once per dispatch, an event resumption included, which
    /// re-enters at a pc in the middle of a body.
    scope_of: std.ArrayList(u32) = .empty,
    case_targets: std.ArrayList(u32) = .empty,
    /// §5.3.2 the pc range of each named sequential block, keyed per §6.2.2
    /// instance like every other declared name, so two instances of one
    /// definition disable their own copy and not each other's.
    /// `depth` is the block's statement nesting, which orders two named
    /// blocks with the same range (`begin : a begin : b ... end end`) for `%m`.
    blocks: std.AutoHashMapUnmanaged(Name, struct { start: u32, end: u32, depth: u32 }) = .empty,
    /// The `.disable_block` instructions still waiting for their range, and the
    /// name each one is waiting for. A.6.5 puts no ordering rule on a
    /// `disable`: the block it names is routinely in ANOTHER process, which may
    /// not be compiled yet, so the lookup is deferred to one pass at the end
    /// rather than failing in the middle of a dispatch.
    disables: std.ArrayList(struct { at: u32, name: Name, tok: u32 }) = .empty,
    /// The argument lists the rows name by `ExprList`.
    operands: std.ArrayList(Ast.ExprId) = .empty,
    /// The slot and pc lists the rows name by `WordList`.
    words: std.ArrayList(u32) = .empty,

    /// Returns the expressions `list` names. Valid until the next `addExprs`.
    pub fn exprs(p: *const Program, list: ExprList) []const Ast.ExprId {
        assert(list.start + list.len <= p.operands.items.len);
        return p.operands.items[list.start..][0..list.len];
    }

    /// Returns the words `list` names. Valid until the next `addWords`.
    pub fn wordsOf(p: *const Program, list: WordList) []const u32 {
        assert(list.start + list.len <= p.words.items.len);
        return p.words.items[list.start..][0..list.len];
    }

    /// Appends `items` and returns the list naming them.
    /// Invalidates slices `exprs` returned if more memory is needed.
    pub fn addExprs(p: *Program, gpa: std.mem.Allocator, items: []const Ast.ExprId) std.mem.Allocator.Error!ExprList {
        assert(p.operands.items.len + items.len <= std.math.maxInt(u32));
        const start: u32 = @intCast(p.operands.items.len);
        try p.operands.appendSlice(gpa, items);
        const list: ExprList = .{ .start = start, .len = @intCast(items.len) };
        assert(std.mem.eql(Ast.ExprId, p.exprs(list), items));
        return list;
    }

    /// Appends `items` and returns the list naming them.
    /// Invalidates slices `wordsOf` returned if more memory is needed.
    pub fn addWords(p: *Program, gpa: std.mem.Allocator, items: []const u32) std.mem.Allocator.Error!WordList {
        assert(p.words.items.len + items.len <= std.math.maxInt(u32));
        const start: u32 = @intCast(p.words.items.len);
        try p.words.appendSlice(gpa, items);
        const list: WordList = .{ .start = start, .len = @intCast(items.len) };
        assert(std.mem.eql(u32, p.wordsOf(list), items));
        return list;
    }
};
