# Batching operating points

A scalar family evaluates one operating point per call. Because `V`, the
type of one unknown's value, is the family's choice, a family can make it a
vector instead: `@Vector(W, f64)`, W operating points per call, one per SIMD
lane, sharing every instruction. On a CPU this is the device's hot loop
running W instances at once; the derivative lanes of
[scalar families](families.md) and these point lanes compose.

This page is for hosts that want that. Everything on it is optional: a host
that only ever uses `V = f64` can skip it.

## Which devices allow it

Three declarations say what a vector family may do with a device:

| Declaration | Meaning |
|---|---|
| `batch_ok` | a family whose `V` holds several operating points evaluates each **exactly**. Without it, a vector `V` is unsound |
| `batch_lead` | it does so only through the **lead protocol** below: the device makes per-point decisions (compares reals, rounds them, strips lanes) |
| `batch_inst` | each point needs its own `Instance`, supplied through the family's `instLane` |

Nothing that steers on a value of the solution, draws a per-call random
number, or collapses an x-dependent chain to its value may sit in a
`batch_ok` device; VerA decides this per device when it generates it.
Per-instance state no point can carry separately (operator history, a held
array, `$limit`'s previous value) drops `batch_ok`.

## The batch key

Every point of a batched call shares the `Model` row (card, temperature,
setup cache) and the `SimState`, and nothing else. Each point has its own
`Instance`. When the device declares `batch_inst` (it reads held variables,
`$prev` latches or `$mfactor` in `eval`), the family that runs the device
supplies

```zig
instLane(comptime T: type, comptime w: usize) *const T
```

returning point `w`'s instance, and the batched call's `inst` argument is not
read for those fields. `updateState`, `stateCtl`, `setupInstance` and
`initState` have no batched form: call them per instance, with its own bias.

## The lead protocol

A device with `batch_lead` makes decisions on per-point values: an `if` on a
voltage, a region of operation. In a batch the points may disagree. The
protocol makes every result exactly, bit for bit, what a scalar family
computes for that point alone, divergent batches included:

1. One point, the **leader**, decides each comparison for the whole batch
   (`decide`, `decideI`, `strip` on the family's `Inner`). A point whose own
   outcome differs is marked diverged.
2. When the run ends, the points that never diverged are finished: their
   results are kept (`leadMerge`).
3. While `leadNext()` names a new leader (the first unfinished point), the
   entry point runs again, and so on until every point has run on its own
   path.

`contract.LeadState(W, sig)` is the bookkeeping, `contract.leadMergeInto`
the merge, and the header comment above `contract.leads` lists every
declaration a batch family supplies. A vector family without the protocol
is refused at compile time for such a device (`contract.leads`), so the
mistake cannot be silent.

A divergent batch costs one more run per distinct path, so a host should
group points that take the same path. `contract.region(D, x, &model, inst,
sim)` hashes every decision `eval` makes at `x` into a 16-bit signature; a
device without `batch_lead` never diverges and its signature is the constant
0. Calling `region` costs part of an evaluation, so the cheaper source is
the batched call itself: `LeadState(W, true)` hashes each point's outcomes as
it runs, and `regions()` afterwards equals `region` at every point. Bucket
the next iterate's points on those.

## What it buys

Measured, not estimated, in two notes in the repository:
[`specification/measurements/batched-instances-2026-10-01.md`](https://github.com/OpenFAT/VerA/blob/main/specification/measurements/batched-instances-2026-10-01.md)
and
[`specification/measurements/batched-lead-2026-10-02.md`](https://github.com/OpenFAT/VerA/blob/main/specification/measurements/batched-lead-2026-10-02.md)
(AVX2, ReleaseFast, with their harnesses beside them). In summary, from the
second note's §1b, §2 and §5:

- Batched results matched the scalar family bit for bit on every model
  measured (diode, mos1, bsim4va, psp103), coherent and divergent batches
  included.
- Coherent batches (every point on one path) cost fewer instructions per
  instance than scalar evaluation; how much depends on the model, and mos1
  gains least in cycles once each point reads its own instance.
- **A divergent batch is slower than scalar** for the MOSFET models: each
  extra run costs about a whole batch. Batching in netlist order measured 1.8
  to 3.5 runs per batch on ARPice's generated decks, which makes every
  compact model slower than scalar.
- Bucketing on the previous call's signatures brought that down to 1.06-1.30
  runs per W = 4 batch on those decks.
- W = 4 is the width to use on AVX2; W = 8 spills registers and diverges
  more.

Read the notes for the tables, the machine and the method before relying on
a number.

## The testbench's batch family

VerA's own testbench carries a W-point batch family with the protocol
(`src/codegen/exe/tb/runner_text.zig`, `@Vector(NL, f64)`), and the fixture suite
checks every `batch_ok` device against the scalar result point by point. It
is a working reference for writing your own.
