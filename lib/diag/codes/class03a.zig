//! The diagnostic catalogue's class 3 rows, types, disciplines and declarations, part a:
//! `E0301` .. `E0335`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .E0301 = retired_e0301_e0302,
    .E0302 = retired_e0301_e0302,
    .E0303 = .{
        .title = "aliasparam target is not a parameter",
        .lrm = "3.4.7",
        .explain =
        \\`aliasparam` gives a second name to an existing parameter, so its
        \\target must be a parameter declared in the same module.
        \\
        \\LRM 3.4.7 adds two rules worth knowing: the alias identifier
        \\"shall not occur anywhere else in the module", and it is an error
        \\to override one parameter through both its original name and an
        \\alias.
        ,
    },
    .E0304 = retired_e0304_e0305,
    .E0305 = retired_e0304_e0305,
    .E0306 = .{
        .title = "expected a net identifier",
        .lrm = "3.12",
        .explain =
        \\A branch declaration names one or two nets:
        \\
        \\    branch (a, b) ab;      // between two nets
        \\    branch (a)    a_gnd;   // net to ground
        \\
        \\Expressions, constants and ports-by-index are not net names.
        ,
    },
    .E0307 = .{
        .title = "array has no declared dimensions",
        .lrm = "3.2",
        .explain =
        \\An array needs at least one declared range. VerA supports
        \\multiple dimensions; this diagnostic reports missing dimensions
        \\where array storage was required.
        ,
    },
    .E0308 = .{
        .title = "array bound is not a constant expression",
        .lrm = "3.2",
        .explain =
        \\LRM 3.2 requires both bounds of an array declaration to be
        \\constant expressions. They may depend on parameters, but not
        \\on variables or probes. This rule concerns the declared range,
        \\not an index used to read or write an element at runtime.
        ,
    },
    .E0309 = .{
        .title = "identifier is not an array",
        .lrm = "3.2",
        .explain =
        \\This name was indexed with `[...]` but was declared as a scalar.
        \\Check for a shadowing declaration in an inner block.
        ,
    },
    .E0310 = .{
        .title = "array index is out of bounds",
        .lrm = "3.2",
        .explain =
        \\This constant index lies outside the declared range. VerA
        \\diagnoses an out-of-range index when it can resolve that index
        \\at compile time. Array accesses may also use runtime indices;
        \\this diagnostic does not require every index to be constant.
        ,
    },
    .E0311 = .{
        .title = "array index is not a constant expression",
        .lrm = "3.2",
        .explain =
        \\This use of an array element as a target requires a constant
        \\index in VerA. Other array reads and assignments support runtime
        \\indices. This restriction is separate from LRM 3.2's requirement
        \\that the bounds in an array declaration be constant.
        \\
        \\A genvar index works: genvar loops are unrolled (LRM 6.6.1), so
        \\the index is constant in each unrolled copy.
        ,
    },
    .E0312 = .{
        .title = "cannot assign to a parameter",
        .lrm = "3.4",
        .explain =
        \\Parameters are constants of an instance: they are set by the
        \\model card or by a defparam before the analog block runs, and
        \\stay fixed for the whole solve.
        \\
        \\Declare a `real` or `integer` variable for a value that changes.
        ,
    },
    .E0313 = .{
        .title = "unknown variable",
        .lrm = "6.8",
        .explain =
        \\No variable, parameter or genvar with this name is visible here.
        \\Verilog-A scopes are lexical: a name declared inside a named
        \\block (LRM 5.3.2) is not visible outside it.
        ,
    },
    .E0314 = .{
        .title = "unknown identifier",
        .lrm = "6.8",
        .explain =
        \\Nothing with this name is declared in scope — not a variable, a
        \\parameter, a net, a branch, a discipline, or a function.
        ,
    },
    .E0315 = .{
        .title = "net must be read through an access function",
        .lrm = "4.4",
        .explain =
        \\A net names a point in a conservative system, not a number. Ask
        \\for one of its two signals explicitly:
        \\
        \\    V(n)      potential of n relative to ground
        \\    V(a, b)   potential across the branch a-b
        \\    I(a, b)   flow through the branch a-b
        \\
        \\LRM 4.4 also forbids `V(n1, n1)`: a flow access whose two net
        \\expressions name the same signal has no branch to flow through.
        ,
    },
    .E0316 = .{
        .title = "unsupported assignment target",
        .lrm = "5.7",
        .explain =
        \\LRM 5.7: "The left-hand side of a procedural assignment shall be
        \\scalar, either an integer, real, or string identifier or an
        \\element of an integer, real or string array" — a variable, or one
        \\element of a scalarized array.
        \\
        \\A `reg` of any width, or a bit, part or element of one, is none of
        \\these: its contents are "calculated in the discrete domain"
        \\(§7.2.1), and the analog side may read it but not write it (§7.3).
        ,
    },
    .E0317 = .{
        .title = "a concatenation is not an assignment target",
        .lrm = "5.7",
        .explain =
        \\A concatenation builds a value; it does not name storage. LRM
        \\4.2.13 makes the related rule explicit for replications:
        \\"expressions containing replications shall not appear on the
        \\left-hand side of an assignment".
        \\
        \\Assign to each variable separately.
        ,
    },
    .E0318 = .{
        .title = "bitwise operator requires integer operands",
        .lrm = "4.2.9",
        .explain =
        \\LRM 4.2.1: with a real operand "all other operators are
        \\considered illegal" — bitwise and reduction operators among them.
        \\A real is an IEEE double whose bit pattern is not a modelled
        \\value in Verilog-A.
        \\
        \\Convert explicitly if that is really the intent; LRM 4.2.1.1
        \\rounds a real to integer, away from zero on an exact .5.
        ,
    },
    .E0319 = .{
        .title = "reduction operator requires an integer operand",
        .lrm = "4.2.10",
        .explain =
        \\A reduction folds an operand's bits into one bit, so the operand
        \\must have bits. See E0318.
        ,
    },
    .E0320 = .{
        .title = "xor reductions cannot be used inside the analog block",
        .lrm = "4.2.10",
        .explain =
        \\`^`, `~^` and `^~` as unary reductions are reduction operators,
        \\and LRM 4.2.10 says "The reduction operators can not be used
        \\inside the analog block". Compute the parity you need
        \\arithmetically, or with the binary bitwise operators, which are
        \\supported on integers.
        ,
    },
    .E0321 = .{
        .title = "arithmetic on a string operand",
        .lrm = "3.3",
        .explain =
        \\Strings are message and file-name payloads. They compare and
        \\concatenate; they do not take part in arithmetic.
        \\
        \\LRM 3.3 Table 3-3 defines ==, !=, <, <=, >, >=, concatenation
        \\and replication on the string type, each between two strings or
        \\a string and a string literal, and "A string cannot be assigned to
        \\an integral type". So `s + 1` and `s == 65` are errors for a
        \\string variable or parameter `s`. A string LITERAL is still the
        \\Verilog packed integer of its bytes: `"A" + 1` is 66.
        \\
        \\LRM 3.4: "It shall be an error to assign a numeric value to a
        \\parameter declared as string or to assign a string value to a
        \\real parameter."
        ,
    },
    .E0322 = .{
        .title = "bitwise and shift operators require integer operands",
        .lrm = "4.2.9",
        .explain =
        \\See E0318. Shifts additionally need an integer shift count: a
        \\fractional shift distance has no meaning.
        ,
    },
    .E0323 = retiredInfo(
        \\"case equality is not in the analog subset". Retired: annex C.5
        \\removes `===` and `!==` from the Verilog-A SUBSET only, and 7.3.2
        \\lists both among the features Verilog-AMS supports in the analog
        \\context. On two-state operands they now lower as `==` and `!=`.
        \\
        \\What replaced it: E0369, for a case comparison with a real operand
        \\(4.2.1). The number is not reused.
    ),
    .E0324 = .{
        .title = "arithmetic shifts cannot be used in an analog block",
        .lrm = "4.2.11",
        .explain =
        \\`<<<` and `>>>` are the arithmetic shift operators of IEEE 1364.
        \\LRM 4.2.11: "The arithmetic shift operators can not be used in an
        \\analog block." Use `<<` and `>>`.
        ,
    },
    .E0325 = retiredInfo(
        \\"operator is not in the analog subset". Retired: nothing emits it.
        \\Its one emitter was lowerBinary's dead `else`, reachable only for
        \\`&&` and `||`, which return earlier; d19a227 made that switch
        \\exhaustive and removed it. The number is not reused.
    ),
    .E0326 = .{
        .title = "empty concatenation",
        .lrm = "4.2.13",
        .explain = "`{}` has no operands, so it has no width and no value.",
    },
    .E0327 = .{
        .title = "concatenation operand has no bit width",
        .lrm = "4.2.13",
        .explain =
        \\LRM 4.2.13 accepts only sized constants (LRM 2.6.1), strings
        \\(LRM 3.3) and integer function calls (LRM 4.7.1, 32 bits) as
        \\concatenation operands, because the result width is the sum of
        \\the operand widths.
        \\
        \\A replication constant must additionally be "a non-negative,
        \\non-x and non-z constant expression".
        ,
    },
    .E0328 = retiredInfo(
        \\"string concatenation with a run-time operand is not supported".
        \\Retired: 3.3 Table 3-3 makes both a string-typed concatenation
        \\operand and a nonconstant replication multiplier legal, and the
        \\device now builds such a string while it runs (`$str$cat`,
        \\`$str$repeat`, str_store.zig). A nonconstant multiplier that is
        \\not of integral type is E0327. The number is not reused.
    ),
    .E0329 = .{
        .title = "a select or operand the analog context cannot size",
        .lrm = "7.3.1",
        .explain =
        \\7.3.1 Table 7-1 lets the analog context read a bit grouping of a
        \\`reg` as an integer, and a `reg` wider than 32 bits that the
        \\analog context assigns holds every bit IEEE 1364-2005 5.4 gives
        \\it. Each form refused here has no width VerA can compute in the
        \\analog context: an indexed part-select `x[i +: w]`, a select whose
        \\bounds are not constant, a part-select used as a value on its own,
        \\a concatenation or a string in the right-hand side of a wide
        \\`reg`, an unsized constant past 32 bits, a parameter past the
        \\64 bits its `Model` field holds, a conditional write (a scan task's
        \\target) or a digital read of a wide `reg` the analog context
        \\computes, and a select past bit 31 under an explicit D2A event,
        \\whose region-1b copy holds bits 0 to 31. Write a constant select,
        \\or size the operand.
        ,
    },
    .E0330 = .{
        .title = "unsupported index expression",
        .lrm = "3.2",
        .explain =
        \\The base of an array index must resolve to a declared array
        \\name, with one subscript per dimension. Runtime indices are
        \\supported for variable arrays. See E0309, E0310 and E0311 for
        \\the specific name, bounds and target restrictions.
        ,
    },
    .E0331 = .{
        .title = "aliasparam name is already a parameter",
        .lrm = "3.4.7",
        .explain =
        \\LRM 3.4.7: "The alias_identifier shall not occur anywhere else in
        \\the module; in particular, it shall not conflict with a different
        \\parameter_identifier".
        \\
        \\An `aliasparam` is a second NAME for one parameter, not a second
        \\parameter. Pointing it at a name that is already declared silently
        \\rebinds that name for the rest of the module, so
        \\
        \\    parameter real a = 1.0;
        \\    parameter real b = 7.0;
        \\    aliasparam a = b;
        \\    analog I(p,n) <+ V(p,n) * a;    // reads b: gain 7, not 1
        \\
        \\computes with `b` while the source says `a`, and the model card's
        \\`a` field becomes dead — writing it changes nothing.
        \\
        \\Rename the alias, or delete the parameter it collides with.
        ,
    },
    .E0373 = .{
        .title = "aliasparam name used in an expression",
        .lrm = "3.4.7",
        .explain =
        \\An alias supplies an alternate name for parameter overrides.
        \\The equations must reference the original parameter name, not
        \\the alias. This also applies to constant expressions, unused
        \\branches and hierarchical references. Bind through the alias
        \\in an instance, paramset, defparam or host model card, and read
        \\the original name in expressions.
        ,
    },
    .E0332 = .{
        .title = "base nature is missing a required attribute",
        .lrm = "3.6.1.2",
        .explain =
        \\LRM 3.6.1: "Each nature definition ... shall include all the
        \\required attributes specified in 3.6.1.2", and 3.6.1.2 says of
        \\abstol, access and units that each "is required for all base
        \\natures".
        \\
        \\    nature Voltage;
        \\      units  = "V";
        \\      access = V;
        \\      abstol = 1e-6;
        \\    endnature
        \\
        \\A nature that means to inherit them is a DERIVED nature and says
        \\so with a parent: `nature High_Voltage : Voltage;`.
        ,
    },
    .E0333 = .{
        .title = "derived nature redefines `units`",
        .lrm = "3.6.1.2",
        .explain =
        \\LRM 3.6.1.2, units: "It is illegal for a derived nature to define
        \\or change the units; the derived nature always inherits its parent
        \\nature units."
        \\
        \\Units are what makes the parent's tolerance and the child's
        \\comparable at all, so a child in different units is not a
        \\refinement of its parent — it is a different quantity, and wants a
        \\base nature of its own.
        \\
        \\Contrast abstol, which 3.6.1.2 explicitly allows a derived nature
        \\to change.
        ,
    },
    .E0334 = .{
        .title = "derived nature changes `access`",
        .lrm = "3.6.1.2",
        .explain =
        \\LRM 3.6.1.2, access: "It is illegal for a derived nature to change
        \\the access attribute; the derived nature always inherits the
        \\access attribute of its parent nature."
        \\
        \\The access function is how source text names the quantity (LRM
        \\4.4). A derived nature narrows the TOLERANCE of its parent's
        \\quantity, not its spelling, so `V(n)` keeps working on a net whose
        \\discipline binds the derived nature.
        ,
    },
    .E0335 = .{
        .title = "two base natures share an access function",
        .lrm = "3.13.2",
        .explain =
        \\LRM 3.13.2: "the access function of each base nature shall be
        \\unique". The name in an access function call (LRM 4.4) has to
        \\identify one nature, and with two claiming it there is no reading
        \\of `MyAccess(n)` that a compiler could pick.
        \\
        \\Two natures that are meant to be the same quantity are spelled as
        \\one base nature plus a derived nature (LRM 3.6.1.1), which
        \\inherits the access name instead of re-declaring it.
        ,
    },
};

/// E0301, E0302: one retirement, one explanation.
const retired_e0301_e0302 = retiredInfo(
    \\"vector ports are not supported" (E0301) and "vector nets are not
    \\supported" (E0302). Both retired: 3.6.3 vector nets and 6.5.2
    \\vector ports now elaborate. Each element becomes its own solver
    \\unknown, named `p[0]`, so the flat node list never learns about
    \\ranges and nothing downstream changed.
    \\
    \\What replaced them: E0350 for 6.5.2.2 (the port's two declarations
    \\give different ranges), E0351 and E0352 for the element reference
    \\itself. The numbers are not reused.
);

/// E0304, E0305: one retirement, one explanation.
const retired_e0304_e0305 = retiredInfo(
    \\"port branches are not supported" (E0304) and "branch arrays are
    \\not supported" (E0305). Both retired: 3.12.1 `branch (<p>) name;`
    \\resolves to the same 5.4.3 port-flow unknown `I(<p>)` reads, and
    \\A.2.3 `branch (p, n) pair[0:1];` expands into one branch per
    \\element registered under the scalarised name `pair[k]`.
    \\
    \\What replaced them: nothing for the declarations, which are legal.
    \\A port branch left of `<+` is E0407 (5.4.3 forbids the position,
    \\not the name); an out-of-range element is E0352 and the bare base
    \\name is E0351, both shared with vector nets.
);
