# A minimal host

This page builds the smallest useful simulator around a VerA device: a Zig
program that solves one DC operating point by Newton's method. Everything
else in this part of the book adds to this loop.

## The circuit

A 1 V source drives a diode through a 1 kΩ resistor. The resistor and the
source belong to the host; the diode is a Verilog-A model with its own series
resistance, so it has an internal node:

```text
1 V --[ R = 1 kΩ ]-- a --[ rs = 10 Ω ]-- ai --[ junction ]-- k = ground
                     \_____________ diode.va _____________/
```

```verilog
{{#include ../examples/host/diode.va}}
```

The device's unknowns are its two ports and its internal node,
`U = { a, k, ai }`. The host grounds `k` and solves for `a` and `ai`.

## The host

```zig
{{#include ../examples/host/host.zig}}
```

Step by step:

- **Opting in.** `vera_validate_contract` turns on the contract's
  conformance checks for this program, and `contract.validateHost` checks at
  compile time that the host meets what this device needs: here only
  `calls_setup`, because the device has a `setup`. Leave the declaration out
  and the build fails with an error saying so.
- **The families.** `S` is the reference family with one derivative lane
  per unknown it may carry: every value `eval` computes carries its partial with
  respect to `a`, `k` and `ai`. `Val` has no lanes; the card-time hooks take
  it. [Scalar families](families.md) explains both.
- **The card.** `Model` holds every parameter at its default. The host runs
  `derive` (when the device has one), `setup`, which fills `model.su` with
  the values that depend only on the card and its temperature, and
  `setupInstance` (when declared), in that order. Both card-time hooks take
  the family itself, `Val`, not a value type.
- **One evaluation per iterate.** `D.eval` returns one row per unknown: its
  value is the current leaving that node through the device, and its lanes
  are that row of the Jacobian. Each row carries only the lanes it can have,
  so the host reads rows with an `inline for` and spreads each into a matrix
  row with `contract.denseRow`.
- **Constant columns.** An unknown outside `deriv_reads` carries no lane;
  its partials are compile-time constants in `jac_const`. This diode has
  none, but the loop is what a general host needs.
- **The host's own stamp.** The 1 kΩ resistor adds its current
  `(V(a) − 1 V)/R` to row `a` and its conductance to the diagonal.
- **Newton.** Solve `J·dx = −f` for the two free unknowns (Cramer's rule is
  enough for two) and stop when the step is below 1 pV.

## Running it

The host compiles against two modules: the generated device, and the
contract. `contract.zig` is installed as `share/vera/contract.zig` by `zig
build install`; in the repository it is `lib/contract.zig`, which the
command below uses. `zig run` binds modules with `--dep` (which applies to the
next `-M`) and `-M` (the first one is the root):

```console
{{#include ../examples/host/host.out}}
```

W0650 is VerA reporting that it cannot prove the exponential finite for
every input, so the junction compiles in strict float mode
([Diagnostics](../using/diagnostics.md)); `--allow=W0650` keeps it out of the
transcript.

From the starting guess of 0.6 V, Newton takes seven iterates. Over the last
three the residual goes from about 1e-7 to 1e-11 to 7e-19 A: the number of
correct digits roughly doubles each time, which is Newton's quadratic
convergence with an exact Jacobian.

## Checking the answer

The same circuit by hand: the junction voltage V<sub>d</sub> = V(ai) and
the current I satisfy

```text
I = is · (exp(Vd / (n · Vt)) − 1)          (the junction)
I = (1 V − Vd) / (R + rs)                  (the two resistors in series)
Vt = k·T/q = 8.617333262145179e-5 · 300.15 = 0.0258649 V
```

with `is` = 10 fA, `n` = 1, R + rs = 1010 Ω. Solving the two by bisection
(independently of VerA, in a few lines of Python) gives
V<sub>d</sub> = 0.629200 V and I = 367.128 µA, so
V(a) = V<sub>d</sub> + I · rs = 0.632872 V: the host's last line.

## What this host leaves out

It is one DC point of one memoryless device with no limiting. The rest of
this part adds, in order of need: charges and the transient loop, device
state, `$limit` and breakpoints ([charges, truncation error and
state](state.md)); noise and AC ([tables](tables.md)); evaluating many
instances per call ([batching](batching.md)); and loading the device from a
shared library instead of compiling it in ([linking](linking.md)).
[ESPice](https://github.com/OmarSiwy/ESPice) is a complete host to read
next: its `src/device/eval.zig` is the host side of this contract, one call
per hook, and `src/analysis/` the analyses.
