# Parameters

A **parameter** is a constant of the model that the simulator may set per
instance: a resistance, a saturation current, a flag. Its value is fixed for
the duration of an analysis, which is what lets VerA compute everything that
depends only on parameters once, outside the solver's loop. This chapter
covers declaring parameters, constraining them, deriving one from another,
and the ways their values are set.

## Declaring parameters

```verilog
{{#include ../examples/parameters/params.va}}
```

```console
{{#include ../examples/parameters/params.out}}
```

Each line shows one feature:

- `parameter real r = 1k from (0:inf);` has a **type** and a **range**. A
  parameter always has a default (LRM §3.4.1). Without a type, it takes the
  type of its final value, as in IEEE 1364 Verilog.
- `parameter integer stages = 2 from [1:8];` is an integer. Square brackets
  include an end point, parentheses exclude it (LRM §3.4.2).
- `parameter real g = 1 / r;` has a default computed from another parameter.
  Defaults are evaluated after overrides, so `g` follows `r` (LRM §6.3.4): the
  card set `r` to 2 kΩ and `g` came out 0.5 mS.
- `parameter string topology = "series" from '{"series", "parallel"};` is a
  **string parameter** whose allowed values are listed (LRM §3.4.6).
- `localparam real rseries = r * stages;` is a **local parameter**: computed
  from parameters like one, but never set from outside (LRM §3.4.5).
- `$param_given(r)` is 1 when the instance's value of `r` was set by an
  override, 0 when it is the default (LRM §6.3.5).

The `//! param r = 2000` line is the testbench's model card. The values in
the transcript follow from it: `rseries` is 4 kΩ, and 1 V draws 0.25 mA.

## Ranges and `exclude`

A range accepts more than intervals: `exclude` removes values or intervals
from what `from` allows, and a parameter with no `from` but an `exclude`
accepts everything else (LRM §3.4.2). This resistance may be negative but not
zero:

```verilog
{{#include ../examples/parameters/negres.va}}
```

```console
{{#include ../examples/parameters/negres.out}}
```

The LRM makes an out-of-range value an error "only if the value of the
parameter is out of range during simulation": a range constrains the values
an instance receives, not the default the module states. VerA checks
overrides when it compiles them, so `--param r=0` is refused before any
code is generated (E0361).

## Setting parameters

A simulator sets parameters per instance, from a model card or an instance
line. In Verilog-AMS itself, a parent module overrides the parameters of the
modules it instantiates, by name or by position (LRM §6.3):

```verilog
{{#include ../examples/parameters/instance.va}}
```

```console
{{#include ../examples/parameters/instance.out}}
```

VerA compiles the module no other module instantiates, here `pair`, and
flattens its children into it: the two branches between `p` and `n` add, and
1 V draws 3 mA.

For the top module, VerA takes overrides from the command line and from
the testbench:

- `--param NAME=VALUE` sets a top-level parameter for one run: a number, or
  a string parameter's text (`--param topology=parallel`). A local parameter
  cannot be set, and VerA says so:

```console
{{#include ../examples/parameters/params_cli.out}}
```

- `//! param NAME = VALUE` in the source is the testbench's model card.
- `//! psweep NAME = v1, v2, ...` runs one operating point per value, each
  with its own card:

```verilog
{{#include ../examples/parameters/psweep.va}}
```

```console
{{#include ../examples/parameters/psweep.out}}
```

## Aliases

`aliasparam res = r;` gives `r` a second name for overrides (LRM §3.4.7). Compact
models use aliases to accept the spellings different simulators use for the
same parameter. The equations must use the original name, and an override
may name the parameter or one alias, never both.

```verilog
{{#include ../examples/parameters/alias.va}}
```

```console
{{#include ../examples/parameters/alias.out}}
```

## Exercises

1. Run `negres.va` with `--param r=-500`. What current flows at 1 V?
2. In `params.va`, what does `--param stages=4` change, and what stays?
3. Why can `g` in `params.va` not be a `localparam` if a simulator should be
   able to set the conductance directly?

<details>
<summary>Solutions</summary>

1. 1 V / −500 Ω = −2 mA: the current flows backwards. The second command of
   the `negres` transcript above shows the run.
2. The series resistance doubles to 8 kΩ, so 1 V draws 0.125 mA; `g`
   depends only on `r` and stays at 0.5 mS. The first command of the
   `params_cli` transcript above shows it.
3. A local parameter cannot be overridden (LRM §3.4.5). `g` is a parameter
   whose *default* is computed from `r`: an instance that sets `g` gets its
   own value, and one that does not gets `1/r`.

</details>
