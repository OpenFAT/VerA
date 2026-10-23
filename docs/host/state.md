# Charges, truncation error and state

The [minimal host](minimal-host.md) solves one static operating point of a
memoryless device. A transient analysis needs three more things from a
device: its charges, the state it carries from one accepted point to the
next, and a say in which steps are accepted. This page covers each, then
the hooks that help Newton converge.

## The call sequence

`contract.validate`'s header lists every entry point in the order a host
calls it:

```text
derive(S, *model)            after writing a card, before building instances
checkShape(&model)           after derive; non-null: refuse the card
checkCard(&model)            after derive (optional; the host decides)
checkRange(&model)           after derive; non-null: refuse the card
setup(S, &model)             after derive, and after every card,
                             temperature__ or setup_simparams write
setupInstance(&model, &inst) per instance after every setup
collapse(S, &model, &inst)   once per instance at build
initState(&model, &inst)     once per instance, before the first solve, and
                             at the start of each later analysis
seed(S, ...)                 once before Newton iteration 1
eval / q / evalQ             every iterate
limit(S, ..., cur, old, sim) every iterate, on the instance's private limited image
advanceIteration / checkConvergence
                             after each iterate / before accepting one
updateState(S, ..., x, &state, sim)
                             at each accepted point; acceptQ fuses it with q
stateCtl(op)                 query, commit or revert the accepted state
display(S, &x, ...)          per accepted point, --display=emit artifacts only;
                             a $finish/$stop/$fatal in it exits the process
noisePsd / acStim            at any state vector
acDyn(F, ..., omega, &out)   per small-signal frequency
nextBreakpoint / pendingBreakpoint / delays
                             transient breakpoint scheduling
```

A device whose model has LRM §9.4 display tasks also has `say_sites` and
`say` (under `--display=record`, the default): call `say` once per accepted point, after the solve and before
`updateState`, with a `contract.Say` buffer you lend it, and print what it
recorded with `contract.formatSay`. That is how the model's `$strobe`,
`$display` and the other display tasks reach your output; [tables](tables.md)
has the details.

[ESPice](https://github.com/OmarSiwy/ESPice) is a complete host to read
beside this list; its `src/device/eval.zig` is the device-facing part, one
call into the contract per hook, and `src/analysis/` the analyses (Newton,
LTE-controlled transient, noise).

## Charges

A device with a `ddt` has `q` and `evalQ`. `q` returns one charge per
**charge site**, not per row: each `ddt` term of a contribution, after
unrolling. `q_stamps` maps sites onto rows, so row `r` of the reactive
residual is `Σ sign · q[site]` over the entries with `row == r`
(`contract.qRows` computes it). Here is the diode with a junction capacitance
added:

```verilog
{{#include ../examples/host/cdiode.va}}
```

```console
{{#include ../examples/host/charges.out}}
```

One site, stamped `+1` on the internal node `ai` and `−1` on the cathode `k`.
Integrate and truncation-check each site on its own, then stamp its current
into its rows. A device without `n_q` and `q_stamps` has one site per row,
site `k` on row `k`.

`q_lte[k]` says whether site `k` joins your local-truncation-error check.
All sites do, unless the model writes VerA's `(* vera_lte = 0 *)` attribute
on the contribution or the `ddt` ([vendor attributes](../using/attributes.md)),
which leaves those sites out of the check while still integrating them. `QStamp`,
`nQ`, `qStamps`, `qLte`, `qRowMask` and `q_site_pattern` are the
declarations to read.

A LRM §4.5.2 operator unknown (each `idt` site, a `ddt` off a contribution's
spine) is an ordinary internal unknown of `U` with its own row and site.

## State across accepted points

Anything a device remembers from one accepted point to the next (an event
latch, a held variable, an `idt` accumulator, `$prev`, a `transition`'s
ramp) lives in `State` and in `Instance`:

```zig
pub const StateClass = enum { none, path_latch, history };
```

| Class | Meaning |
|---|---|
| `.none` | no `State`, no `updateState` |
| `.path_latch` | only LRM §5.6.1.2 path latches: `updateState` stages them, `stateCtl(.commit)` latches them |
| `.history` | anything else `updateState` advances |

`contract.stateClass(D)` reads it. The protocol:

1. `state = initState(&model, &inst)` once, before the first solve, and
   again at the start of each later analysis: it resets everything
   `updateState` advances (LRM §4.6.2).
2. At every accepted point, the operating point included,
   `updateState(S, &model, &inst, x, &state, sim)`, then
   `stateCtl(&model, &inst, &state, .commit)`.
3. To reject a step after `updateState` ran on it,
   `stateCtl(..., .revert)`. Exact when at most one `updateState` ran since
   the last commit or revert.
4. `stateCtl(..., .query)` asks whether the working state differs from the
   accepted one in a way that should reject the step (a `cross` or `above`
   flipped).

`acceptQ` fuses `updateState` and `q` into one evaluation for a host that
needs both at an accepted point.

`updateState` returns an `UpdateResult`:

```zig
pub const UpdateResult = union(enum) {
    ok,
    request_reject_at: f64,
};
```

`request_reject_at = t` asks you to reject the step and retry with its end at
absolute time `t`. A Verilog-A device returns it only from VerA's
`$vera_reject_step(t)` with `t` before the step's end, and such a device emits
no `acceptQ`. A digital `.v` device returns it in a static solve to mean
"iterate again at this point": its state moved and the solve must see it.
An event that fired inside a step (a `cross` that flipped) is what
`stateCtl(.query)` reports; the SPICE runner then cuts the step.

After an accepted step, read `inst.bound_step` (LRM §9.17.2 `$bound_step`,
`inf` when unconstrained) and `inst.discontinuity_order` (LRM §9.17.1, `-1`
for none) when the instance has those fields.

## Breakpoints

| Hook | Meaning |
|---|---|
| `nextBreakpoint(&model, t) ?f64` | the next time after `t` the card alone schedules (a piecewise source) |
| `pendingBreakpoint(&inst, t) ?f64` | the live per-instance schedule: LRM §5.10.3.3 timers, digital events, the corners of D2A ramps |
| `delays(&model) [k]f64` | the LRM §4.5.7 `absdelay` delays, from which a host echoes breakpoints |

Land a step on each breakpoint. The SPICE runner takes the earlier of the
first two (`Circuit.nextBreakpoint`).

## Limiting, seeding and collapse

LRM §9.17.3 `$limit` is the host's to apply ([`$limit`
arguments](../using/limit.md)). A device with honoured `$limit` sites
publishes:

| Hook | Meaning |
|---|---|
| `limit(S, &model, &inst, cur, old, sim) LimitResult(n_u)` | every iterate: `cur` clamped against `old`, the previous iterate's limited point, and `converged`, false when you must iterate again (a large clamp, or the model at `old` executed `$discontinuity(-1)`) |
| `limit_reads`, `limit_writes` | the unknowns the clamps load and may store (supersets). A clamp writes only internal nodes; a host that masks ports loses only that clamp, which LRM §9.17.3 permits |
| `seed(S, &model, &inst, sim) [n_u]?f64` | before Newton iteration 1: the cold-start value of each limited unknown (SPICE `MODEINITJCT`), null elsewhere |

Keep the limited image per instance, never on the shared solution vector.

`collapse(S, &model, &inst) [n_u]?u8` maps each internal unknown to the index
it merges into when its separating resistance is zero (a series resistance
of 0 Ω), or null. `collapse_full` is the same map with every retention flag
set, at compile time, for sizing a reduced basis. A family that declares
`collapse_applied = true` promises you applied the aliases to your gather and
scatter maps; the device then omits the collapsed branches' cancelling
stamps. Applying none is exact too: the uncollapsed system keeps a 0 V
branch's flow as an unknown.

`advanceIteration(S, &model, &inst, x_prev, sim)` and
`checkConvergence(S, &model, &inst, x, sim) bool` are the per-iterate hooks
for limiter history and a device's own convergence veto. A device with them
requires the host to declare `iteration_hooks = true` (`validateHost`).

`attempt(model, lambda) Model` returns the card modified for continuation
step `lambda`, for a host doing source or parameter stepping.

## `$fatal` and `$error` in a device

A device cannot print or stop its host. The first LRM §9.7.3 `$fatal` or
`$error` an evaluation reaches latches `inst.vera_status__` (the severity in
the top byte, the site's index plus one below) with up to four numeric
arguments in `inst.vera_status_args__`. While latched (until `initState` or
`setupInstance`), `eval`, `q` and `evalQ` return all-zero rows and
`updateState` changes nothing. Poll the field after a solve and render it
with `contract.formatStatus(D, &inst, writer)`, which prints
`<file>:<line>: fatal|error: <message>` from `status_sites`.
