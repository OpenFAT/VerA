//! MIR, the SSA IR lowering writes and every later stage reads: §4.2
//! operators, §4.3 math, §5.8/§5.9 control flow as blocks, phis and calls.
//! Instructions, values and blocks are SoA columns addressed by typed
//! `enum(u32)` handles; tables grow by append, so equal input gives equal
//! indices. A Value index renumbers when the source changes, so it must never
//! reach an emitted name or a content hash (names.zig canonicalizes).
//!
//! LRM clauses this file's code cites: §2.7, §2.9, §3.2, §3.2.2, §3.4,
//! §4.2.1.1, §4.2.1.2, §4.2.1.3, §4.2.3, §4.2.4, §4.2.5, §4.2.7, §4.2.8, §4.2.9, §4.2.10, §4.2.11,
//! §4.2.12, §4.3.1, §4.3.2, §4.4, §4.5, §4.7, §5.6.1.2, §5.10, §10.1.
//! IEEE 1364-2005 clauses cited: §5.1.5, §19.1.

const std = @import("std");
const base = @import("base");
const assert = std.debug.assert;
/// The per-opcode fact table (class, type, domain, …).
pub const opcode = @import("opcode.zig");
/// What a `call` calls, and the per-callee fact table.
pub const callee = @import("callee.zig");
/// What a `call` calls (`callee.Callee`).
pub const Callee = callee.Callee;

const Mir = @This();

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

/// Opcode set: §4.2 arithmetic, relational, logical, bitwise and shift
/// operators, §4.3 math, casts. Every opcode has a row of facts in
/// `opcode.zig`. Naming: a leading `f` is the real-valued form, a leading `i` the
/// integer form. Math functions (§4.3) are always real-valued and carry the
/// bare LRM name.
pub const Opcode = enum(u8) {
    // --- arithmetic §4.2.4 (+ unary §4.2.3, modulus §4.2.4) ---
    fadd,
    fsub,
    fmul,
    fdiv,
    fmod,
    fneg,
    iadd,
    isub,
    imul,
    idiv,
    imod,
    ineg,
    // --- relational §4.2.5 / equality §4.2.7 (yield integer 0/1) ---
    flt,
    fgt,
    fle,
    fge,
    feq,
    fne,
    ilt,
    igt,
    ile,
    ige,
    ieq,
    ine,
    // --- logical §4.2.8 (integer 0/1 result) ---
    logand,
    logor,
    lognot,
    // --- bitwise §4.2.9 (integer only; reduction §4.2.10 is digital-only) ---
    bitand,
    bitor,
    bitxor,
    bitxnor,
    bitnot,
    // --- shifts §4.2.11 (logical << >> only; <<< >>> are illegal in analog) ---
    shl,
    shr,
    // --- standard math, LRM Table 4-14 §4.3.1 ---
    sqrt,
    exp,
    expm1,
    ln,
    ln1p,
    log10,
    pow,
    hypot,
    floor,
    ceil,
    fabs,
    fmin,
    fmax, // real forms
    iabs,
    imin,
    imax, // integer forms (§4.3.1: int operands ⇒ int result)
    /// §4.2.1.3 `**` over two integers: integer, not §4.3.1's real `pow`.
    /// IEEE 1364-2005 §5.1.5 Table 5-6 at §3.2's 32-bit width; `kernels.fold.ipow32`
    /// is the definition.
    ipow,
    // --- trigonometric + hyperbolic, LRM Table 4-15 §4.3.2 ---
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    atan2,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,
    // --- casts §4.2.1.1 (real→integer, rounds) / §4.2.1.2 (integer→real) ---
    fi_cast,
    if_cast,
    /// Optimization fence (engine-internal): stops codegen from folding or
    /// reassociating across it. Unary, value-preserving.
    opt_barrier,
    /// Derivative stop (no LRM basis; VerA's `vera_nodiff` attribute, §2.9):
    /// the operand's value with every derivative lane zero. So its `deps` is
    /// empty although the value still varies with x (`Analysis.xDep`).
    dstop,
    /// Committed-value latch (engine-internal): reads the Instance field
    /// `pb__<k>`, the operand's value at the last accepted solve; gradient
    /// zero. Serves §5.6.1.2 path-integrated reactive terms `A*ddt(B)`:
    /// q = path_acc + A·(B - path_prev(B)), so the charge increment is A·ΔB
    /// (the capacitance form) and dA reaches the Jacobian only times ΔB,
    /// which is 0 at every committed point (AC sees exactly A·∂B/∂x).
    path_prev,
    /// Committed accumulator latch: reads `pq__<k>`, the sum of the operand's
    /// values over all accepted solves; gradient zero. Carries the charge base
    /// Σ A·ΔB for `path_prev`. The base is fixed across one Newton attempt, so
    /// the reactive residual is one smooth function per attempt and its AD
    /// Jacobian is exact.
    path_acc,
    // --- value-form conditional §4.2.12 (`?:` that needs no CFG split) ---
    select,
    // --- §3.2.2 memory-backed arrays (`Lowered.mem_arrays`) ---
    /// A fresh version of array `a` (an index into `Lowered.mem_arrays`, not a
    /// Value): every element zero, or for a §5.10 held array the values the
    /// last accepted evaluation left in its `Instance` field.
    anew,
    /// Element `b` of array version `a`; real / integer by the array's type.
    /// `b` is the flat element index, and any index outside `0..len` reads
    /// the element type's zero (§3.2.2 names no element there; lowering's
    /// `runtimeArrayIndex` encodes an invalid subscript as -1).
    fload,
    iload,
    /// Array version `a` with element `b` set to `c`: a new version. An index
    /// outside `0..len` writes nothing. Every version of one array shares one
    /// storage, so a version is dead once a store has been made from it; no
    /// pass may make one live again (if-conversion keeps any arm that stores).
    store,
    // --- control §5.8/§5.9 ---
    phi,
    branch,
    jump,
    call,
};

/// Operand shape of an opcode; selects the `InstData` variant.
pub const OpClass = enum(u8) { unary, binary, ternary, phi, branch, jump, call, anew, load, store };

/// Operand shape of an opcode. Drives `instData` decoding.
pub fn opClass(op: Opcode) OpClass {
    return opcode.get(op).class;
}

/// Returns whether `op` yields a §3.2 integer rather than a real.
/// Relational, equality and logical operators yield integer 0/1 (§4.2.5, §4.2.8).
pub fn opIsInteger(op: Opcode) bool {
    return opcode.get(op).int;
}

/// One instruction row. Fixed width; operands are Value/Block/StrId handles
/// packed into a/b/c; `result` is the produced Value; `next` links within a block.
///
/// Operand encoding per class (see `instData` for the decoded view):
///   unary   a = operand
///   binary  a = lhs, b = rhs
///   ternary a = cond, b = then value, c = else value        (§4.2.12)
///   phi     b = extra start, c = pair count (2 u32 per pair: block, value)
///   branch  a = cond, b = then Block, c = else Block        (§5.8)
///   jump    a = target Block                                (§5.9)
///   call    a = Callee, b = extra start (the raw name's StrId, then the
///           args), c = arg count
///   anew    a = array id (`Lowered.mem_arrays` index)                (§3.2.2)
///           b = 0, or 1 + the `Lowered.timepoints` row whose cache fills
///           it, c = that row's slot (VerA's `vera_timepoint`, §2.9)
///   load    a = array version, b = flat index
///   store   a = array version, b = flat index, c = value
pub const InstRow = struct {
    op: Opcode,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    result: Value = .undef,
    next: Inst = .none,
    /// The block whose `next` chain links this row. Never set by a caller:
    /// `addInst` stamps it and every relink restamps it.
    block: Block = .entry,
    /// Index of the token this instruction came from, for diagnostics, or
    /// `no_tok`. Never set by a caller: `addInst` stamps it from `cur_tok`.
    /// A cold column; `instData` does not read it.
    tok: u32 = no_tok,
};

/// "This instruction has no AST origin", such as a constant the SSA builder
/// materialised. Not 0, because token 0 is the first real token of the file.
pub const no_tok: u32 = std.math.maxInt(u32);

/// First and last instruction of a block's `next` chain; `.none` when empty.
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

/// SoA row of the value-definition side table. `payload` is kind-dependent:
/// float bits / int bits / StrId / param index / unknown index / Inst.
pub const ValueRow = struct { kind: DefKind, payload: u64 };

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

// Row budgets, in bytes per row of each SoA table (psp103: 27,760
// instructions, 23,859 values, 4,234 blocks). A new column has to move one of
// these on purpose; docs/seams/s1-ircore.md at 2c3f565d has the narrower
// shapes proposed.
comptime {
    assert(std.MultiArrayList(InstRow).capacityInBytes(1) == 29);
    assert(std.MultiArrayList(ValueRow).capacityInBytes(1) == 9);
    assert(std.MultiArrayList(BlockRow).capacityInBytes(1) == 8);
    assert(@sizeOf(PhiPair) == 8); // two `extra` words
    assert(@sizeOf(GuardLit) == 12);
}

/// The lowered module's name.
name: []const u8 = "",
/// IEEE 1364 §19.1 (via §10.1): the module was declared inside a
/// `` `celldefine ``/`` `endcelldefine `` pair. A tag only; nothing branches on
/// it. It carries the fact past the preprocessor for tools that ask. For any
/// other module, ask `Preprocessor.CellRegion.inForce`.
is_cell: bool = false,
/// Provenance cursor: the builder sets it to the token of the AST node being
/// lowered, and `addInst` stamps it onto every row. A cursor rather than an
/// `emit` parameter because lowering emits from hundreds of sites but visits
/// AST nodes from a handful.
cur_tok: u32 = no_tok,
/// Instruction rows, indexed by `Inst`.
insts: std.MultiArrayList(InstRow) = .empty,
/// Block rows, indexed by `Block`.
blocks: std.MultiArrayList(BlockRow) = .empty,
/// Definition of every dynamic Value; index = @backingInt(v) - first_dynamic.
defs: std.MultiArrayList(ValueRow) = .empty,
/// Shared variable-length payload pool (call args, phi operands).
extra: std.ArrayList(u32) = .empty,
/// String table (`base`'s interner, as the AST's). Slices are not copied: they must
/// outlive the Mir.
strings: base.StringInterner = .empty,
/// Constant dedup, keyed by exact bits so -0.0 / 0.0 stay distinct and NaN
/// payloads survive. Lookup only: iteration order is not deterministic.
fconst_map: std.AutoHashMapUnmanaged(u64, Value) = .empty,
/// Integer constant dedup. Lookup only.
iconst_map: std.AutoHashMapUnmanaged(i64, Value) = .empty,
/// Trivial-phi aliases (ssa.zig `tryRemoveTrivialPhi`). Union-find parent array
/// parallel to `defs` (index = value - first_dynamic); an entry equal to its own
/// Value means "no alias". Only collapsed phis point elsewhere, so codegen never
/// emits a decl for them.
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

/// Returns the first literal of `inst`'s speculation guard, or null when the
/// row runs wherever it stands.
pub fn guardOf(self: *const Mir, inst: Inst) ?u32 {
    return self.guard_of.get(inst);
}

/// The conditions `inst`'s guard reads. Codegen renders them with the row,
/// so they are operands to every analysis that asks what the row reads.
pub fn guardConds(self: *const Mir, inst: Inst) GuardIter {
    return .{ .mir = self, .lit = self.guardOf(inst) orelse GuardLit.end };
}

/// Walks one guard chain in chain order (`guard_lits`).
pub const GuardIter = struct {
    mir: *const Mir,
    lit: u32,

    /// Returns the next literal's condition, or null past the chain's end.
    pub fn next(it: *GuardIter) ?Value {
        if (it.lit == GuardLit.end) return null;
        const l = it.mir.guard_lits.items[it.lit];
        it.lit = l.next;
        return l.cond;
    }
};

/// Prepends the literal (`cond`, `taken`) to `inst`'s speculation guard.
pub fn addGuardLit(self: *Mir, gpa: std.mem.Allocator, inst: Inst, cond: Value, taken: bool) !void {
    const at: u32 = @intCast(self.guard_lits.items.len);
    assert(at != GuardLit.end);
    try self.guard_lits.ensureUnusedCapacity(gpa, 1); // no `guard_of` entry without its literal
    const gop = try self.guard_of.getOrPut(gpa, inst);
    const next = if (gop.found_existing) gop.value_ptr.* else GuardLit.end;
    self.guard_lits.appendAssumeCapacity(.{ .cond = cond, .taken = taken, .next = next });
    gop.value_ptr.* = at;
}

/// Frees every table. Keeps `name`, which the Mir does not own.
pub fn deinit(self: *Mir, gpa: std.mem.Allocator) void {
    self.insts.deinit(gpa);
    self.blocks.deinit(gpa);
    self.defs.deinit(gpa);
    self.extra.deinit(gpa);
    self.strings.deinit(gpa);
    self.fconst_map.deinit(gpa);
    self.iconst_map.deinit(gpa);
    self.alias.deinit(gpa);
    self.guard_of.deinit(gpa);
    self.guard_lits.deinit(gpa);
    self.* = .{ .name = self.name };
}

/// Gives the instruction, value and extra tables room for at least `insts`,
/// `values` and `extra` rows, so a builder that knows its size up front
/// grows each table once. A count below the current capacity does nothing.
/// Why it pays: `insts` and `defs` are MultiArrayLists, and each regrowth
/// copies every column into a fresh block while the old one is still
/// mapped. Invalidates pointers into the tables (`instData` slices).
pub fn reserve(self: *Mir, gpa: std.mem.Allocator, insts: u32, values: u32, extra: u32) !void {
    if (insts > self.insts.capacity) try self.insts.setCapacity(gpa, insts);
    if (values > self.defs.capacity) try self.defs.setCapacity(gpa, values);
    try self.alias.ensureTotalCapacityPrecise(gpa, values);
    try self.extra.ensureTotalCapacityPrecise(gpa, extra);
}

// ---------------------------------------------------------------- values ----

/// Registers a new dynamic Value. Prefer the typed helpers below.
fn addValue(self: *Mir, gpa: std.mem.Allocator, kind: DefKind, payload: u64) !Value {
    const i = self.defs.len + Value.first_dynamic;
    assert(i < std.math.maxInt(u32));
    const v: Value = @fromBackingInt(@intCast(i));
    // Both reserved first: `alias` stays parallel to `defs` on failure.
    try self.defs.ensureUnusedCapacity(gpa, 1);
    try self.alias.ensureUnusedCapacity(gpa, 1);
    self.defs.appendAssumeCapacity(.{ .kind = kind, .payload = payload });
    self.alias.appendAssumeCapacity(v); // self-parent = no alias
    return v;
}

/// Returns the §4.2 real constant `x`, deduped. Common literals map onto the sentinels so
/// two spellings of `1.0` are the same Value in every compilation.
pub fn addFloatConst(self: *Mir, gpa: std.mem.Allocator, x: f64) !Value {
    const bits: u64 = @bitCast(x);
    switch (bits) {
        @as(u64, @bitCast(@as(f64, 0.0))) => return .f_zero,
        @as(u64, @bitCast(@as(f64, 1.0))) => return .f_one,
        @as(u64, @bitCast(@as(f64, -1.0))) => return .f_neg_one,
        @as(u64, @bitCast(@as(f64, 2.0))) => return .f_two,
        @as(u64, @bitCast(@as(f64, 10.0))) => return .f_ten,
        @as(u64, @bitCast(std.math.inf(f64))) => return .f_inf,
        else => {},
    }
    // Reserve before `addValue`, so a failed add leaves no entry behind.
    try self.fconst_map.ensureUnusedCapacity(gpa, 1);
    if (self.fconst_map.get(bits)) |v| return v;
    const v = try self.addValue(gpa, .float_const, bits);
    self.fconst_map.putAssumeCapacityNoClobber(bits, v);
    return v;
}

/// Returns the §4.2 integer constant `x`, deduped; 0, 1 and -1 are sentinels.
pub fn addIntConst(self: *Mir, gpa: std.mem.Allocator, x: i64) !Value {
    switch (x) {
        0 => return .zero,
        1 => return .one,
        -1 => return .neg_one,
        else => {},
    }
    try self.iconst_map.ensureUnusedCapacity(gpa, 1);
    if (self.iconst_map.get(x)) |v| return v;
    const v = try self.addValue(gpa, .int_const, @bitCast(x));
    self.iconst_map.putAssumeCapacityNoClobber(x, v);
    return v;
}

/// Returns a §2.7 string literal Value. `bytes` must outlive the Mir. The string itself is deduped by the interner; the
/// Value wrapper is not (a handful per module, and identical strings are
/// behaviorally interchangeable).
pub fn addStrConst(self: *Mir, gpa: std.mem.Allocator, bytes: []const u8) !Value {
    const s = try self.internString(gpa, bytes);
    return self.addValue(gpa, .str_const, @backingInt(s));
}

/// Returns a §3.4 parameter reference. `param` indexes `Lowered.params`.
pub fn addParamRef(self: *Mir, gpa: std.mem.Allocator, param: u32) !Value {
    return self.addValue(gpa, .param_ref, param);
}

/// Returns a §4.4 signal-access probe. `unknown` indexes the solver unknown vector
/// (Lowered.nodes → the generated `U` enum, i.e. codegen's `x[unknown]`).
/// V(a,b) lowers to fsub of two probes; a branch-current unknown gets its own
/// `nodes` row.
pub fn addBlockParam(self: *Mir, gpa: std.mem.Allocator, unknown: u32) !Value {
    return self.addValue(gpa, .block_param, unknown);
}

/// Interns a name into this Mir's table. `bytes` is borrowed and must outlive
/// the Mir. Idempotent, so the same callee name is one
/// StrId no matter how many call sites use it.
pub fn internString(self: *Mir, gpa: std.mem.Allocator, bytes: []const u8) !StrId {
    return self.strings.intern(gpa, bytes);
}

/// Returns the decoded definition of `value`. A `.str_const` slice borrows
/// the string table. `value` must be a sentinel or name a `defs` row; any
/// other index is a safety-checked out-of-bounds read.
pub fn valueDef(self: *const Mir, value: Value) Def {
    switch (value) {
        .undef => return .undef,
        .f_zero => return .{ .float_const = 0.0 },
        .f_one => return .{ .float_const = 1.0 },
        .f_neg_one => return .{ .float_const = -1.0 },
        .f_two => return .{ .float_const = 2.0 },
        .f_ten => return .{ .float_const = 10.0 },
        .f_inf => return .{ .float_const = std.math.inf(f64) },
        .zero => return .{ .int_const = 0 },
        .one => return .{ .int_const = 1 },
        .neg_one => return .{ .int_const = -1 },
        _ => {},
    }
    const row = self.defs.get(@backingInt(value) - Value.first_dynamic);
    return switch (row.kind) {
        .undef => .undef,
        .float_const => .{ .float_const = @bitCast(row.payload) },
        .int_const => .{ .int_const = @bitCast(row.payload) },
        .str_const => .{ .str_const = self.strings.get(@fromBackingInt(@truncate(row.payload))) },
        .param_ref => .{ .param_ref = @truncate(row.payload) },
        .block_param => .{ .block_param = @truncate(row.payload) },
        .inst_result => .{ .inst_result = @fromBackingInt(@truncate(row.payload)) },
    };
}

/// Returns the kind of `value`, read from the `kind` column without decoding
/// the payload. `value` must be a sentinel or name a `defs` row.
pub fn valueKind(self: *const Mir, value: Value) DefKind {
    return switch (value) {
        .undef => .undef,
        .f_zero, .f_one, .f_neg_one, .f_two, .f_ten, .f_inf => .float_const,
        .zero, .one, .neg_one => .int_const,
        _ => self.defs.items(.kind)[@backingInt(value) - Value.first_dynamic],
    };
}

// --------------------------------------------------------------- aliases ----

/// Records `from` ≡ `to` (ssa.zig trivial-phi removal); overwrites.
/// `from` must be a dynamic Value (a phi result); `to` may be a sentinel.
/// Asserts that `from != to`.
pub fn setAlias(self: *Mir, from: Value, to: Value) void {
    assert(from != to); // a self-alias would make resolveAlias non-terminating
    assert(@backingInt(from) >= Value.first_dynamic);
    self.alias.items[@backingInt(from) - Value.first_dynamic] = to;
}

/// Returns whether `value` was collapsed onto another (codegen skips its decl).
/// `value` must be a sentinel or name a `defs` row.
pub fn hasAlias(self: *const Mir, value: Value) bool {
    const i = @backingInt(value);
    if (i < Value.first_dynamic) return false;
    return self.alias.items[i - Value.first_dynamic] != value;
}

/// Returns the Value `value` aliases to at the end of its chain. Union-find
/// with path compression: amortized near O(1).
/// Takes `*const` but writes `alias` (compression), so it is not safe to call
/// concurrently on one Mir. Asserts the chain has no cycle.
pub fn resolveAlias(self: *const Mir, value: Value) Value {
    const fd = Value.first_dynamic;
    if (@backingInt(value) < fd) return value;
    const parent = self.alias.items;

    var root = value;
    var hops: usize = 0;
    while (@backingInt(root) >= fd) {
        const next = parent[@backingInt(root) - fd];
        if (next == root) break;
        root = next;
        hops += 1;
        assert(hops <= parent.len); // cycle ⇒ SSA bug
    }

    var v = value;
    while (v != root) {
        const next = parent[@backingInt(v) - fd];
        parent[@backingInt(v) - fd] = root;
        v = next;
    }
    return root;
}

// ---------------------------------------------------------------- blocks ----

/// Appends an empty block and returns its handle; the first call returns
/// `.entry`. Asserts that the block count stays below `maxInt(u32)`.
pub fn addBlock(self: *Mir, gpa: std.mem.Allocator) !Block {
    const i = self.blocks.len;
    assert(i < std.math.maxInt(u32));
    try self.blocks.append(gpa, .{});
    return @fromBackingInt(@intCast(i));
}

/// Returns the number of blocks.
pub fn blockCount(self: *const Mir) u32 {
    return @intCast(self.blocks.len);
}

/// Iterator over one block's instruction chain.
pub const InstIterator = struct {
    /// Borrowed `next` column. Adding instructions invalidates it: iterate only
    /// after the block is built (codegen/proof are read-only passes).
    next_col: []const Inst,
    cur: Inst,

    /// Returns the next instruction, or null at the end of the chain.
    pub fn next(it: *InstIterator) ?Inst {
        if (it.cur == .none) return null;
        const out = it.cur;
        it.cur = it.next_col[@backingInt(out)];
        return out;
    }
};

/// Returns an iterator over `block`'s instructions, in emission order (the
/// intrusive `next` chain). The iterator borrows the `next` column: any
/// append to `insts` (every `emit*`) invalidates it.
pub fn blockInsts(self: *const Mir, block: Block) InstIterator {
    return .{
        .next_col = self.insts.items(.next),
        .cur = self.blocks.items(.first)[@backingInt(block)],
    };
}

/// The last instruction linked into `block`, or `.none` when it is empty.
pub fn blockLast(self: *const Mir, block: Block) Inst {
    return self.blocks.items(.last)[@backingInt(block)];
}

/// Unlinks every instruction of `from` after `after` (all of them when `after`
/// is `.none`) and relink them, in order, in front of `to`'s terminator. For a
/// value computed after a join that one incoming edge has to carry: the
/// operands must already be available at the end of `to`. True when there is
/// nothing to move; moves nothing and returns false when `to` has no
/// terminator yet or is `from`.
pub fn moveTailBefore(self: *Mir, from: Block, after: Inst, to: Block) bool {
    const next = self.insts.items(.next);
    const first = self.blocks.items(.first);
    const last = self.blocks.items(.last);
    const home = self.insts.items(.block);
    const head = if (after == .none) first[@backingInt(from)] else next[@backingInt(after)];
    if (head == .none) return true;
    if (from == to) return false;
    var prev: Inst = .none;
    var term = first[@backingInt(to)];
    while (term != .none) : (term = next[@backingInt(term)]) {
        switch (opClass(self.instOp(term))) {
            .branch, .jump => break,
            .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => prev = term,
        }
    } else return false;
    const tail = last[@backingInt(from)];
    var moved = head;
    while (moved != .none) : (moved = next[@backingInt(moved)]) home[@backingInt(moved)] = to;
    if (after == .none) first[@backingInt(from)] = .none else next[@backingInt(after)] = .none;
    last[@backingInt(from)] = after;
    next[@backingInt(tail)] = term;
    if (prev == .none) first[@backingInt(to)] = head else next[@backingInt(prev)] = head;
    return true;
}

/// Removes `inst` from `block`'s chain; the rows after it stay linked. The row
/// is orphaned, not reused, and keeps its `block` column. Asserts that
/// `inst` is linked into `block`. This operation is O(n) in the block's length.
pub fn unlink(self: *Mir, block: Block, inst: Inst) void {
    assert(inst != .none);
    const next = self.insts.items(.next);
    const first = self.blocks.items(.first);
    const last = self.blocks.items(.last);
    const b = @backingInt(block);
    var prev: Inst = .none;
    var cur = first[b];
    while (cur != inst) : (cur = next[@backingInt(cur)]) {
        assert(cur != .none); // the chain ended without reaching `inst`
        prev = cur;
    }
    const after = next[@backingInt(inst)];
    if (prev == .none) first[b] = after else next[@backingInt(prev)] = after;
    if (last[b] == inst) last[b] = prev;
    next[@backingInt(inst)] = .none;
    // An empty chain has neither end; a nonempty one has both.
    assert((first[b] == .none) == (last[b] == .none));
}

/// Relinks every row of `from`, in order, at the end of `to`; `from` is left
/// empty. Asserts that `to != from`.
pub fn splice(self: *Mir, to: Block, from: Block) void {
    assert(to != from);
    const next = self.insts.items(.next);
    const first = self.blocks.items(.first);
    const last = self.blocks.items(.last);
    const home = self.insts.items(.block);
    const head = first[@backingInt(from)];
    if (head == .none) return;
    var moved = head;
    while (moved != .none) : (moved = next[@backingInt(moved)]) home[@backingInt(moved)] = to;
    const tail = last[@backingInt(to)];
    if (tail == .none) first[@backingInt(to)] = head else next[@backingInt(tail)] = head;
    last[@backingInt(to)] = last[@backingInt(from)];
    first[@backingInt(from)] = .none;
    last[@backingInt(from)] = .none;
}

// ---------------------------------------------------------- instructions ----

/// Appends `row` to the end of `block` and links it in. Caller sets row.result
/// (use `emit` to get a fresh result Value automatically).
fn addInst(self: *Mir, gpa: std.mem.Allocator, block: Block, row: InstRow) !Inst {
    const i = self.insts.len;
    assert(i < std.math.maxInt(u32) - 1); // maxInt is Inst.none
    var stamped = row;
    stamped.tok = self.cur_tok; // provenance: see InstRow.tok and cur_tok
    stamped.block = block;
    try self.insts.append(gpa, stamped);
    const inst: Inst = @fromBackingInt(@intCast(i));

    const b = @backingInt(block);
    const last = self.blocks.items(.last)[b];
    if (last == .none) {
        self.blocks.items(.first)[b] = inst;
    } else {
        self.insts.items(.next)[@backingInt(last)] = inst;
    }
    self.blocks.items(.last)[b] = inst;
    return inst;
}

/// Appends `row` to `block` with a fresh result Value, and returns it.
fn addResultInst(self: *Mir, gpa: std.mem.Allocator, block: Block, row: InstRow) !Value {
    try self.insts.ensureUnusedCapacity(gpa, 1); // no result Value without its row
    const result = try self.addValue(gpa, .inst_result, 0);
    var r = row;
    r.result = result;
    const inst = try self.addInst(gpa, block, r);
    self.defs.items(.payload)[@backingInt(result) - Value.first_dynamic] = @backingInt(inst);
    return result;
}

/// Appends a value-producing instruction to `block` and returns its result.
/// Invalidates every `InstIterator` (each `emit*` appends to `insts`).
/// Asserts that `ops` matches `op`'s class (see `InstRow`'s encoding table);
/// phi, branch, jump, call and anew have their own builders.
pub fn emit(self: *Mir, gpa: std.mem.Allocator, block: Block, op: Opcode, ops: []const Value) !Value {
    assert(ops.len >= 1);
    assert(ops.len <= 3);
    assert(switch (opClass(op)) {
        .unary => ops.len == 1,
        .binary => ops.len == 2,
        .ternary, .store => ops.len == 3,
        .load => ops.len == 2,
        .phi, .branch, .jump, .call, .anew => false, // dedicated builders
    });
    return self.addResultInst(gpa, block, .{
        .op = op,
        .a = @backingInt(ops[0]),
        .b = if (ops.len > 1) @backingInt(ops[1]) else 0,
        .c = if (ops.len > 2) @backingInt(ops[2]) else 0,
    });
}

/// Returns a fresh version of §3.2.2 memory-backed array `array` (see `Opcode.anew`).
pub fn emitAnew(self: *Mir, gpa: std.mem.Allocator, block: Block, array: u32) !Value {
    return self.addResultInst(gpa, block, .{ .op = .anew, .a = array });
}

/// Returns a version of `array` filled from slot `slot` of `vera_timepoint`
/// statement `tp`'s cache (`Lowered.TpBlock`).
pub fn emitAnewCached(self: *Mir, gpa: std.mem.Allocator, block: Block, array: u32, tp: u32, slot: u32) !Value {
    return self.addResultInst(gpa, block, .{ .op = .anew, .a = array, .b = tp + 1, .c = slot });
}

/// Appends a §5.8 two-way branch, the block's terminator. Asserts that both
/// targets are blocks of this Mir.
pub fn emitBranch(self: *Mir, gpa: std.mem.Allocator, block: Block, cond: Value, then_block: Block, else_block: Block) !Inst {
    assert(@backingInt(then_block) < self.blockCount());
    assert(@backingInt(else_block) < self.blockCount());
    return self.addInst(gpa, block, .{
        .op = .branch,
        .a = @backingInt(cond),
        .b = @backingInt(then_block),
        .c = @backingInt(else_block),
    });
}

/// Appends a §5.9 unconditional jump, the block's terminator. Asserts that
/// `target` is a block of this Mir.
pub fn emitJump(self: *Mir, gpa: std.mem.Allocator, block: Block, target: Block) !Inst {
    assert(@backingInt(target) < self.blockCount());
    return self.addInst(gpa, block, .{ .op = .jump, .a = @backingInt(target) });
}

/// Appends a call by name (§4.3 math, §4.5 analog operator, §4.7 function,
/// ch9 system function) and returns its result. The one place a name becomes
/// a `Callee`; the raw name is kept for `.systf`. Invalidates every
/// `InstIterator` and the `args` of every earlier `instData` call view.
pub fn emitCall(self: *Mir, gpa: std.mem.Allocator, block: Block, name: StrId, args: []const Value) !Value {
    const start = try self.addExtra(gpa, &.{@backingInt(name)});
    _ = try self.addExtra(gpa, @ptrCast(args));
    return self.addResultInst(gpa, block, .{
        .op = .call,
        .a = @backingInt(Callee.fromName(self.strings.get(name))),
        .b = start,
        .c = @intCast(args.len),
    });
}

/// Appends a phi and returns its result. `pairs` may be empty for an
/// incomplete phi (Braun et al.); fill it later with `setPhiPairs`.
/// Invalidates every `InstIterator` and earlier `instData` call `args`.
pub fn emitPhi(self: *Mir, gpa: std.mem.Allocator, block: Block, pairs: []const PhiPair) !Value {
    const start = try self.addExtraPairs(gpa, pairs);
    return self.addResultInst(gpa, block, .{ .op = .phi, .b = start, .c = @intCast(pairs.len) });
}

/// Replaces a phi's operand list (`sealBlock` fills incomplete phis).
/// Asserts that `inst` is a phi. Invalidates slices previously returned by
/// `instData`.
pub fn setPhiPairs(self: *Mir, gpa: std.mem.Allocator, inst: Inst, pairs: []const PhiPair) !void {
    // ponytail: appends a fresh region and abandons the old one, a few dead
    // u32s per filled phi. Compact the pool only if `extra` shows in a profile.
    assert(self.insts.items(.op)[@backingInt(inst)] == .phi);
    const start = try self.addExtraPairs(gpa, pairs);
    self.insts.items(.b)[@backingInt(inst)] = start;
    self.insts.items(.c)[@backingInt(inst)] = @intCast(pairs.len);
}

/// Returns every column of `inst`, the cold `tok` and `next` included; a hot
/// walk decodes through `instData` instead.
pub fn instRow(self: *const Mir, inst: Inst) InstRow {
    return self.insts.get(@backingInt(inst));
}

/// Returns the token `inst` was lowered from (the finiteness diagnostics'
/// location), or `no_tok` when it has no AST origin.
pub fn instTok(self: *const Mir, inst: Inst) u32 {
    return self.insts.items(.tok)[@backingInt(inst)];
}

/// Returns the opcode of `inst`.
pub fn instOp(self: *const Mir, inst: Inst) Opcode {
    return self.insts.items(.op)[@backingInt(inst)];
}

/// Returns the block `inst` is linked into.
pub fn instBlock(self: *const Mir, inst: Inst) Block {
    return self.insts.items(.block)[@backingInt(inst)];
}

/// Returns the Value `inst` defines, or `.undef` for a terminator.
pub fn instResult(self: *const Mir, inst: Inst) Value {
    return self.insts.items(.result)[@backingInt(inst)];
}

/// Returns the decoded view of `inst`. A call's `args` borrows `extra` and is
/// invalidated by any later append to the pool. Reads only the `op`/`a`/`b`/`c`
/// columns.
pub fn instData(self: *const Mir, inst: Inst) InstData {
    const i = @backingInt(inst);
    const cols = self.insts.slice();
    const row: struct { op: Opcode, a: u32, b: u32, c: u32 } = .{
        .op = cols.items(.op)[i],
        .a = cols.items(.a)[i],
        .b = cols.items(.b)[i],
        .c = cols.items(.c)[i],
    };
    return switch (opClass(row.op)) {
        .unary => .{ .unary = .{ .op = row.op, .operand = @fromBackingInt(@intCast(row.a)) } },
        .binary => .{ .binary = .{
            .op = row.op,
            .lhs = @fromBackingInt(@intCast(row.a)),
            .rhs = @fromBackingInt(@intCast(row.b)),
        } },
        .ternary => .{ .ternary = .{
            .cond = @fromBackingInt(@intCast(row.a)),
            .then_val = @fromBackingInt(@intCast(row.b)),
            .else_val = @fromBackingInt(@intCast(row.c)),
        } },
        .phi => .{ .phi = .{ .start = row.b, .count = row.c } },
        .branch => .{ .branch = .{
            .cond = @fromBackingInt(@intCast(row.a)),
            .then_block = @fromBackingInt(@intCast(row.b)),
            .else_block = @fromBackingInt(@intCast(row.c)),
        } },
        .jump => .{ .jump = .{ .target = @fromBackingInt(@intCast(row.a)) } },
        .call => .{
            .call = .{
                .callee = @fromBackingInt(@intCast(row.a)),
                .name = self.strings.get(@fromBackingInt(@intCast(self.extra.items[row.b]))),
                // Borrowed slice into the payload pool; invalidated by further appends.
                .args = @ptrCast(self.extra.items[row.b + 1 ..][0..row.c]),
            },
        },
        .anew => .{ .anew = .{ .array = row.a, .tp = if (row.b == 0) null else .{ .block = row.b - 1, .slot = row.c } } },
        .load => .{ .load = .{ .op = row.op, .arr = @fromBackingInt(@intCast(row.a)), .index = @fromBackingInt(@intCast(row.b)) } },
        .store => .{ .store = .{
            .arr = @fromBackingInt(@intCast(row.a)),
            .index = @fromBackingInt(@intCast(row.b)),
            .value = @fromBackingInt(@intCast(row.c)),
        } },
    };
}

/// Returns operand `i` of a phi (0..count-1 from `instData(...).phi`).
/// Asserts that `inst` is a phi and `i` is below its pair count.
pub fn phiPair(self: *const Mir, inst: Inst, i: u32) PhiPair {
    const n = @backingInt(inst);
    assert(self.insts.items(.op)[n] == .phi);
    assert(i < self.insts.items(.c)[n]);
    const at = self.insts.items(.b)[n] + i * 2;
    return .{
        .block = @fromBackingInt(@intCast(self.extra.items[at])),
        .value = @fromBackingInt(@intCast(self.extra.items[at + 1])),
    };
}

/// Returns phi `inst`'s incoming value on the edge from block `from`, or null
/// when no pair names `from`; the first pair wins if two do. O(pairs).
pub fn phiIn(self: *const Mir, inst: Inst, from: Block) ?Value {
    const d = self.instData(inst).phi;
    for (0..d.count) |k| {
        const p = self.phiPair(inst, @intCast(k));
        if (p.block == from) return p.value;
    }
    return null;
}

// ----------------------------------------------------------- extra pool ----

/// Appends raw u32s and returns the start index. Prefer the typed wrappers.
/// Invalidates slices previously returned by `instData`.
pub fn addExtra(self: *Mir, gpa: std.mem.Allocator, words: []const u32) !u32 {
    const start = self.extra.items.len;
    assert(start < std.math.maxInt(u32));
    try self.extra.appendSlice(gpa, words);
    return @intCast(start);
}

fn addExtraPairs(self: *Mir, gpa: std.mem.Allocator, pairs: []const PhiPair) !u32 {
    const start = self.extra.items.len;
    assert(start < std.math.maxInt(u32));
    try self.extra.ensureUnusedCapacity(gpa, pairs.len * 2);
    for (pairs) |p| {
        self.extra.appendAssumeCapacity(@backingInt(p.block));
        self.extra.appendAssumeCapacity(@backingInt(p.value));
    }
    return @intCast(start);
}

// -------------------------------------------------------------------------

test "mir: const dedup, block chain, phi pairs, alias" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "diode" };
    defer mir.deinit(gpa);

    // sentinels + dedup (§4.2 constant expressions)
    try std.testing.expectEqual(Value.f_one, try mir.addFloatConst(gpa, 1.0));
    try std.testing.expectEqual(Value.zero, try mir.addIntConst(gpa, 0));
    const k = try mir.addFloatConst(gpa, 1.5);
    try std.testing.expectEqual(k, try mir.addFloatConst(gpa, 1.5));
    try std.testing.expectEqual(@as(f64, 1.5), mir.valueDef(k).float_const);
    // 0.0 and -0.0 are distinct bit patterns and must not collapse
    try std.testing.expect(try mir.addFloatConst(gpa, -0.0) != Value.f_zero);

    const entry = try mir.addBlock(gpa);
    const vd = try mir.addBlockParam(gpa, 0);
    const vs = try mir.addBlockParam(gpa, 1);
    const dv = try mir.emit(gpa, entry, .fsub, &.{ vd, vs });
    const id = try mir.emit(gpa, entry, .fmul, &.{ dv, k });
    try std.testing.expectEqual(@as(u32, 0), mir.valueDef(vd).block_param);

    // instruction chain + decoded view
    var it = mir.blockInsts(entry);
    const in0 = it.next().?;
    const in1 = it.next().?;
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqual(dv, mir.instResult(in0));
    try std.testing.expectEqual(id, mir.instResult(in1));
    try std.testing.expectEqual(vs, mir.instData(in0).binary.rhs);
    try std.testing.expectEqual(in1, mir.valueDef(id).inst_result);

    // call (§4.3): name + args round-trip through the extra pool
    const nm = try mir.internString(gpa, "exp");
    try std.testing.expectEqual(nm, try mir.internString(gpa, "exp")); // deduped
    const e = try mir.emitCall(gpa, entry, nm, &.{id});
    const cd = mir.instData(mir.valueDef(e).inst_result).call;
    try std.testing.expectEqualStrings("exp", cd.name);
    try std.testing.expectEqual(Callee.systf, cd.callee); // bare `exp` is an opcode, not a callee
    try std.testing.expectEqualSlices(Value, &.{id}, cd.args);

    // phi (§5.8): empty then filled, and trivial-phi aliasing
    const join = try mir.addBlock(gpa);
    const p = try mir.emitPhi(gpa, join, &.{});
    const pi = mir.valueDef(p).inst_result;
    try std.testing.expectEqual(@as(u32, 0), mir.instData(pi).phi.count);
    try std.testing.expectEqual(join, mir.instBlock(pi));
    try std.testing.expectEqual(entry, mir.instBlock(in1));
    try mir.setPhiPairs(gpa, pi, &.{ .{ .block = entry, .value = id }, .{ .block = join, .value = e } });
    try std.testing.expectEqual(@as(u32, 2), mir.instData(pi).phi.count);
    try std.testing.expectEqual(e, mir.phiPair(pi, 1).value);

    mir.setAlias(p, e);
    try std.testing.expectEqual(e, mir.resolveAlias(p));
    try std.testing.expectEqual(id, mir.resolveAlias(id));

    try std.testing.expectEqual(@as(u32, 2), mir.blockCount());
}

test addFloatConst {
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);

    // The six real sentinels spend no `defs` row.
    const sentinels = [_]struct { f64, Value }{
        .{ 0.0, .f_zero },
        .{ 1.0, .f_one },
        .{ -1.0, .f_neg_one },
        .{ 2.0, .f_two },
        .{ 10.0, .f_ten },
        .{ std.math.inf(f64), .f_inf },
    };
    for (sentinels) |s| try std.testing.expectEqual(s[1], try mir.addFloatConst(gpa, s[0]));
    try std.testing.expectEqual(@as(usize, 0), mir.defs.len);

    // -inf and -0.0 are not sentinels: each gets one row and keeps its bits.
    const neg_inf = try mir.addFloatConst(gpa, -std.math.inf(f64));
    const neg_zero = try mir.addFloatConst(gpa, -0.0);
    try std.testing.expect(neg_inf != neg_zero);
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), @as(u64, @bitCast(mir.valueDef(neg_zero).float_const)));
    try std.testing.expectEqual(neg_zero, try mir.addFloatConst(gpa, -0.0));

    // Dedup is by bits, so two NaN payloads are two Values and one payload is
    // one, and the payload survives the round trip.
    const nan_a: f64 = @bitCast(@as(u64, 0x7ff8_0000_0000_0001));
    const nan_b: f64 = @bitCast(@as(u64, 0x7ff8_0000_0000_0002));
    const va = try mir.addFloatConst(gpa, nan_a);
    const vb = try mir.addFloatConst(gpa, nan_b);
    try std.testing.expect(va != vb);
    try std.testing.expectEqual(va, try mir.addFloatConst(gpa, nan_a));
    try std.testing.expectEqual(@as(u64, 0x7ff8_0000_0000_0001), @as(u64, @bitCast(mir.valueDef(va).float_const)));
    try std.testing.expectEqual(@as(usize, 4), mir.defs.len);
    try std.testing.expectEqual(DefKind.float_const, mir.valueKind(va));
}

test addIntConst {
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);

    try std.testing.expectEqual(Value.zero, try mir.addIntConst(gpa, 0));
    try std.testing.expectEqual(Value.one, try mir.addIntConst(gpa, 1));
    try std.testing.expectEqual(Value.neg_one, try mir.addIntConst(gpa, -1));
    try std.testing.expectEqual(@as(usize, 0), mir.defs.len);

    // The i64 extremes round-trip, and each is one Value however often asked.
    for ([_]i64{ std.math.maxInt(i64), std.math.minInt(i64), 2 }) |x| {
        const v = try mir.addIntConst(gpa, x);
        try std.testing.expectEqual(v, try mir.addIntConst(gpa, x));
        try std.testing.expectEqual(x, mir.valueDef(v).int_const);
        try std.testing.expectEqual(DefKind.int_const, mir.valueKind(v));
    }
    try std.testing.expectEqual(@as(usize, 3), mir.defs.len);
    // An integer 2 is not the real sentinel `f_two`.
    try std.testing.expect(try mir.addIntConst(gpa, 2) != Value.f_two);
}

test valueDef {
    // Every sentinel decodes without a `defs` row: an empty Mir has none.
    const mir: Mir = .{};
    const want = [_]struct { Value, Def }{
        .{ .undef, .undef },
        .{ .f_zero, .{ .float_const = 0.0 } },
        .{ .f_one, .{ .float_const = 1.0 } },
        .{ .f_neg_one, .{ .float_const = -1.0 } },
        .{ .f_two, .{ .float_const = 2.0 } },
        .{ .f_ten, .{ .float_const = 10.0 } },
        .{ .f_inf, .{ .float_const = std.math.inf(f64) } },
        .{ .zero, .{ .int_const = 0 } },
        .{ .one, .{ .int_const = 1 } },
        .{ .neg_one, .{ .int_const = -1 } },
    };
    try std.testing.expectEqual(@as(usize, Value.first_dynamic), want.len);
    for (want, 0..) |w, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), @backingInt(w[0]));
        try std.testing.expectEqual(w[1], mir.valueDef(w[0]));
        try std.testing.expectEqual(std.meta.activeTag(w[1]), mir.valueKind(w[0]));
        try std.testing.expect(!mir.hasAlias(w[0]));
    }
}

test "mir: string, parameter and probe Values round-trip their payloads" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);

    // The text is interned once; the Value wrapper is not deduped.
    const a = try mir.addStrConst(gpa, "tran");
    const b = try mir.addStrConst(gpa, "tran");
    try std.testing.expect(a != b);
    try std.testing.expectEqualStrings("tran", mir.valueDef(a).str_const);
    try std.testing.expectEqual(@as(usize, 1), mir.strings.strings.items.len);

    const p = try mir.addParamRef(gpa, 7);
    const u = try mir.addBlockParam(gpa, std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u32, 7), mir.valueDef(p).param_ref);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), mir.valueDef(u).block_param);
    try std.testing.expectEqual(DefKind.param_ref, mir.valueKind(p));
    try std.testing.expectEqual(DefKind.block_param, mir.valueKind(u));
    // Dynamic Values number from `first_dynamic` in creation order.
    try std.testing.expectEqual(@as(u32, Value.first_dynamic), @backingInt(a));
    try std.testing.expectEqual(@as(u32, Value.first_dynamic + 3), @backingInt(u));
}

test "mir: every builder encodes the operands its InstData view decodes" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);
    const entry = try mir.addBlock(gpa);
    const b1 = try mir.addBlock(gpa);
    const b2 = try mir.addBlock(gpa);
    try std.testing.expectEqual(Block.entry, entry);
    try std.testing.expectEqual(@as(u32, 3), mir.blockCount());
    try std.testing.expectEqual(Inst.none, mir.blockLast(b1));

    // §3.2.2 arrays: a fresh version, a cached one, a store and a load.
    mir.cur_tok = 42;
    const a0 = try mir.emitAnew(gpa, entry, 3);
    mir.cur_tok = no_tok;
    const a1 = try mir.emitAnewCached(gpa, entry, 3, 0, 5);
    const s = try mir.emit(gpa, entry, .store, &.{ a0, .zero, .f_one });
    const l = try mir.emit(gpa, entry, .iload, &.{ s, .one });
    const d0 = mir.instData(mir.valueDef(a0).inst_result).anew;
    try std.testing.expectEqual(@as(u32, 3), d0.array);
    try std.testing.expect(d0.tp == null);
    const d1 = mir.instData(mir.valueDef(a1).inst_result).anew;
    try std.testing.expectEqual(@as(u32, 0), d1.tp.?.block);
    try std.testing.expectEqual(@as(u32, 5), d1.tp.?.slot);
    const ds = mir.instData(mir.valueDef(s).inst_result).store;
    try std.testing.expectEqual(a0, ds.arr);
    try std.testing.expectEqual(Value.zero, ds.index);
    try std.testing.expectEqual(Value.f_one, ds.value);
    const dl = mir.instData(mir.valueDef(l).inst_result).load;
    try std.testing.expectEqual(Opcode.iload, dl.op);
    try std.testing.expectEqual(s, dl.arr);
    try std.testing.expectEqual(Value.one, dl.index);

    // Provenance and home block are stamped, never taken from the caller.
    const r0 = mir.instRow(mir.valueDef(a0).inst_result);
    try std.testing.expectEqual(@as(u32, 42), r0.tok);
    try std.testing.expectEqual(entry, r0.block);
    try std.testing.expectEqual(no_tok, mir.instTok(mir.valueDef(a1).inst_result));

    // §4.2.12 select, then the two terminators, which define no Value.
    const sel = try mir.emit(gpa, entry, .select, &.{ .one, .f_two, .f_ten });
    const dt = mir.instData(mir.valueDef(sel).inst_result).ternary;
    try std.testing.expectEqual(Value.one, dt.cond);
    try std.testing.expectEqual(Value.f_two, dt.then_val);
    try std.testing.expectEqual(Value.f_ten, dt.else_val);
    const br = try mir.emitBranch(gpa, entry, .one, b1, b2);
    try std.testing.expectEqual(Value.undef, mir.instResult(br));
    const dbr = mir.instData(br).branch;
    try std.testing.expectEqual(Value.one, dbr.cond);
    try std.testing.expectEqual(b1, dbr.then_block);
    try std.testing.expectEqual(b2, dbr.else_block);
    const j = try mir.emitJump(gpa, b1, b2);
    try std.testing.expectEqual(Value.undef, mir.instResult(j));
    try std.testing.expectEqual(b2, mir.instData(j).jump.target);
    try std.testing.expectEqual(j, mir.blockLast(b1));
    try std.testing.expectEqual(br, mir.blockLast(entry));

    // A call with no arguments, a known callee, and an unlisted `$` name.
    const t = try mir.emitCall(gpa, b2, try mir.internString(gpa, "$abstime"), &.{});
    const dc = mir.instData(mir.valueDef(t).inst_result).call;
    try std.testing.expectEqual(Callee.@"$abstime", dc.callee);
    try std.testing.expectEqual(@as(usize, 0), dc.args.len);
    const u = try mir.emitCall(gpa, b2, try mir.internString(gpa, "$my_task"), &.{ t, .one });
    const du = mir.instData(mir.valueDef(u).inst_result).call;
    try std.testing.expectEqual(Callee.systf, du.callee);
    try std.testing.expectEqualStrings("$my_task", du.name);
    try std.testing.expectEqualSlices(Value, &.{ t, .one }, du.args);
}

test "mir: block chain edits agree with a list-per-block model (seeded)" {
    // Model-based: every chain edit is mirrored on plain lists, and the
    // chains, `last` and the `block` column are compared after each one.
    const gpa = std.testing.allocator;
    const nb = 4;
    var prng = std.Random.DefaultPrng.init(0x6d69_7263);
    const r = prng.random();
    const Edit = enum { value, jump, unlink, splice, move };
    for (0..40) |round| {
        errdefer std.debug.print("chain model: round {d}\n", .{round});
        var mir: Mir = .{};
        defer mir.deinit(gpa);
        var model: [nb]std.ArrayList(Inst) = @splat(.empty);
        defer for (&model) |*l| l.deinit(gpa);
        var blocks: [nb]Block = undefined;
        for (&blocks) |*b| b.* = try mir.addBlock(gpa);

        for (0..60) |_| {
            const bi = r.uintLessThan(usize, nb);
            switch (r.enumValue(Edit)) {
                .value => {
                    _ = try mir.emit(gpa, blocks[bi], .fneg, &.{.f_one});
                    try model[bi].append(gpa, mir.blockLast(blocks[bi]));
                },
                .jump => {
                    const to = blocks[r.uintLessThan(usize, nb)];
                    try model[bi].append(gpa, try mir.emitJump(gpa, blocks[bi], to));
                },
                .unlink => if (model[bi].items.len != 0) {
                    const k = r.uintLessThan(usize, model[bi].items.len);
                    mir.unlink(blocks[bi], model[bi].orderedRemove(k));
                },
                .splice => {
                    const ti = r.uintLessThan(usize, nb);
                    if (ti != bi) {
                        mir.splice(blocks[ti], blocks[bi]);
                        try model[ti].appendSlice(gpa, model[bi].items);
                        model[bi].clearRetainingCapacity();
                    }
                },
                .move => {
                    const ti = r.uintLessThan(usize, nb);
                    const from = &model[bi];
                    // `after` is none (move every row) or one of `from`'s rows.
                    const keep = r.uintLessThan(usize, from.items.len + 1);
                    const after: Inst = if (keep == 0) .none else from.items[keep - 1];
                    const tail_len = from.items.len - keep;
                    const term_at: ?usize = for (model[ti].items, 0..) |inst, k| {
                        if (mir.instOp(inst) == .jump) break k;
                    } else null;
                    // The documented order: nothing to move, then `to` is
                    // `from`, then `to` has no terminator.
                    const moved = if (tail_len == 0) true else if (ti == bi) false else term_at != null;
                    try std.testing.expectEqual(moved, mir.moveTailBefore(blocks[bi], after, blocks[ti]));
                    if (tail_len != 0 and moved) {
                        try model[ti].insertSlice(gpa, term_at.?, from.items[keep..]);
                        from.shrinkRetainingCapacity(keep);
                    }
                },
            }
            for (blocks, model) |b, m| {
                var it = mir.blockInsts(b);
                for (m.items) |linked| {
                    try std.testing.expectEqual(linked, it.next().?);
                    try std.testing.expectEqual(b, mir.instBlock(linked));
                }
                try std.testing.expect(it.next() == null);
                const last: Inst = if (m.items.len == 0) .none else m.items[m.items.len - 1];
                try std.testing.expectEqual(last, mir.blockLast(b));
            }
        }
    }
}

test resolveAlias {
    // Model-based: the union-find against a naive walk of the same parents.
    // As in ssa.zig and ifconv.zig, only a root (an unaliased Value) is ever
    // aliased, and only onto an older Value or a sentinel, so no cycle forms.
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xa11a5);
    const r = prng.random();
    var mir: Mir = .{};
    defer mir.deinit(gpa);
    const n = 64;
    var naive: [n]Value = undefined;
    for (&naive, 0..) |*p, i| {
        p.* = try mir.addFloatConst(gpa, @floatFromInt(i + 100));
        try std.testing.expectEqual(@as(u32, @intCast(i + Value.first_dynamic)), @backingInt(p.*));
    }
    for (0..200) |_| {
        const i = r.uintLessThan(usize, n);
        const from: Value = @fromBackingInt(@intCast(i + Value.first_dynamic));
        if (naive[i] != from) continue; // not a root
        const j = r.uintLessThan(usize, i + 1);
        const to: Value = if (j == i) .f_one else @fromBackingInt(@intCast(j + Value.first_dynamic));
        try std.testing.expect(!mir.hasAlias(from));
        mir.setAlias(from, to);
        naive[i] = to;
        try std.testing.expect(mir.hasAlias(from));
        for (0..n) |k| {
            const v: Value = @fromBackingInt(@intCast(k + Value.first_dynamic));
            var root = v;
            while (@backingInt(root) >= Value.first_dynamic) {
                const next = naive[@backingInt(root) - Value.first_dynamic];
                if (next == root) break;
                root = next;
            }
            try std.testing.expectEqual(root, mir.resolveAlias(v));
            // Path compression: after a resolve, the row names its root.
            if (root != v) try std.testing.expectEqual(root, mir.alias.items[k]);
        }
    }
    // A sentinel resolves to itself and is never aliased.
    try std.testing.expectEqual(Value.f_inf, mir.resolveAlias(.f_inf));
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

/// Fails unless every side table agrees with `defs` and `insts`: the
/// invariants a builder call must keep even when it fails part way.
fn expectConsistent(mir: *const Mir) !void {
    const fd = Value.first_dynamic;
    try std.testing.expectEqual(mir.defs.len, mir.alias.items.len);
    var fit = mir.fconst_map.iterator();
    while (fit.next()) |e| {
        try std.testing.expect(@backingInt(e.value_ptr.*) - fd < mir.defs.len);
        try std.testing.expectEqual(e.key_ptr.*, @as(u64, @bitCast(mir.valueDef(e.value_ptr.*).float_const)));
    }
    var iit = mir.iconst_map.iterator();
    while (iit.next()) |e| {
        try std.testing.expect(@backingInt(e.value_ptr.*) - fd < mir.defs.len);
        try std.testing.expectEqual(e.key_ptr.*, mir.valueDef(e.value_ptr.*).int_const);
    }
    var git = mir.guard_of.valueIterator();
    while (git.next()) |lit| try std.testing.expect(lit.* < mir.guard_lits.items.len);
    for (mir.defs.items(.kind), mir.defs.items(.payload), 0..) |kind, payload, i| {
        if (kind != .inst_result) continue;
        try std.testing.expect(payload < mir.insts.len);
        try std.testing.expectEqual(@as(u32, @intCast(i + fd)), @backingInt(mir.instResult(@fromBackingInt(@intCast(payload)))));
    }
}

test "mir: a builder call that runs out of memory leaves every table consistent" {
    // Fault injection with recovery: fail allocation k, swallow the error,
    // keep building, and check the cross-table invariants after each run.
    var k: usize = 0;
    while (true) : (k += 1) {
        errdefer std.debug.print("failing allocation {d}\n", .{k});
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = k });
        const gpa = failing.allocator();
        var mir: Mir = .{};
        defer mir.deinit(gpa);
        const entry = mir.addBlock(gpa) catch null;
        for (0..3) |round| {
            const x: f64 = @floatFromInt(round);
            _ = mir.addFloatConst(gpa, 1.5 + x) catch {};
            _ = mir.addIntConst(gpa, 7 + @as(i64, @intCast(round))) catch {};
            const b = entry orelse continue;
            const v = mir.emit(gpa, b, .fneg, &.{.f_one}) catch continue;
            mir.addGuardLit(gpa, mir.valueDef(v).inst_result, v, true) catch {};
            _ = mir.emitCall(gpa, b, mir.internString(gpa, "exp") catch continue, &.{v}) catch {};
        }
        try expectConsistent(&mir);
        if (!failing.has_induced_failure) break;
    }
}

test "mir: building leaks nothing when any allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var mir: Mir = .{};
            defer mir.deinit(gpa);
            try mir.reserve(gpa, 4, 4, 4);
            const entry = try mir.addBlock(gpa);
            const join = try mir.addBlock(gpa);
            const k = try mir.addFloatConst(gpa, 1.5);
            const n = try mir.addIntConst(gpa, 9);
            const s = try mir.addStrConst(gpa, "tran");
            const v = try mir.emit(gpa, entry, .fmul, &.{ k, try mir.addParamRef(gpa, 0) });
            try mir.addGuardLit(gpa, mir.valueDef(v).inst_result, n, true);
            _ = try mir.emitCall(gpa, entry, try mir.internString(gpa, "$strobe"), &.{ s, v });
            _ = try mir.emitBranch(gpa, entry, n, join, join);
            const p = try mir.emitPhi(gpa, join, &.{});
            try mir.setPhiPairs(gpa, mir.valueDef(p).inst_result, &.{.{ .block = entry, .value = v }});
        }
    }.run, .{});
}
