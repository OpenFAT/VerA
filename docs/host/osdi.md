# OSDI interoperability

OSDI is the C interface of the compiled models
[OpenVAF-Reloaded](https://github.com/OpenVAF/OpenVAF-Reloaded) builds: a
shared object exporting a descriptor of a model's nodes, parameters and
Jacobian entries, with function pointers the simulator calls. ngspice loads
such a library with its `pre_osdi` command. If your simulator already loads
`.osdi` files, that is the shortest path to running a VerA-compiled model in
it, at the costs [the first page](why.md) lists.

## `vera --emit-osdi`

```sh
vera --emit-osdi model.va              # writes <module>.osdi and prints its path
vera --emit-osdi model.va -o lib.osdi  # or names it
vera --emit-osdi design.v              # a Verilog module's contract device, the same way
```

It is `--emit-so` under a `dyn` module VerA ships, `lib/osdi_dyn.zig`,
which `vera` carries inside it and writes beside its own copy of the
contract (`contract.zig` and `contract/`) in the work directory (`.zig-cache/vera-tb` unless
`--work-dir` says otherwise). So it takes neither `--dyn` nor `--emit-zig`,
`--emit-exe` or `--run`; each of those is refused with exit status 2. The
library holds one OSDI 0.4 descriptor, named after the module, which is the
name a `.model` card uses.

The source may be a Verilog-A model (`.va`) or an IEEE 1364 design (`.v`).
A `.v` builds its top module as the contract device `--emit-zig design.v`
prints (4-state; what it refuses is E1103): one terminal per port bit, an
input sensed through an A2D bridge and an output driven through a D2A bridge
whose card (`vdd`, `vss`, `vth`, `vhys`, `trise`, `tfall`, `rout`, `gz`,
`ttol`) is the library's parameters. So one ngspice deck can `pre_osdi` a
`.v` library and a `.va` one and wire them together.

`lib/osdi_dyn.zig`'s header is the specification of the mapping. Its
layout follows OpenVAF-Reloaded's `openvaf/osdi/header/osdi_0_4.h` and
ngspice-45's `src/osdi/`, which reads the OSDI 0.3 prefix of the descriptor.
In short:

| OSDI | From the contract |
|---|---|
| nodes | every unknown of `U`, ports first (the first `num_ports` are the terminals); a `current`/`flow` unknown is an OSDI flow node |
| Jacobian entries | every `(row, col)` in `jac_pattern \| q_pattern`, plus the `jac_const` and `ac_dyn_slots` entries |
| parameters | every scalar real, integer or string `Model` parameter (no `__` in its name), listed twice, as an instance parameter and as a model parameter, since the contract does not say which a parameter is; an instance value overrides the card's. `$mfactor` is an instance parameter when `Instance` has `mfactor` |
| eval | one `evalQ` (or `eval`) over the sparse reference family at the limited point: `seed` under ngspice's `INIT_LIM`, `limit` against the previous limited point under `ENABLE_LIM`. The results are kept in the instance, and the `load_*` calls stamp them |
| noise | one OSDI source per `noise_gens` row, its density `coeff² · (white + flicker/f^ef + table)` from `noisePsd` at the last evaluated point |
| `$mfactor` | LRM §6.3.6's scaling, which the device leaves to its host: the rows (and the noise power) times `Instance.mfactor` |
| temperature | each instance runs on its own `Model` row: the card, the instance's own parameters and `temperature__`, then `derive`, `checkShape`, `checkRange`, `setup`, `setupInstance` |
| collapse | a flow unknown whose branch the card switches off collapses into ground; every other `collapse` alias is left unapplied, which is exact |
| `$bound_step` | `bound_step_offset` |
| breakpoints | `pendingBreakpoint` bounds the step after each point through the same `bound_step_offset`: the distance to the next breakpoint, or, when one is due at the point itself (its consequences known only once the point is accepted), the length of the step that reached it |
| a static "iterate again" | `updateState`'s request in a DC or operating-point solve is `EVAL_RET_FLAG_LIM`: ngspice counts the iterate unconverged and solves again |

And what does not map, "each because OSDI 0.4 has no slot for it", per the
same header:

- operating-point variables (opvars);
- correlated noise (`NoiseGen.source` shared by rows, `PsdTerm.corr_with`):
  each row becomes an independent source;
- a step rejection the device asks for in a transient (`request_reject_at`),
  refused before the build (E1099);
- the late-event query (`stateCtl(.query)`): a native host rejects a step
  that ended long after a crossing the device woke on; under OSDI the
  device's response starts at the first point ngspice accepts after the
  crossing;
- acceptance itself: OSDI has no accept callback, so `updateState` and
  `stateCtl(.commit)` run at every iterate of a static solve and, in a
  transient, at the last point evaluated before the simulator moves time
  forward. A rejected step retries at an earlier time, so it is never
  committed.

So a device whose behaviour depends on state across accepted points (events,
`idt`, held variables, every `.v` design) runs under OSDI with acceptance
approximated as above. The native contract, with `updateState` and
`stateCtl` called at real accepted points, is exact.

Printed output follows the same commits. A Verilog-A device's `$strobe`,
`$display` and `$debug` records are not printed by the library. A `.v`
device prints what a committed step ran to stderr, at the commits above:
in a static solve that is any iterate whose events print, and each time
ngspice sets an instance up again (a new analysis) the design restarts from
time 0, so an `initial` block prints again.

## Checking against ngspice

`tools/external_analog.py` runs hand-derived ngspice decks over
`--emit-osdi` libraries (`tests/osdi/`; `mixed.sp` wires a `.v` design's
library to a `.va` model's), in `nix develop .#external`
([External accuracy suites](../using/external-suites.md)). The CI job
`external-analog` runs them on every push to `main` and every pull request.
This book quotes no numbers from them; the job summary and its artifact are
the record.
