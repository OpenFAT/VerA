// Shared self-check macros for the exhaustive testbenches. LRM §10.4 `define.
//
// A fixture states its OWN expectation and prints the comparison, so the golden
// transcript is readable rather than merely diffable:
//
//     `CHECK("tanh(0.5)", tanh(0.5), 0.46211715726000974, 1e-15);
//     -> tanh(0.5) got=0.46211715726 want=0.46211715726 ok=1
//
// The trailing `;` is the CALL SITE's, as it is for every Verilog macro: a
// `define expands to text, and §5.1 wants a statement terminator.
//
// `ok=1` is the assertion. A reviewer checks the WANT column against the LRM or
// a reference implementation once; after that a regression turns `ok=1` into
// `ok=0` and the runner fails on the diff.
//
// WHY THE VERDICT IS A NUMBER AND NOT A BRANCH. `if (ok) $strobe("PASS")` now
// works — a guarded display is emitted inside its arm — but it is still the
// wrong shape for an assertion: a check that prints only when it PASSES is
// indistinguishable from a check that never ran, and the runner counts `ok=`
// columns. A comparison is an integer in Verilog-A (§4.2.5), so making the
// verdict an OPERAND makes every check announce itself either way.
//
// (Until 2026-09-20 it was also the only shape that worked: a task under a
// conditional was dropped with W0851, which no longer exists. Fixture comments
// citing that drop as current behaviour are stale, not wrong about their own
// history.)

`ifndef VERA_CHECK_VH
`define VERA_CHECK_VH

// GOT AND WANT ARE EXPANDED TWICE — once for the transcript column, once inside
// the verdict. §10.3 makes a macro textual substitution, and Verilog-A gives a
// macro no way to bind a temporary, so there is no spelling of these that
// evaluates its operand once.
//
// For a pure expression that is invisible. For one with a SIDE EFFECT it is
// not, and the failure is silent in the worst way: the value printed is not the
// value compared. §4.7.2's output/inout function arguments are the case that
// found this — `CHECKX("...", via_inout(d), 5.0)` calls the function twice, so
// the transcript read `got=5 want=5 ok=0`, and `d` came out 25 instead of 5.
//
// So: a GOT with a side effect must be bound to a variable first.
//
//     t = via_inout(d);
//     `CHECKX("return via inout argument", t, 5.0);
//
// The same applies to $random and to any analog function with an output or
// inout formal. Everything else in this suite is a pure function of the
// operating point and is unaffected.

`ifdef VERA_PERTURB
// `zig build suite -- --perturb[=d]` defines
// VERA_PERTURB to d and asks whether each check can FAIL: every want is moved
// by a relative d (by d itself at zero; by one for CHECKI), so a check that
// still prints ok=1 cannot see an error of that size in its own expectation.
// No `abs`: under `begin_keywords "1364-2005" there is none, and CHECKX and
// CHECKI must still expand there (ch10_directives/begin_keywords_verilog.va).
// Arithmetic, not `?:`: a CHECKEQ want may hold an analog operator, which
// §5.8.1 does not allow under a condition (E0514).
`define VERA_PW(WANT) ((WANT) * (1 + (`VERA_PERTURB)) + ((WANT) == 0) * (`VERA_PERTURB))
`define CHECK(NAME, GOT, WANT, TOL) \
  $strobe("%s got=%g want=%g ok=%d", NAME, GOT, `VERA_PW(WANT), (abs((GOT) - `VERA_PW(WANT)) <= (TOL)))
`define CHECKR(NAME, GOT, WANT, RTOL) \
  $strobe("%s got=%g want=%g ok=%d", NAME, GOT, `VERA_PW(WANT), \
          (abs((GOT) - `VERA_PW(WANT)) <= (RTOL) * (abs(`VERA_PW(WANT)) + 1e-30)))
`define CHECKX(NAME, GOT, WANT) \
  $strobe("%s got=%g want=%g ok=%d", NAME, GOT, `VERA_PW(WANT), ((GOT) == `VERA_PW(WANT)))
`define CHECKI(NAME, GOT, WANT) \
  $strobe("%s got=%0d want=%0d ok=%d", NAME, GOT, (WANT) + 1, ((GOT) == (WANT) + 1))
`define CHECKEQ(NAME, GOT, WANT, TOL) \
  $strobe("%s got=%g want=%g ok=%d", NAME, GOT, `VERA_PW(WANT), (abs((GOT) - `VERA_PW(WANT)) <= (TOL)))
`else
// A fixture that prints its own `ok=` (a $monitor or $debug report, which no
// CHECK can be) writes each literal want as `VERA_PW(want), so a perturbed
// run moves it as it moves a CHECK's.
`define VERA_PW(WANT) (WANT)

// Absolute tolerance. Use for values near or at zero.
`define CHECK(NAME, GOT, WANT, TOL) \
  $strobe("%s got=%g want=%g ok=%d", NAME, GOT, WANT, (abs((GOT) - (WANT)) <= (TOL)))

// Relative tolerance, for values whose magnitude is the point (currents that
// span decades, exponentials). `1e-30` floors the denominator so a want of zero
// does not divide by it.
`define CHECKR(NAME, GOT, WANT, RTOL) \
  $strobe("%s got=%g want=%g ok=%d", NAME, GOT, WANT, \
          (abs((GOT) - (WANT)) <= (RTOL) * (abs(WANT) + 1e-30)))

// Exact equality. For integers and for reals the LRM defines to the last bit
// (§4.2.1.1 conversions, §4.3.1 floor/ceil/abs, a literal round-trip).
`define CHECKX(NAME, GOT, WANT) \
  $strobe("%s got=%g want=%g ok=%d", NAME, GOT, WANT, ((GOT) == (WANT)))

// Integer form of the same, so the transcript shows `12` and not `12.0000`.
// `%0d`, because a bare `%d` pads to the operand's widest value (IEEE 1364
// §17.1.1.3: 11 columns for an `integer`); `ok=%d` of a comparison is one
// column either way.
`define CHECKI(NAME, GOT, WANT) \
  $strobe("%s got=%0d want=%0d ok=%d", NAME, GOT, WANT, ((GOT) == (WANT)))

// RELATIONAL, and deliberately a weaker claim than the four above.
//
// The others pin a value against a literal a human derived, so VerA cannot
// supply its own expectation. This one pins two VerA expressions against EACH
// OTHER, for the rules the LRM states as an identity with no value to write
// down: `V(br)` must equal `V(a,b)`, `$ln(x)` must equal `ln(x)`.
// Alias names are binding-only (§3.4.7); do not read one in a CHECKEQ.
//
// It is still restricting — a compiler that lowers the two sides differently
// fails it — but it is NOT independent: an error common to both sides passes.
// So it is a separate macro rather than a relaxation of `CHECK`, which keeps
// the weaker claims greppable and lets tests/suite.zig hold the strict
// literal rule everywhere else. Reach for it only when there is genuinely no
// literal to write; if you can write the digits, write the digits.
`define CHECKEQ(NAME, GOT, WANT, TOL) \
  $strobe("%s got=%g want=%g ok=%d", NAME, GOT, WANT, (abs((GOT) - (WANT)) <= (TOL)))
`endif

`endif
