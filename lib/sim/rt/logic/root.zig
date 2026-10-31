//! The four-state operators the emitted expressions call as `L.<name>` (`sim.rt.logic`): every name of the four files below, re-exported because the emitted code's text names them here (src/codegen/digital/emit_expr.zig). A rename is a golden change.
//! Cites: none here; each file's header names its clauses.
//!
//! Contents:
//! - `pub const two`
//! - `pub const W`
//! - `pub const Bit`
//! - `pub const Wide`
//! - `pub const words`
//! - `pub const T`
//! - `pub const M`
//! - `pub const wide`
//! - `pub const full`
//! - `pub const xs`
//! - `pub const span`
//! - `pub const mask`
//! - `pub const k`
//! - `pub const low`
//! - `pub const rs`
//! - `pub const ctx`
//! - `pub const planesOf`
//! - `pub const Bitwise`
//! - `pub const Shift`
//! - `pub const Relational`
//! - `pub const Equality`
//! - `pub const Reduction`
//! - `pub const Logical`
//! - `pub const not`
//! - `pub const neg`
//! - `pub const bitwise`
//! - `pub const arith`
//! - `pub const pow`
//! - `pub const shift`
//! - `pub const rel`
//! - `pub const eq`
//! - `pub const reduce`
//! - `pub const truth`
//! - `pub const invert`
//! - `pub const logical`
//! - `pub const cond`
//! - `pub const toReal`
//! - `pub const wordsToReal`
//! - `pub const ofReal`
//! - `pub const ofRealTo`
//! - `pub const rtoi`
//! - `pub const itorReal`
//! - `pub const realBits`
//! - `pub const real`
//! - `pub const word0`
//! - `pub const realCond`
//! - `pub const realTruth`
//! - `pub const CaseKind`
//! - `pub const join`
//! - `pub const asInt`
//! - `pub const asIndex`
//! - `pub const bitAt`
//! - `pub const selectShift`
//! - `pub const partAt`
//! - `pub const part`
//! - `pub const field`
//! - `pub const place`
//! - `pub const up`
//! - `pub const bit`
//! - `pub const pos`
//! - `pub const rep`
//! - `pub const clog2`
//! - `pub const caseMatch`

const values = @import("values.zig");
const operators = @import("operators.zig");
const reals = @import("reals.zig");
const selects = @import("selects.zig");

/// `vera --emit-exe --two-state`: not IEEE 1364 §3.2/§4.1 4-state logic.
pub const two = values.two;
/// A value of at most 64 bits as two planes, VPI-encoded per bit: (v, x) =
pub const W = values.W;
/// One bit, as `Integer.Bit` encodes it: `v | x << 1`.
pub const Bit = values.Bit;
/// A value of more than 64 bits: `n` words per plane, least significant
pub const Wide = values.Wide;
/// The words per plane of a `w`-bit value.
pub const words = values.words;
/// The type a `w`-bit value is carried in.
pub const T = values.T;
/// The type of a `w`-bit plane mask: what `State.put` takes beside a `T(w)`.
pub const M = values.M;
/// `a` as words, one when it is a `W`.
pub const wide = values.wide;
/// Every bit of a `w`-bit value.
pub const full = values.full;
/// A `w`-bit value of all x; all 0 under `--two-state`.
pub const xs = values.xs;
/// Bits `[lo, hi)` of word `j`, clamped to the word.
pub const span = values.span;
/// The mask of a `w`-bit value. Asserts at comptime that `w` is 1 to 64.
pub const mask = values.mask;
/// A `W` from its two planes; the caller keeps bits above the width 0.
pub const k = values.k;
/// Bit 0 of a `W` or a `Wide`: the bit an edge is of (§9.7.2).
pub const low = values.low;
/// `Literal.resize`: truncate, or extend by `sign` (per plane, so a top x
pub const rs = values.rs;
/// A one-bit result in its context (`evaluate.scalarContext`).
pub const ctx = values.ctx;
/// Both planes of `a`, values first: an `Integer.Literal`'s `planes`.
pub const planesOf = values.planesOf;
/// §5.1.10's binary bitwise operators, Tables 5-12 to 5-15.
pub const Bitwise = operators.Bitwise;
/// §5.1.12's four shift operators.
pub const Shift = operators.Shift;
/// §5.1.7's four relational operators.
pub const Relational = operators.Relational;
/// §5.1.8: logical (`==`, `!=`) and case (`===`, `!==`) equality.
pub const Equality = operators.Equality;
/// §5.1.11's six reduction operators.
pub const Reduction = operators.Reduction;
/// §5.1.9's binary logical operators `&&` and `||`.
pub const Logical = operators.Logical;
/// §5.1.10 Table 5-16 `~`: x and z bits invert to x.
pub const not = operators.not;
/// Any unknown bit makes all of it x.
pub const neg = operators.neg;
/// `a op b` per bit (§5.1.10): a known 0 decides `&`, a known 1 decides
pub const bitwise = operators.bitwise;
/// `Literal.arithmetic` at one word: any unknown bit, and `/` or `%` by 0,
pub const arith = operators.arith;
/// `Literal.power`: the base in context, the exponent self-determined
pub const pow = operators.pow;
/// `Literal.shift`: an unknown amount is all x; an amount of at least the
pub const shift = operators.shift;
/// Any unknown bit makes the relation x (§5.1.7).
pub const rel = operators.rel;
/// Both operands already in their common type (§5.1.8).
pub const eq = operators.eq;
/// §5.1.11 Tables 5-17 to 5-19: one bit from every bit of the `w`-bit `a`; a
pub const reduce = operators.reduce;
/// §5.1.9: any known 1 makes it true, even beside x or z.
pub const truth = operators.truth;
/// §5.1.9 `!` of one truth: x and z are x.
pub const invert = operators.invert;
/// `Literal.logical` of two one-bit truths.
pub const logical = operators.logical;
/// §5.1.13 Table 5-21: under an ambiguous condition only matching known
pub const cond = operators.cond;
/// §4.8.2 integer to real (`evaluate.realOfInt`): the value read by its own
pub const toReal = reals.toReal;
/// §4.8.2 integer to real at any width: the `width`-bit value in `v` (bits
pub const wordsToReal = reals.wordsToReal;
/// §4.8.2 real to integer (`evaluate.intOfReal`): rounded to nearest, halves
pub const ofReal = reals.ofReal;
/// §4.8.2 real to a `to`-bit integer (`evaluate.intOfReal`, then the
pub const ofRealTo = reals.ofRealTo;
/// §17.8 `$rtoi`: truncated toward zero, a 32-bit signed value, the low 32
pub const rtoi = reals.rtoi;
/// §17.8 `$itor` of a real argument (VD-130): the argument converts to an
pub const itorReal = reals.itorReal;
/// A real as the 64-bit value a real slot holds: its IEEE 754 bits.
pub const realBits = reals.realBits;
/// The real a real slot's value holds.
pub const real = reals.real;
/// The least significant word of `a`'s value plane (`$bitstoreal`).
pub const word0 = reals.word0;
/// §5.1.13 a real `?:` under an x or z condition is always zero, after
pub const realCond = reals.realCond;
/// A real's truth (§9.4): not zero.
pub const realTruth = reals.realTruth;
/// §9.5 `case` and §9.5.1's `casez` and `casex`.
pub const CaseKind = selects.CaseKind;
/// `{hi, lo}`, `hi` being `hw` bits wide and `lo` `lw`.
pub const join = selects.join;
/// The integer a self-determined index reads as, or null when it has an
pub const asInt = selects.asInt;
/// The full numeric index, retaining bases just outside an i64 declaration
pub const asIndex = selects.asIndex;
/// `exec.position` then `readSelect` of one bit: bit `index` of a vector
pub const bitAt = selects.bitAt;
/// The least-significant storage position of an indexed part-select.
pub const selectShift = selects.selectShift;
/// A runtime part-select, all x for an x/z base (§5.2.1).
pub const partAt = selects.partAt;
/// A constant or runtime part-select of an `sw`-bit vector:
pub const part = selects.part;
/// The slot bits a part-select of `count` bits at `shift` names
pub const field = selects.field;
/// The inverse of `part` for an assignment: `a`'s `count` bits placed at
pub const place = selects.place;
/// The one-bit `a` moved up to bit `p` of an `sw`-bit vector: a runtime
pub const up = selects.up;
/// Bit `p` alone of an `sw`-bit vector: a runtime bit-select's mask.
pub const bit = selects.bit;
/// The bit position a runtime bit-select names, or null (`exec.position`).
pub const pos = selects.pos;
/// §5.1.14 `{count{a}}`.
pub const rep = selects.rep;
/// §17.11 `$clog2` of a self-determined operand, x/z read as 0 (`exec`'s
pub const clog2 = selects.clog2;
/// §9.5 / §9.5.1: `case` is `===`; casez/casex skip z (and x) bits of
pub const caseMatch = selects.caseMatch;

test {
    _ = values;
    _ = operators;
    _ = reals;
    _ = selects;
}
