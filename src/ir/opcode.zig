//! The MIR opcode set and one row of facts per opcode: an `Opcode` in, its
//! operand class, result type, LRM domain obligation (Tables 4-14/4-15),
//! comparison relation and constant fold out. `table` is a `std.EnumArray`
//! built with `init`, so a new opcode does not compile until its row exists.
//! Target spellings live in `src/codegen/device/codegen/opcode_zig.zig`: `ir`
//! does not know the target is Zig.
//!
//! Cites: §2.7, §2.9, §3.2, §3.2.2, §4.2, §4.2.1.1, §4.2.1.2, §4.2.1.3,
//! §4.2.3, §4.2.4, §4.2.5, §4.2.7, §4.2.8, §4.2.9, §4.2.10, §4.2.11, §4.2.12,
//! §4.3.1, §4.3.2, §5.6.1.2, §5.8, §5.9, §5.10; IEEE 1364-2005 §5.1.5.
//!
//! Contents:
//! - `pub const Opcode = enum(u8)`
//! - `pub const OpClass = enum(u8)`
//! - `pub const Domain = enum(u8)`
//! - `pub const Relation = enum(u8)`
//! - `pub const Fold = union(enum)`
//! - `pub fn Kernel(comptime Op: type) type`
//! - `pub const Info = struct`
//! - `pub const table: std.EnumArray(Opcode, Info)`
//! - `pub fn get(op: Opcode) Info`
//! - `pub fn class(op: Opcode) OpClass`
//! - `pub fn isInteger(op: Opcode) bool`
//! - `pub fn operandCount(c: OpClass) ?u8`
//! - `pub fn fold(op: Opcode, args: []const Const) ?Const`
//! - `pub fn label(op: Opcode) []const u8`

const std = @import("std");
const assert = std.debug.assert;
const value_fold = @import("kernels").fold;
const Const = value_fold.Const;

/// Opcode set: §4.2 arithmetic, relational, logical, bitwise and shift
/// operators, §4.3 math, casts, §3.2.2 arrays and §5.8/§5.9 control. Naming:
/// a leading `f` is the real-valued form, a leading `i` the integer form.
/// Math functions (§4.3) are always real-valued and carry the bare LRM name.
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
    /// Array version `arr` with element `index` set to `value`: a new version. An index
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

/// Operand shape of an opcode; selects the `Mir.InstData` variant and the
/// row encoding (`Mir.InstRow`).
pub const OpClass = enum(u8) { unary, binary, ternary, phi, branch, jump, call, anew, load, store };

/// LRM Tables 4-14 / 4-15 domains. The operand of each must be proven in-domain
/// (else compile error), except the "All x" group which governs float mode only.
pub const Domain = enum(u8) {
    all, // exp, expm1, sinh, cosh, tanh, sin, cos, floor, ceil, min, max, abs; §4.3.1/§4.3.2
    positive, // ln, log10                                   §4.3.1  (x > 0)
    gt_neg_one, // ln1p                                       §4.3.1  (x > -1)
    non_negative, // sqrt                                     §4.3.1  (x >= 0)
    unit_closed, // asin, acos                                §4.3.2  (-1 <= x <= 1)
    unit_open, // atanh                                       §4.3.2  (-1 < x < 1)
    ge_one, // acosh                                          §4.3.2  (x >= 1)
    nonzero_divisor, // '/', '%'                              §4.2 / §4.3.1
    tan_poles, // tan: x != n(π/2), n odd                     §4.3.2
    pow_sign, // pow(x,y) sign rules                          §4.3.1 Table 4-14
};

/// `lhs REL rhs` for the twelve comparison opcodes (`Info.rel`).
pub const Relation = enum(u8) { lt, le, gt, ge, eq, ne };

/// How the one constant kernel (`kernels.fold`) folds an opcode.
/// No default: a new opcode states its fold or does not compile.
pub const Fold = union(enum) {
    /// Not a value of its operands: a latch, or a class `fold` never sees
    /// (`select`, `phi` and `call` are the walker's to resolve).
    none,
    /// `opt_barrier`: the operand, unchanged.
    identity,
    /// §4.2.1.2 integer→real (`if_cast`).
    to_real,
    /// §4.2.1.1 real→integer, rounding, ties away from zero (`fi_cast`).
    /// Saturating and NaN→0 (`lossyCast`): the rule codegen emits.
    to_int,
    unary: Kernel(value_fold.UnaryOp),
    binary: Kernel(value_fold.BinaryOp),
    math: Kernel(value_fold.MathFn),
};

/// One row of `table`.
pub const Info = struct {
    /// Operand shape; drives `Mir.instData` decoding.
    class: OpClass,
    /// The result is a §3.2 integer rather than a real. Relational, equality
    /// and logical operators yield integer 0/1 (§4.2.5, §4.2.7, §4.2.8).
    int: bool = false,
    /// The result is 0 or 1: the relational, equality and logical operators.
    bool01: bool = false,
    /// A predicate the prover's `condFacts` can mine and if-conversion's
    /// `peelToBool` may peel: the §4.2.5/§4.2.7 comparisons and `!`. Not `&&`
    /// and `||`, which are 0/1 but carry no fact about an operand.
    predicate: bool = false,
    /// The §4.2.4/§4.2.5 relation a comparison tests, real or integer alike;
    /// null for every other opcode. The prover's `condFacts` mines it.
    rel: ?Relation = null,
    /// The LRM domain obligation. For the binary members it is on the SECOND
    /// operand (`nonzero_divisor`) or on BOTH (`pow_sign`); everything else
    /// constrains the single unary operand.
    ///
    /// Not `.fdiv`: §4.2.4 makes only `%`-by-zero an error. `x/0.0` is an
    /// exact IEEE ±inf and is legal, so it forfeits finiteness instead of
    /// rejecting (see the prover's `.fdiv` transfer). `ipow`'s one
    /// undefined corner is pow's: a zero base under a negative exponent (IEEE
    /// 1364-2005 Table 5-6's 'bx).
    domain: Domain = .all,
    /// Table 4-14/4-15 spelling for diagnostics (`log10` is Verilog-A's
    /// `log`); null means the tag name.
    label: ?[]const u8 = null,
    /// How `fold` evaluates it over constant operands.
    fold: Fold,
};

/// Per-opcode facts, total over `Opcode`.
pub const table = std.EnumArray(Opcode, Info).init(.{
    .fadd = .{ .class = .binary, .fold = .{ .binary = .{ .f = .add } } },
    .fsub = .{ .class = .binary, .fold = .{ .binary = .{ .f = .sub } } },
    .fmul = .{ .class = .binary, .fold = .{ .binary = .{ .f = .mul } } },
    .fdiv = .{ .class = .binary, .fold = .{ .binary = .{ .f = .div } } },
    .fmod = .{ .class = .binary, .domain = .nonzero_divisor, .fold = .{ .binary = .{ .f = .mod } } },
    .fneg = .{ .class = .unary, .fold = .{ .unary = .{ .f = .minus } } },
    .iadd = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .add, .int = true } } },
    .isub = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .sub, .int = true } } },
    .imul = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .mul, .int = true } } },
    .idiv = .{ .class = .binary, .int = true, .domain = .nonzero_divisor, .fold = .{ .binary = .{ .f = .div, .int = true } } },
    .imod = .{ .class = .binary, .int = true, .domain = .nonzero_divisor, .fold = .{ .binary = .{ .f = .mod, .int = true } } },
    .ineg = .{ .class = .unary, .int = true, .fold = .{ .unary = .{ .f = .minus, .int = true, .wrap = true } } },
    .flt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .lt, .fold = .{ .binary = .{ .f = .lt } } },
    .fgt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .gt, .fold = .{ .binary = .{ .f = .gt } } },
    .fle = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .le, .fold = .{ .binary = .{ .f = .le } } },
    .fge = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .ge, .fold = .{ .binary = .{ .f = .ge } } },
    .feq = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .eq, .fold = .{ .binary = .{ .f = .eq } } },
    .fne = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .ne, .fold = .{ .binary = .{ .f = .neq } } },
    .ilt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .lt, .fold = .{ .binary = .{ .f = .lt, .int = true } } },
    .igt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .gt, .fold = .{ .binary = .{ .f = .gt, .int = true } } },
    .ile = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .le, .fold = .{ .binary = .{ .f = .le, .int = true } } },
    .ige = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .ge, .fold = .{ .binary = .{ .f = .ge, .int = true } } },
    .ieq = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .eq, .fold = .{ .binary = .{ .f = .eq, .int = true } } },
    .ine = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .ne, .fold = .{ .binary = .{ .f = .neq, .int = true } } },
    .logand = .{ .class = .binary, .int = true, .bool01 = true, .fold = .{ .binary = .{ .f = .logical_and } } },
    .logor = .{ .class = .binary, .int = true, .bool01 = true, .fold = .{ .binary = .{ .f = .logical_or } } },
    .lognot = .{ .class = .unary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .unary = .{ .f = .logical_not } } },
    .bitand = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_and, .int = true } } },
    .bitor = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_or, .int = true } } },
    .bitxor = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_xor, .int = true } } },
    .bitxnor = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_xnor, .int = true } } },
    .bitnot = .{ .class = .unary, .int = true, .fold = .{ .unary = .{ .f = .bit_not, .int = true } } },
    .shl = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .shl, .int = true } } },
    .shr = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .shr, .int = true } } },
    .sqrt = .{ .class = .unary, .domain = .non_negative, .label = "sqrt()", .fold = .{ .math = .{ .f = .sqrt } } },
    .exp = .{ .class = .unary, .fold = .{ .math = .{ .f = .exp } } },
    .expm1 = .{ .class = .unary, .fold = .{ .math = .{ .f = .expm1 } } },
    .ln = .{ .class = .unary, .domain = .positive, .label = "ln()", .fold = .{ .math = .{ .f = .ln } } },
    .ln1p = .{ .class = .unary, .domain = .gt_neg_one, .label = "ln1p()", .fold = .{ .math = .{ .f = .ln1p } } },
    .log10 = .{ .class = .unary, .domain = .positive, .label = "log()", .fold = .{ .math = .{ .f = .log } } },
    .pow = .{ .class = .binary, .domain = .pow_sign, .label = "pow()", .fold = .{ .math = .{ .f = .pow } } },
    .hypot = .{ .class = .binary, .fold = .{ .math = .{ .f = .hypot } } },
    .floor = .{ .class = .unary, .fold = .{ .math = .{ .f = .floor } } },
    .ceil = .{ .class = .unary, .fold = .{ .math = .{ .f = .ceil } } },
    .fabs = .{ .class = .unary, .fold = .{ .math = .{ .f = .abs } } },
    .fmin = .{ .class = .binary, .fold = .{ .math = .{ .f = .min } } },
    .fmax = .{ .class = .binary, .fold = .{ .math = .{ .f = .max } } },
    .iabs = .{ .class = .unary, .int = true, .fold = .{ .math = .{ .f = .abs, .int = true, .wrap = true } } },
    .imin = .{ .class = .binary, .int = true, .fold = .{ .math = .{ .f = .min, .int = true } } },
    .imax = .{ .class = .binary, .int = true, .fold = .{ .math = .{ .f = .max, .int = true } } },
    .ipow = .{ .class = .binary, .int = true, .domain = .pow_sign, .fold = .{ .binary = .{ .f = .pow, .int = true } } },
    .sin = .{ .class = .unary, .fold = .{ .math = .{ .f = .sin } } },
    .cos = .{ .class = .unary, .fold = .{ .math = .{ .f = .cos } } },
    .tan = .{ .class = .unary, .domain = .tan_poles, .label = "tan()", .fold = .{ .math = .{ .f = .tan } } },
    .asin = .{ .class = .unary, .domain = .unit_closed, .label = "asin()", .fold = .{ .math = .{ .f = .asin } } },
    .acos = .{ .class = .unary, .domain = .unit_closed, .label = "acos()", .fold = .{ .math = .{ .f = .acos } } },
    .atan = .{ .class = .unary, .fold = .{ .math = .{ .f = .atan } } },
    .atan2 = .{ .class = .binary, .fold = .{ .math = .{ .f = .atan2 } } },
    .sinh = .{ .class = .unary, .fold = .{ .math = .{ .f = .sinh } } },
    .cosh = .{ .class = .unary, .fold = .{ .math = .{ .f = .cosh } } },
    .tanh = .{ .class = .unary, .fold = .{ .math = .{ .f = .tanh } } },
    .asinh = .{ .class = .unary, .fold = .{ .math = .{ .f = .asinh } } },
    .acosh = .{ .class = .unary, .domain = .ge_one, .label = "acosh()", .fold = .{ .math = .{ .f = .acosh } } },
    .atanh = .{ .class = .unary, .domain = .unit_open, .label = "atanh()", .fold = .{ .math = .{ .f = .atanh } } },
    .fi_cast = .{ .class = .unary, .int = true, .fold = .to_int },
    .if_cast = .{ .class = .unary, .fold = .to_real },
    .opt_barrier = .{ .class = .unary, .fold = .identity },
    .dstop = .{ .class = .unary, .fold = .identity },
    .path_prev = .{ .class = .unary, .fold = .none },
    .path_acc = .{ .class = .unary, .fold = .none },
    .select = .{ .class = .ternary, .fold = .none },
    // §3.2.2 memory-backed arrays: an element is not a value of the index's
    // operands, so nothing folds; an `iload` is a §3.2 integer.
    .anew = .{ .class = .anew, .fold = .none },
    .fload = .{ .class = .load, .fold = .none },
    .iload = .{ .class = .load, .int = true, .fold = .none },
    .store = .{ .class = .store, .fold = .none },
    .phi = .{ .class = .phi, .fold = .none },
    .branch = .{ .class = .branch, .fold = .none },
    .jump = .{ .class = .jump, .fold = .none },
    .call = .{ .class = .call, .fold = .none },
});

// The facts every row must agree on, checked once at build time: a 0/1 result
// is an integer, only a 0/1 result is a predicate, a relation is exactly a
// comparison (every predicate but `!`), a label exists to name a domain error,
// and a folding row's kernel takes as many operands as its class.
comptime {
    @setEvalBranchQuota(10_000);
    assert(@sizeOf(Opcode) == 1);
    assert(@sizeOf(OpClass) == 1);
    for (std.enums.values(Opcode)) |op| {
        const info = table.get(op);
        if (info.bool01) assert(info.int);
        if (info.predicate) assert(info.bool01);
        assert((info.predicate and op != .lognot) == (info.rel != null));
        if (info.label != null) assert(info.domain != .all);
        switch (info.fold) {
            .unary, .identity, .to_real, .to_int => assert(info.class == .unary),
            .binary => assert(info.class == .binary),
            .math => |k| assert(info.class == if (k.f.arity() == 1) OpClass.unary else .binary),
            .none => {},
        }
    }
}

/// Returns the row type of one kernel operation. The operands are first
/// converted to the opcode's type (`int` or real) because a MIR opcode,
/// unlike a source operator, already names it: `fadd` is real whatever its
/// operands folded to. `wrap` applies §3.2's 32 bits to the result where the
/// device does (`wrap32`); `+ - * << /` and `**` already wrap in the kernel.
pub fn Kernel(comptime Op: type) type {
    return struct { f: Op, int: bool = false, wrap: bool = false };
}

/// Returns `op`'s row of `table`.
pub fn get(op: Opcode) Info {
    return table.get(op);
}

/// Returns the operand shape of `op`, which drives `Mir.instData` decoding.
pub fn class(op: Opcode) OpClass {
    return table.getPtrConst(op).class;
}

/// Returns whether `op` yields a §3.2 integer rather than a real.
/// Relational, equality and logical operators yield integer 0/1 (§4.2.5, §4.2.8).
pub fn isInteger(op: Opcode) bool {
    return table.getPtrConst(op).int;
}

/// Returns how many Value operands `Mir.emit` takes for class `c`, or null
/// for a class with its own builder (phi, branch, jump, call, anew).
pub fn operandCount(c: OpClass) ?u8 {
    return switch (c) {
        .unary => 1,
        .binary, .load => 2,
        .ternary, .store => 3,
        .phi, .branch, .jump, .call, .anew => null,
    };
}

/// Returns `op` over already-folded operands, through the one constant kernel: the
/// per-instruction step every MIR folder shares (`analysis.foldConst`,
/// `lower/contrib.scanFinite`). Null when `op` is not a constant operation or
/// the kernel declines (a zero integer divisor, `0 ** -1`). `args` holds one
/// folded operand per operand of `op` (one for a unary, two for a binary).
/// Asserts that `args.len` is that operand count for every opcode that
/// folds (a `.none` row reads no operand and takes any slice).
pub fn fold(op: Opcode, args: []const Const) ?Const {
    const row = table.getPtrConst(op);
    if (row.fold != .none) assert(args.len == operandCount(row.class).?);
    const result: ?Const = switch (row.fold) {
        .none => null,
        .identity => args[0],
        // §4.2.1.1/§4.2.1.2 convert a number; `asReal` would read a string as 0.
        .to_real => if (args[0] == .str) null else .{ .real = args[0].asReal() },
        .to_int => if (args[0] == .str) null else .{ .int = std.math.lossyCast(i64, @round(args[0].asReal())) },
        .unary => |k| wrapped(k.wrap, value_fold.unary(k.f, as(k.int, args[0]) orelse return null)),
        .binary => |k| wrapped(k.wrap, value_fold.binary(
            k.f,
            as(k.int, args[0]) orelse return null,
            as(k.int, args[1]) orelse return null,
            null,
        )),
        .math => |k| blk: {
            assert(args.len == k.f.arity());
            var buf: [value_fold.MathFn.arity_max]Const = undefined;
            for (args, buf[0..args.len]) |a, *b| b.* = as(k.int, a) orelse return null;
            break :blk wrapped(k.wrap, value_fold.math(k.f, buf[0..args.len]));
        },
    };
    // A fold never produces a string, and an integer opcode folds to an integer.
    if (result) |r| assert(r != .str);
    if (result) |r| if (row.int and row.fold != .identity) assert(r == .int);
    return result;
}

/// Returns the diagnostic spelling of `op` (see `Info.label`).
pub fn label(op: Opcode) []const u8 {
    const text = table.getPtrConst(op).label orelse @tagName(op);
    assert(text.len != 0);
    return text;
}

// ---- private ----

/// A folded operand in the opcode's type. An integer from a real is
/// `fi_cast`'s rounding; a string is not an operand of any opcode.
fn as(int: bool, c: Const) ?Const {
    if (c == .str) return null;
    if (!int) return .{ .real = c.asReal() };
    return .{
        .int = switch (c) {
            .int => |i| i,
            .real => |r| std.math.lossyCast(i64, @round(r)),
            .str => unreachable, // returned above
        },
    };
}

fn wrapped(wrap: bool, r: ?Const) ?Const {
    const c = r orelse return null;
    return if (wrap and c == .int) .{ .int = value_fold.wrap32(c.int) } else c;
}

test "fold: an opcode's type, not its operands', decides the kernel's rule" {
    const i = struct {
        fn c(v: i64) Const {
            return .{ .int = v };
        }
    }.c;
    // `fdiv` is real division even over two integers; `idiv` truncates.
    try std.testing.expectEqual(@as(f64, 3.5), fold(.fdiv, &.{ i(7), i(2) }).?.real);
    try std.testing.expectEqual(@as(i64, 3), fold(.idiv, &.{ i(7), i(2) }).?.int);
    try std.testing.expectEqual(@as(?Const, null), fold(.idiv, &.{ i(7), i(0) }));
    // §3.2: `~` and unary minus at 32 bits.
    try std.testing.expectEqual(@as(i64, -2147483648), fold(.ineg, &.{i(-2147483648)}).?.int);
    try std.testing.expectEqual(@as(i64, -1), fold(.bitnot, &.{i(0)}).?.int);
    // §4.3.2 folds, and `fi_cast` rounds half away from zero.
    try std.testing.expectEqual(@sin(@as(f64, 0.5)), fold(.sin, &.{.{ .real = 0.5 }}).?.real);
    try std.testing.expectEqual(@as(i64, -3), fold(.fi_cast, &.{.{ .real = -2.5 }}).?.int);
    try std.testing.expectEqual(@as(?Const, null), fold(.path_prev, &.{.{ .real = 1 }}));
}

test "opcode: each row's flags agree with the LRM typing and its fold's shape" {
    // The comptime block above is the check; this pins the spec cases it
    // must classify, so a table edit that keeps the relations but moves a
    // row out of its clause still fails.
    // §4.2.5/§4.2.7: every comparison is a predicate with a relation.
    for ([_]Opcode{ .flt, .fgt, .fle, .fge, .feq, .fne, .ilt, .igt, .ile, .ige, .ieq, .ine }) |op| {
        try std.testing.expect(get(op).predicate);
        try std.testing.expect(get(op).rel != null);
        try std.testing.expect(isInteger(op));
    }
    // §4.2.8: `!` is a predicate without a relation; `&&`/`||` are 0/1, no predicate.
    try std.testing.expect(get(.lognot).predicate and get(.lognot).rel == null);
    try std.testing.expect(get(.logand).bool01 and !get(.logand).predicate);
    // §4.3.1/§4.3.2: math is real even over integers.
    for ([_]Opcode{ .sqrt, .exp, .pow, .sin, .atan2, .hypot }) |op| try std.testing.expect(!isInteger(op));
    // The class column agrees with the operand count `emit` asserts.
    try std.testing.expectEqual(OpClass.binary, class(.pow));
    try std.testing.expectEqual(@as(?u8, 3), operandCount(class(.store)));
    try std.testing.expectEqual(@as(?u8, null), operandCount(class(.call)));
}

test "fold: hand-derived values for every operator family" {
    const t = std.testing;
    const i = struct {
        fn c(v: i64) Const {
            return .{ .int = v };
        }
    }.c;
    const f = struct {
        fn c(v: f64) Const {
            return .{ .real = v };
        }
    }.c;
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    // §3.2 32-bit integers: 2147483647 + 1 = -2^31, and 65536 * 65536 = 2^32 ≡ 0.
    try t.expectEqual(@as(i64, -2147483648), fold(.iadd, &.{ i(2147483647), i(1) }).?.int);
    try t.expectEqual(@as(i64, 0), fold(.imul, &.{ i(65536), i(65536) }).?.int);
    try t.expectEqual(@as(i64, 2147483647), fold(.isub, &.{ i(-2147483648), i(1) }).?.int);
    // §4.2.4: integer `/` truncates toward zero (-7 / 2 = -3), `%` takes the
    // dividend's sign (-7 % 2 = -1), and a zero divisor has no value.
    try t.expectEqual(@as(i64, -3), fold(.idiv, &.{ i(-7), i(2) }).?.int);
    try t.expectEqual(@as(i64, -1), fold(.imod, &.{ i(-7), i(2) }).?.int);
    try t.expectEqual(@as(?Const, null), fold(.imod, &.{ i(1), i(0) }));
    // -2^31 / -1 overflows 32 bits and wraps back to -2^31.
    try t.expectEqual(@as(i64, -2147483648), fold(.idiv, &.{ i(-2147483648), i(-1) }).?.int);
    // Real `%`: -7.5 % 2 = -1.5; by zero has no value. Real `/` by zero is
    // IEEE +inf: the domain table leaves `fdiv` unrestricted.
    try t.expectEqual(@as(f64, -1.5), fold(.fmod, &.{ f(-7.5), f(2) }).?.real);
    try t.expectEqual(@as(?Const, null), fold(.fmod, &.{ f(1), f(0) }));
    try t.expectEqual(inf, fold(.fdiv, &.{ f(1), f(0) }).?.real);
    try t.expectEqual(@as(f64, -0.5), fold(.fneg, &.{f(0.5)}).?.real);
    // An integer opcode first rounds a real operand as `fi_cast` does:
    // 2.5 → 3, so 2.5 + 2 = 5; and 1.4 → 1 < 1.5 → 2.
    try t.expectEqual(@as(i64, 5), fold(.iadd, &.{ f(2.5), i(2) }).?.int);
    try t.expectEqual(@as(i64, 1), fold(.ilt, &.{ f(1.4), f(1.5) }).?.int);
    // §4.2.5/§4.2.7: comparisons are integer 0/1; NaN equals nothing.
    try t.expectEqual(@as(i64, 1), fold(.flt, &.{ i(1), f(1.5) }).?.int);
    try t.expectEqual(@as(i64, 0), fold(.feq, &.{ f(nan), f(nan) }).?.int);
    try t.expectEqual(@as(i64, 1), fold(.fne, &.{ f(nan), f(nan) }).?.int);
    try t.expectEqual(@as(i64, 1), fold(.ige, &.{ i(3), i(3) }).?.int);
    // §4.2.8 logical operators over any nonzero operand.
    try t.expectEqual(@as(i64, 1), fold(.logand, &.{ f(0.5), i(-3) }).?.int);
    try t.expectEqual(@as(i64, 0), fold(.logor, &.{ f(0), i(0) }).?.int);
    try t.expectEqual(@as(i64, 1), fold(.lognot, &.{f(0)}).?.int);
    // §4.2.9 bitwise: 1100 ^ 1010 = 0110, and xnor is its complement.
    try t.expectEqual(@as(i64, 0b0110), fold(.bitxor, &.{ i(0b1100), i(0b1010) }).?.int);
    try t.expectEqual(@as(i64, -7), fold(.bitxnor, &.{ i(0b1100), i(0b1010) }).?.int);
    try t.expectEqual(@as(i64, 0b1000), fold(.bitand, &.{ i(0b1100), i(0b1010) }).?.int);
    try t.expectEqual(@as(i64, 0b1110), fold(.bitor, &.{ i(0b1100), i(0b1010) }).?.int);
    // §4.2.11 at 32 bits: 1 << 31 is negative, 1 << 32 is 0, `>>` fills zeros.
    try t.expectEqual(@as(i64, -2147483648), fold(.shl, &.{ i(1), i(31) }).?.int);
    try t.expectEqual(@as(i64, 0), fold(.shl, &.{ i(1), i(32) }).?.int);
    try t.expectEqual(@as(i64, 0x7fff_ffff), fold(.shr, &.{ i(-1), i(1) }).?.int);
    // §4.3.1 "min(x,y) is equivalent to (x < y) ? x : y": a NaN x yields y,
    // a NaN y yields the NaN.
    try t.expectEqual(@as(f64, 1), fold(.fmin, &.{ f(nan), f(1) }).?.real);
    try t.expect(std.math.isNan(fold(.fmin, &.{ f(1), f(nan) }).?.real));
    try t.expectEqual(@as(f64, 1), fold(.fmax, &.{ f(nan), f(1) }).?.real);
    // Integer forms stay integer; |-2^31| wraps to -2^31 at 32 bits.
    try t.expectEqual(@as(i64, -2147483648), fold(.iabs, &.{i(-2147483648)}).?.int);
    try t.expectEqual(@as(i64, -3), fold(.imin, &.{ i(-3), i(2) }).?.int);
    try t.expectEqual(@as(i64, 2), fold(.imax, &.{ i(-3), i(2) }).?.int);
    // §4.2.1.3 integer `**`: 2 ** 10 = 1024, and 0 ** -1 has no value.
    try t.expectEqual(@as(i64, 1024), fold(.ipow, &.{ i(2), i(10) }).?.int);
    try t.expectEqual(@as(?Const, null), fold(.ipow, &.{ i(0), i(-1) }));
    // §4.3.1 math is real even over integers: sqrt(4) = 2.0 (IEEE sqrt is
    // exact here), hypot(3, 4) = 5, and Table 4-14's `log` is decimal.
    try t.expectEqual(@as(f64, 2), fold(.sqrt, &.{i(4)}).?.real);
    try t.expectApproxEqAbs(@as(f64, 5), fold(.hypot, &.{ i(3), i(4) }).?.real, 1e-15);
    try t.expectApproxEqAbs(@as(f64, 3), fold(.log10, &.{f(1000)}).?.real, 1e-15);
    // §4.2.1.1: ties away from zero, saturating, NaN → 0 (`lossyCast`).
    try t.expectEqual(@as(i64, 3), fold(.fi_cast, &.{f(2.5)}).?.int);
    try t.expectEqual(@as(i64, -3), fold(.fi_cast, &.{f(-2.5)}).?.int);
    try t.expectEqual(@as(i64, 0), fold(.fi_cast, &.{f(nan)}).?.int);
    try t.expectEqual(@as(i64, std.math.maxInt(i64)), fold(.fi_cast, &.{f(inf)}).?.int);
    try t.expectEqual(@as(f64, 7), fold(.if_cast, &.{i(7)}).?.real);
    // `opt_barrier` and `dstop` are the operand's value.
    try t.expectEqual(@as(f64, 0.25), fold(.opt_barrier, &.{f(0.25)}).?.real);
    try t.expectEqual(@as(i64, 4), fold(.dstop, &.{i(4)}).?.int);
    // Not values of their operands: latches, select, arrays, phis, calls.
    for ([_]Opcode{ .path_prev, .path_acc, .select, .anew, .fload, .iload, .store, .phi, .call }) |op|
        try t.expectEqual(@as(?Const, null), fold(op, &.{ f(1), f(1), f(1) }));
}

test "fold: a string is not an operand of any opcode" {
    // §4.2.1.1/§4.2.1.2 convert between integer and real only; lowering
    // converts a §2.7 string before it reaches an opcode, so a string here
    // has no value to fold to.
    const s: Const = .{ .str = "abc" };
    const one: Const = .{ .real = 1 };
    try std.testing.expectEqual(@as(?Const, null), fold(.fi_cast, &.{s}));
    try std.testing.expectEqual(@as(?Const, null), fold(.if_cast, &.{s}));
    try std.testing.expectEqual(@as(?Const, null), fold(.fadd, &.{ s, one }));
    try std.testing.expectEqual(@as(?Const, null), fold(.ieq, &.{ one, s }));
    try std.testing.expectEqual(@as(?Const, null), fold(.exp, &.{s}));
    try std.testing.expectEqual(@as(?Const, null), fold(.lognot, &.{s}));
}

test label {
    // Table 4-14's `log` is the decimal logarithm, MIR's `log10`.
    try std.testing.expectEqualStrings("log()", label(.log10));
    try std.testing.expectEqualStrings("sqrt()", label(.sqrt));
    try std.testing.expectEqualStrings("fadd", label(.fadd));
}
