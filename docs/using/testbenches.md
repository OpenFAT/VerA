# Testbenches and `//!` directives

`vera --emit-exe model.va` builds a **testbench**: the device, plus a
generated program that evaluates it at operating points and prints what it
reports. `vera --run model.va` builds it and runs it. The operating points
come from `//!` comment lines in the source, so a model file carries its own
test.

A `//!` line is a comment to every other tool (LRM §2.4). VerA reads them
from the raw source, before preprocessing, and refuses an unknown keyword, so
a typo cannot silently test nothing.

## What a testbench does

For a model with no digital half, the testbench steps a fixed grid:

1. It writes the model card: every parameter at its default, then each
   `//! param` (and each `--param` from the command line, which wins).
2. For each operating point (the cartesian product of the sweeps), and at each
   `//! time` point, it sets the unknowns: a `bias` or `sweep` value where one
   is given, Newton's solution for the rest under `//! solve`, and 0 V
   otherwise.
3. It calls the device, prints the device's own `$strobe`/`$display`
   output, then the residual and Jacobian at that point unless `//! print
   none` says not to.

A model with a digital half (LRM chapter 7) runs on the mixed-signal
scheduler instead, which inserts the time points events ask for; see
[Mixed signal](../learn/mixed-signal.md).

```verilog
{{#include ../examples/testbenches/residual.va}}
```

```console
{{#include ../examples/testbenches/residual.out}}
```

The residual is the current each unknown's row sums to (here 1 mA leaves `p`
and enters `n`), and the Jacobian is its derivative with respect to each
unknown. `--param` overrides a parameter for one run. Its value is a plain
number: a scale factor such as `4k` is source syntax (LRM §2.6.2), not a
command-line one, and VerA refuses it:

```console
{{#include ../examples/testbenches/param.out}}
```

## Sweeps

`//! sweep` lists values for one unknown; several sweeps multiply, the last
varying fastest:

```verilog
{{#include ../examples/testbenches/sweep.va}}
```

```console
{{#include ../examples/testbenches/sweep.out}}
```

The W0650 at the end is about speed, not the sweep: `limexp` is `exp` (LRM
§4.5.13), and nothing bounds its argument here, so the unit compiles in
strict float mode ([the diode](../learn/diode.md#limexp) says more).

## Time

`//! time` lists the `$abstime` values to step through (LRM §9.10), and makes
the analysis a transient one. Between points the testbench calls the
device's state update, so `ddt`, `idt` and the other operators of LRM §4.5
see history. `//! wave` gives an unknown one value per time point (a short
list holds its last value). The step is fixed backward Euler, with no
truncation-error control:

```verilog
{{#include ../examples/testbenches/rc.va}}
```

```console
{{#include ../examples/testbenches/rc.out}}
```

With τ = RC = 100 µs, the exact response at 100 µs is 1 − e⁻¹ ≈ 0.632;
backward Euler with a step of one time constant gives 0.5, and the error
shrinks as the step does. The testbench is for checking a model's equations,
not for accurate transients: that is your simulator's job.

## Self-checking testbenches

A check prints its own verdict as a number, `ok=1` or `ok=0`, rather than
printing only on success, so a check that never ran cannot pass. VerA's own
fixtures use the macros in
[`tests/fixtures/check.vh`](https://github.com/OmarSiwy/VerA/blob/main/tests/fixtures/check.vh)
(`CHECK` absolute tolerance, `CHECKR` relative, `CHECKX` exact, `CHECKI`
integer, `CHECKEQ` two expressions against each other); this one defines its
own:

```verilog
{{#include ../examples/testbenches/selfcheck.va}}
```

```console
{{#include ../examples/testbenches/selfcheck.out}}
```

## Directives the testbench reads

| Directive | Meaning |
|---|---|
| `//! param NAME = v, ...` | model-card values (LRM §3.4). A parameter that sizes an array or picks a generate arm is fixed at compile time from this value |
| `//! psweep NAME = v1, v2, ...` | sweep a parameter: each point gets its own card (LRM §6.3.4) |
| `//! bias V(a) = v, ...` | hold unknowns at fixed values for the whole run. Also `I(a,b)` for a branch flow |
| `//! sweep V(a) = v1, v2, ...` | sweep an unknown |
| `//! solve` | solve every unknown no other directive names, by Newton on the device's own residual (LRM §5.6). Without it, unnamed unknowns are tied to 0 |
| `//! time t0, t1, ...` | the `$abstime` grid; more than one point makes it a transient |
| `//! wave V(a) = v0, v1, ...` | one value per time point |
| `//! temp K` | `$temperature`, in kelvin (default 300.15) |
| `//! analysis KIND [NAME]` | the analysis `analysis()` sees (LRM §4.6.1): `static`, `ic`, `nodeset`, `dc`, `tran`, `ac`, `noise`; NAME is LRM §9.15's `analysis_name` |
| `//! plusargs +a +b=1` | the testbench's command line, for `$test$plusargs` (LRM §9.12) |
| `//! print none\|residual` | whether to print the residual and Jacobian after each point |
| `//! spice <card>` | an LRM Annex E SPICE card the source is compiled against, as `--spice` would read it |
| `//! discipline-resolution basic\|detail` | LRM §7.4.4's mode, as `--discipline-resolution` |
| `//! display record` | build the device with `--display=record`: it records its `$strobe` and other display output for the host, and the testbench prints the records (LRM §9.4) |

These assert what a device **publishes** to a host, and print a `got=/want=
ok=` line each: `//! noise` (the noise sources, LRM §4.6.4, with their
densities and, as `corr=<row>:<rho>`, the correlation coefficient between
two rows, LRM §4.6.4.6), `//! acstim` (AC stimuli, LRM §4.6.3), `//! acdyn`
(a small-signal admittance term), `//! qsite` (the charge sites and their
truncation-error flag, LRM §5.6.1.2), `//! seed` (the `$limit` cold-start
values, LRM §9.17.3), `//! abstol` (the tolerance of an unknown, LRM
§3.6.1.2), `//! meta` (the `desc` and `units` a declaration publishes, LRM
§2.9.2) and `//! limit` (a `$limit` clamp, old values to new). `noise`,
`acstim`, `qsite`, `seed` and `meta` also take `none`: the device publishes
no such row, which is a claim, where an absent directive claims nothing.
Their exact syntax is in the header of
[`src/codegen/exe/tb/directive.zig`](https://github.com/OmarSiwy/VerA/blob/main/src/codegen/exe/tb/directive.zig).

## Directives the fixture suite grades

VerA's own test suite (`zig build suite -- --strict`) runs every fixture
under `tests/fixtures/` through the same testbench and grades it by these.
`vera --run` ignores them; you need them only to contribute a fixture.

| Directive | Meaning |
|---|---|
| `//! reject SUBSTRING` | the source must fail to compile, with a diagnostic containing SUBSTRING (name the code: a bare `//! reject` matches anything) |
| `//! reject-only CODE` | as `reject`, and that diagnostic must be the only error, so the fixture isolates one rule |
| `//! neighbour FILE` | with a refusal: the legal variant of the same source, which must compile and pass. It tells a real restriction from a blanket refusal |
| `//! reject-run CODE` | the source compiles, and the *run* must refuse: exit nonzero (1 unless `//! exit` says) with an `error[` line containing CODE and no other |
| `//! warn SUBSTRING` | the compile must report a warning containing SUBSTRING, and still run |
| `//! nowarn` | the compile must report no warning |
| `//! checks N` | exactly N `ok=` verdicts must be printed, all `ok=1` |
| `//! exit N` | the testbench's expected exit status |
| `//! xfail REASON` | a known gap: the fixture states the LRM correctly and VerA does not meet it yet. The suite fails if it unexpectedly passes |
| `//! lrm 5.6.1` | the LRM clause the fixture tests, counted by `--coverage` |
| `//! lrm 5.6.1:2` | one normative sentence of the clause (the second), a row of the requirement ledger `tests/fixtures/conformance/OBLIGATIONS.tsv` |
| `//! inherited IEEE 1364-2005 9.2` | the same, for a clause the LRM inherits from IEEE 1364 |
| `//! fd-exempt REASON` | the derivative and finiteness certificates (`benchmark -- --certify`) do not apply, for the stated reason |

## Running a testbench by hand

`--emit-exe` prints the binary's path on stdout and diagnostics on stderr,
so the two can be captured apart:

```sh
P=$(vera --emit-exe model.va 2>/dev/null) && "$P"
```

The testbench is a Debug build by default (it compiles in seconds and runs
in microseconds, and safety checks turn a code-generation bug into a trap
rather than a wrong number); `--optimize=ReleaseFast` builds an optimised
one. `--validate-contract` also runs the device contract's conformance
checks inside it. The build goes under `.zig-cache/vera-tb`, or `--work-dir`.
