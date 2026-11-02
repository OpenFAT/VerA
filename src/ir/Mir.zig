//! MIR, the SSA IR lowering writes and every later stage reads: the tables,
//! their row types and handles, and the method table over the four files
//! that transform them (`mir_values.zig`, `mir_insts.zig`, `mir_blocks.zig`,
//! `mir_guards.zig`). §4.2 operators, §4.3 math and §5.8/§5.9 control flow
//! as blocks, phis and calls. Instructions, values and blocks are SoA
//! columns addressed by typed `enum(u32)` handles; tables grow by append, so
//! equal input gives equal indices. A Value index renumbers when the source
//! changes, so it must never reach an emitted name or a content hash
//! (`names.zig` canonicalizes).
//!
//! Cites: §2.7, §2.9, §3.2.2, §3.4, §4.2, §4.4, §4.5, §4.7, §5.8, §5.9;
//! IEEE 1364-2005 §19.1.
//!
//! Contents:
//! - `pub const opcode`, `pub const callee`, `pub const Callee`
//! - `pub const Opcode`, `pub const OpClass`, `pub const opClass`, `pub const opIsInteger`
//! - `pub const Inst = enum(u32)`, `pub const Value = enum(u32)` (`Value.first_dynamic`), `pub const Block = enum(u32)`, `pub const StrId`
//! - `pub const insts_max: u32`, `pub const values_max: u32`, `pub const blocks_max: u32`, `pub const extra_max: u32`
//! - `pub const no_tok: u32`, `pub const callee_bits`
//! - `pub const InstRow = struct`, `pub const BlockRow = struct`, `pub const ValueRow = struct`
//! - `pub const DefKind = enum(u8)`, `pub const Def = union(DefKind)`, `pub const InstData = union(OpClass)`
//! - `pub const PhiPair = struct`, `pub const GuardLit = struct` (`GuardLit.end`), `pub const InstIterator`, `pub const GuardIter`
//! - `pub fn deinit(mir: *Mir, gpa: Allocator) void`
//! - `pub fn reserve(mir: *Mir, gpa: Allocator, insts: u32, values: u32, extra: u32) Allocator.Error!void`
//! - values: `addFloatConst`, `addIntConst`, `addStrConst`, `addParamRef`, `addBlockParam`,
//!   `internString`, `valueDef`, `valueKind`, `valueCount`, `setAlias`, `hasAlias`, `resolveAlias`
//! - blocks: `addBlock`, `blockCount`, `blockInsts`, `blockLast`, `unlink`, `splice`, `moveTailBefore`
//! - instructions: `emit`, `emitAnew`, `emitAnewCached`, `emitBranch`, `emitJump`, `emitCall`,
//!   `emitPhi`, `setPhiPairs`, `addExtra`, `instCount`, `instRow`, `instTok`, `instOp`,
//!   `instBlock`, `instResult`, `instData`, `phiPair`, `phiIn`
//! - guards: `guardOf`, `guardConds`, `addGuardLit`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const base = @import("base");
const values_file = @import("mir_values.zig");
const insts_file = @import("mir_insts.zig");
const blocks_file = @import("mir_blocks.zig");
const guards = @import("mir_guards.zig");
/// The per-opcode fact table (class, type, domain, fold, ...).
pub const opcode = @import("opcode.zig");
/// What a `call` calls, and the per-callee fact table.
pub const callee = @import("callee.zig");

/// The lowered module's name. Borrowed: the Mir does not own it.
name: []const u8 = "",
/// IEEE 1364 §19.1 (via §10.1): the module was declared inside a
/// `` `celldefine ``/`` `endcelldefine `` pair. A tag only; nothing branches on
/// it. It carries the fact past the preprocessor for tools that ask. For any
/// other module, ask `directive_events.CellRegion.inForce`.
is_cell: bool = false,
/// Provenance cursor: the builder sets it to the token of the AST node being
/// lowered, and every appended instruction row is stamped with it. A cursor
/// rather than an `emit` parameter because lowering emits from hundreds of
/// sites but visits AST nodes from a handful.
cur_tok: u32 = no_tok,
/// Instruction rows, indexed by `Inst`.
insts: std.MultiArrayList(InstRow) = .empty,
/// Block rows, indexed by `Block`.
blocks: std.MultiArrayList(BlockRow) = .empty,
/// Definition of every dynamic Value; row = @backingInt(v) - first_dynamic.
defs: std.MultiArrayList(ValueRow) = .empty,
/// The bits of every dynamic real and integer constant, indexed by the
/// `payload` of its `defs` row. A wide literal lives here, not in the row,
/// so a `defs` row is 5 bytes instead of 9.
consts: std.ArrayList(u64) = .empty,
/// Shared variable-length payload pool (call args, phi operands, the third
/// operand of a ternary or store, branch targets).
extra: std.ArrayList(u32) = .empty,
/// String table (`base`'s interner, as the AST's). Slices are not copied: they must
/// outlive the Mir.
strings: base.StringInterner = .empty,
/// Real constant dedup, keyed by exact bits so -0.0 / 0.0 stay distinct and
/// NaN payloads survive. Lookup only: iteration order is not deterministic.
fconst_map: std.AutoHashMapUnmanaged(u64, Value) = .empty,
/// Integer constant dedup. Lookup only.
iconst_map: std.AutoHashMapUnmanaged(i64, Value) = .empty,
/// Trivial-phi aliases (`analog/ssa.zig` `tryRemoveTrivialPhi`). Union-find
/// parent array parallel to `defs` (row = value - first_dynamic); an entry
/// equal to its own Value means "no alias". Only collapsed phis point
/// elsewhere, so codegen never emits a decl for them.
alias: std.ArrayList(Value) = .empty,
/// §4.2.12/§4.3.2 the speculation guards `prove/ifconv.zig`'s `.speculate`
/// pass writes: a domain-restricted row (`opcode.Info.domain != .all`) it
/// moved out of a branch arm ran in the source only while every literal of
/// its chain held, so codegen evaluates it on a safe argument otherwise.
/// Row → first literal of its chain in `guard_lits`. Lookup only.
guard_of: std.AutoHashMapUnmanaged(Inst, u32) = .empty,
/// The literal pool `guard_of` indexes. A chain is one conversion per arm
/// level, outermost first; `GuardLit.end` closes it.
guard_lits: std.ArrayList(GuardLit) = .empty,

/// What a `call` calls (`callee.Callee`).
pub const Callee = callee.Callee;
/// The opcode set (`opcode.Opcode`).
pub const Opcode = opcode.Opcode;
/// Operand shape of an opcode (`opcode.OpClass`).
pub const OpClass = opcode.OpClass;
/// Returns the operand shape of an opcode (`opcode.class`).
pub const opClass = opcode.class;
/// Returns whether an opcode yields a §3.2 integer (`opcode.isInteger`).
pub const opIsInteger = opcode.isInteger;

/// Handle to an instruction row; `.none` ends a block's `next` chain.
pub const Inst = enum(u32) { none = std.math.maxInt(u32), _ };
/// Handle to an SSA value. Indices below `first_dynamic` are shared constants
/// with no `defs` row.
pub const Value = enum(u32) {
    // Reserved sentinels 0..9 (common constants); dynamic values from 10+.
    undef = 0,
    f_zero,
    f_one,
    f_neg_one,
    f_two,
    f_ten,
    f_inf,
    zero,
    one,
    neg_one,
    _,

    /// First dynamic Value index. Values below this are the sentinels above and
    /// have no row in the `defs` side table.
    pub const first_dynamic: u32 = 10;
};
/// Handle to a basic block; block 0 is the entry.
pub const Block = enum(u32) { entry = 0, _ };
/// Interned string handle (call names, §4.4 access names, ch9 arguments). The
/// AST's type (`base`'s), but it indexes this Mir's `strings` table, not the AST's.
/// `.none` is the absent sentinel.
pub const StrId = base.StrId;

/// Most instruction rows one Mir holds: `Inst.none` is the next index.
/// Reaching it takes more memory than any host has (25 bytes a row), so it
/// is asserted, not returned.
pub const insts_max: u32 = std.math.maxInt(u32) - 1;
/// Most dynamic Values one Mir holds: the handle space above the sentinels.
pub const values_max: u32 = std.math.maxInt(u32) - Value.first_dynamic;
/// Most blocks one Mir holds.
pub const blocks_max: u32 = std.math.maxInt(u32);
/// Most words the `extra` pool holds: every offset into it is a `u32`.
pub const extra_max: u32 = std.math.maxInt(u32);

/// "This instruction has no AST origin", such as a constant the SSA builder
/// materialised. Not 0, because token 0 is the first real token of the file.
pub const no_tok: u32 = std.math.maxInt(u32);

/// One instruction row, 25 bytes across its SoA columns. Two operand words
/// `a`/`b` hold Value/Block/StrId handles; a class with a third operand keeps
/// its last two in `extra` at `b`, so the common unary/binary/phi row carries
/// no dead word. `result` is the produced Value; `next` links within a block.
///
/// Operand encoding per class (see `instData` for the decoded view):
///   unary   a = operand
///   binary  a = lhs, b = rhs
///   ternary a = cond, b = extra start (then value, else value)   (§4.2.12)
///   phi     a = pair count, b = extra start (2 u32 per pair: block, value)
///   branch  a = cond, b = extra start (then Block, else Block)   (§5.8)
///   jump    a = target Block                                     (§5.9)
///   call    a = Callee | arg count << `callee_bits`, b = extra start (the
///           raw name's StrId, then the args)
///   anew    a = array id (`Lowered.mem_arrays` index)                (§3.2.2)
///           b = 0, or 1 + extra start (the `Lowered.timepoints` row whose
///           cache fills it, then that row's slot; VerA's `vera_timepoint`, §2.9)
///   load    a = array version, b = flat index
///   store   a = array version, b = extra start (flat index, value)
pub const InstRow = struct {
    op: Opcode,
    a: u32 = 0,
    b: u32 = 0,
    result: Value = .undef,
    next: Inst = .none,
    /// The block whose `next` chain links this row. Never set by a caller:
    /// the builders stamp it and every relink restamps it.
    block: Block = .entry,
    /// Index of the token this instruction came from, for diagnostics, or
    /// `no_tok`. Never set by a caller: the builders stamp it from `cur_tok`.
    /// A cold column; `instData` does not read it.
    tok: u32 = no_tok,
};

/// Width of a call row's `Callee` field in `a`; the arg count sits above it.
pub const callee_bits = @bitSizeOf(Callee);

/// First and last instruction of a block's `next` chain; `.none` when empty.
/// Invariant: both are `.none` or neither is.
pub const BlockRow = struct { first: Inst = .none, last: Inst = .none };

/// How a Value came to be.
pub const DefKind = enum(u8) {
    undef,
    float_const, // §4.2 constant expression, real
    int_const, // §4.2 constant expression, integer
    str_const, // §2.7 string literal (ch9 format args, §4.4 names)
    param_ref, // §3.4 parameter: index into Lowered.params
    block_param, // §4.4 probe: index into the unknown vector (Lowered.nodes)
    inst_result, // result of an instruction
};

/// Decoded definition of a Value (see `valueDef`). Built on read, never stored.
pub const Def = union(DefKind) {
    undef,
    float_const: f64,
    int_const: i64,
    str_const: []const u8,
    param_ref: u32,
    block_param: u32,
    inst_result: Inst,
};

/// SoA row of the value-definition side table, 5 bytes. `payload` is
/// kind-dependent: a `consts` index (real and integer constants), a StrId, a
/// `Lowered.params` index, a `Lowered.nodes` index or an Inst.
pub const ValueRow = struct { kind: DefKind, payload: u32 };

/// Decoded instruction view. Built on demand; never stored (see InstRow).
pub const InstData = union(OpClass) {
    unary: struct { op: Opcode, operand: Value },
    binary: struct { op: Opcode, lhs: Value, rhs: Value },
    ternary: struct { cond: Value, then_val: Value, else_val: Value },
    phi: struct { start: u32, count: u32 },
    branch: struct { cond: Value, then_block: Block, else_block: Block },
    jump: struct { target: Block },
    /// `name` is the spelling the call was emitted with: `@tagName(callee)`,
    /// except for `.systf`, whose name only this carries.
    call: struct { callee: Callee, name: []const u8, args: []const Value },
    /// `tp`: null for a zero or held start; else the `vera_timepoint` cache
    /// slot it starts from (`Lowered.TpBlock`).
    anew: struct { array: u32, tp: ?struct { block: u32, slot: u32 } = null },
    load: struct { op: Opcode, arr: Value, index: Value },
    store: struct { arr: Value, index: Value, value: Value },
};

/// One phi operand: the value flowing in from predecessor `block`.
pub const PhiPair = struct { block: Block, value: Value };

/// One literal of a speculation guard: `cond` was nonzero (`taken`) or zero
/// on the arm the guarded row came from. 12 bytes; at most one per guarded
/// row per conversion that moved it.
pub const GuardLit = struct {
    cond: Value,
    taken: bool,
    /// The next literal of the chain, or `end`.
    next: u32,

    /// Closes a chain.
    pub const end = std.math.maxInt(u32);
};

/// Iterator over one block's instruction chain (`mir_blocks.InstIterator`).
pub const InstIterator = blocks_file.InstIterator;
/// Iterator over one guard chain's conditions (`mir_guards.GuardIter`).
pub const GuardIter = guards.GuardIter;

// Row budgets, in bytes per row of each SoA table (psp103: 27,760
// instructions, 23,859 values, 4,234 blocks). A new column has to move one of
// these on purpose.
comptime {
    assert(std.MultiArrayList(InstRow).capacityInBytes(1) == 25);
    assert(std.MultiArrayList(ValueRow).capacityInBytes(1) == 5);
    assert(std.MultiArrayList(BlockRow).capacityInBytes(1) == 8);
    assert(@sizeOf(PhiPair) == 8); // two `extra` words
    assert(@sizeOf(GuardLit) == 12);
    assert(callee_bits + 24 == 32); // a call's arg count gets the top 24 bits
    assert(insts_max == @backingInt(Inst.none) - 1);
    assert(GuardLit.end == std.math.maxInt(u32));
}

// Values (`mir_values.zig`).
/// Returns the §4.2 real constant, deduped; common literals are sentinels.
pub const addFloatConst = values_file.addFloatConst;
/// Returns the §4.2 integer constant, deduped; 0, 1 and -1 are sentinels.
pub const addIntConst = values_file.addIntConst;
/// Returns a §2.7 string literal Value.
pub const addStrConst = values_file.addStrConst;
/// Returns a §3.4 parameter reference Value.
pub const addParamRef = values_file.addParamRef;
/// Returns a §4.4 signal-access probe Value.
pub const addBlockParam = values_file.addBlockParam;
/// Interns a name into this Mir's string table.
pub const internString = values_file.internString;
/// Returns the decoded definition of a Value.
pub const valueDef = values_file.valueDef;
/// Returns the kind of a Value without decoding its payload.
pub const valueKind = values_file.valueKind;
/// Returns the size of the Value handle space: sentinels plus `defs` rows.
pub const valueCount = values_file.valueCount;
/// Records a trivial-phi alias.
pub const setAlias = values_file.setAlias;
/// Returns whether a Value was collapsed onto another.
pub const hasAlias = values_file.hasAlias;
/// Returns the Value at the end of an alias chain.
pub const resolveAlias = values_file.resolveAlias;

// Blocks (`mir_blocks.zig`).
/// Appends an empty block.
pub const addBlock = blocks_file.addBlock;
/// Returns the number of blocks.
pub const blockCount = blocks_file.blockCount;
/// Returns an iterator over a block's instructions, in chain order.
pub const blockInsts = blocks_file.blockInsts;
/// Returns the last instruction of a block, or `.none`.
pub const blockLast = blocks_file.blockLast;
/// Removes one instruction from a block's chain.
pub const unlink = blocks_file.unlink;
/// Relinks every row of one block at the end of another.
pub const splice = blocks_file.splice;
/// Moves a block's tail in front of another block's terminator.
pub const moveTailBefore = blocks_file.moveTailBefore;

// Instructions (`mir_insts.zig`).
/// Appends a value-producing instruction of a fixed-operand class.
pub const emit = insts_file.emit;
/// Appends a fresh version of a §3.2.2 array.
pub const emitAnew = insts_file.emitAnew;
/// Appends a version of an array filled from a `vera_timepoint` cache slot.
pub const emitAnewCached = insts_file.emitAnewCached;
/// Appends a §5.8 two-way branch.
pub const emitBranch = insts_file.emitBranch;
/// Appends a §5.9 unconditional jump.
pub const emitJump = insts_file.emitJump;
/// Appends a call by name.
pub const emitCall = insts_file.emitCall;
/// Appends a phi.
pub const emitPhi = insts_file.emitPhi;
/// Replaces a phi's operand list.
pub const setPhiPairs = insts_file.setPhiPairs;
/// Appends raw words to the `extra` pool.
pub const addExtra = insts_file.addExtra;
/// Returns the number of instruction rows.
pub const instCount = insts_file.instCount;
/// Returns every column of an instruction row.
pub const instRow = insts_file.instRow;
/// Returns the token an instruction was lowered from.
pub const instTok = insts_file.instTok;
/// Returns an instruction's opcode.
pub const instOp = insts_file.instOp;
/// Returns the block an instruction is linked into.
pub const instBlock = insts_file.instBlock;
/// Returns the Value an instruction defines.
pub const instResult = insts_file.instResult;
/// Returns the decoded view of an instruction.
pub const instData = insts_file.instData;
/// Returns one operand pair of a phi.
pub const phiPair = insts_file.phiPair;
/// Returns a phi's incoming value on one edge.
pub const phiIn = insts_file.phiIn;

// Speculation guards (`mir_guards.zig`).
/// Returns the first literal of an instruction's guard, or null.
pub const guardOf = guards.guardOf;
/// Returns an iterator over the conditions an instruction's guard reads.
pub const guardConds = guards.guardConds;
/// Prepends a literal to an instruction's guard.
pub const addGuardLit = guards.addGuardLit;

const Mir = @This();

/// Frees every table. Keeps `name`, which the Mir does not own.
/// Invalidates every handle, slice and iterator taken from the Mir.
pub fn deinit(mir: *Mir, gpa: Allocator) void {
    const name = mir.name;
    mir.insts.deinit(gpa);
    mir.blocks.deinit(gpa);
    mir.defs.deinit(gpa);
    mir.consts.deinit(gpa);
    mir.extra.deinit(gpa);
    mir.strings.deinit(gpa);
    mir.fconst_map.deinit(gpa);
    mir.iconst_map.deinit(gpa);
    mir.alias.deinit(gpa);
    mir.guard_of.deinit(gpa);
    mir.guard_lits.deinit(gpa);
    mir.* = .{ .name = name };
    assert(mir.insts.len == 0);
    assert(mir.defs.len == 0);
}

/// Gives the instruction, value and extra tables room for at least `insts`,
/// `values` and `extra` rows, so a builder that knows its size up front
/// grows each table once. A count below the current capacity does nothing.
/// Why it pays: `insts` and `defs` are MultiArrayLists, and each regrowth
/// copies every column into a fresh block while the old one is still
/// mapped. Invalidates pointers into the tables (`instData` slices).
/// On error the tables already grown stay grown; no row is added.
pub fn reserve(mir: *Mir, gpa: Allocator, insts: u32, values: u32, extra: u32) Allocator.Error!void {
    assert(insts <= insts_max);
    assert(values <= values_max);
    if (insts > mir.insts.capacity) try mir.insts.setCapacity(gpa, insts);
    if (values > mir.defs.capacity) try mir.defs.setCapacity(gpa, values);
    try mir.alias.ensureTotalCapacityPrecise(gpa, values);
    try mir.extra.ensureTotalCapacityPrecise(gpa, extra);
    assert(mir.insts.capacity >= insts);
    assert(mir.defs.capacity >= values);
}

test reserve {
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);
    try mir.reserve(gpa, 10, 20, 30);
    try std.testing.expect(mir.insts.capacity >= 10);
    try std.testing.expect(mir.defs.capacity >= 20);
    try std.testing.expect(mir.alias.capacity >= 20);
    try std.testing.expect(mir.extra.capacity >= 30);
    // A smaller request keeps what is there.
    const cap = mir.insts.capacity;
    try mir.reserve(gpa, 1, 1, 1);
    try std.testing.expectEqual(cap, mir.insts.capacity);
}

test deinit {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "kept" };
    _ = try mir.addFloatConst(gpa, 3.5);
    _ = try mir.addBlock(gpa);
    mir.deinit(gpa);
    try std.testing.expectEqualStrings("kept", mir.name);
    try std.testing.expectEqual(@as(u32, 0), mir.blockCount());
    try std.testing.expectEqual(@as(usize, 0), mir.defs.len);
    try std.testing.expectEqual(@as(usize, 0), mir.consts.items.len);
}

test {
    _ = values_file;
    _ = insts_file;
    _ = blocks_file;
    _ = guards;
}
