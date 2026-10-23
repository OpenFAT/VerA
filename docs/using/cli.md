# The command line

`vera` takes one source file and a mode. A `.va` (or any non-`.v`) file is
Verilog-AMS and goes through the analog compiler; a `.v` file is digital
IEEE 1364 Verilog and goes through the event-driven engine, and may be
followed by more `.v` files holding the library cells it instantiates.

```text
vera [options] FILE.va
vera --run|--emit-exe [options] FILE.v [MORE.v ...]
vera --emit-zig|--check|--emit-so|--emit-osdi|--emit-rtlil [options] FILE.v [MORE.v ...]
vera --explain CODE
vera --version | -v | -V
```

## Exit status

| Status | Meaning |
|---|---|
| 0 | success; warnings do not fail |
| 1 | a diagnosed error in the source, or a failed build |
| 2 | a usage error: an unknown or malformed flag, or two flags that conflict |

Conflicting flags are refused by name whatever order they come in; a later
flag never silently wins over an earlier one of another kind.

## Modes

| Flag | What it does | Needs `zig` |
|---|---|---|
| `--lint` | parse, elaborate, lower and prove; generate nothing | no |
| `--emit-zig` | write the device's Zig source to stdout, or to `-o PATH` | no |
| `-o PATH` | implies `--emit-zig`, writing to `PATH` | no |
| `--emit-verilog` | a behavioural Verilog model of a `.va`, for digital simulators | no |
| `--emit-rtlil` | a `.v` design as Yosys RTLIL text, for synthesis: `yosys -p 'read_rtlil design.il; synth'`. One module per source module, a `process` per `always` block, parameters at their defaults; a construct outside the synthesizable subset (a loop, a memory, a real, a hierarchical name, a parameter override of a module outside the source) is refused by name with its line | no |
| `--check` | generate the device and type-check it with Zig against the contract, running the contract's conformance checks | yes |
| `--emit-exe` | build a self-checking testbench from the source's `//!` directives (or a `.v` design's executable) and print its path | yes |
| `--run` | `--emit-exe`, then run it; the testbench's exit status is `vera`'s | yes |
| `--emit-so` | build the device as a shared library for your simulator, through your `--dyn` module | yes |
| `--emit-osdi` | build the device (of a `.va`, or a `.v` design's top module) as an OSDI 0.4 library that ngspice loads with `pre_osdi` (`--emit-so` under the `lib/osdi_dyn.zig` built into `vera`); `-o PATH` names it, default `<module>.osdi`, and its path is printed | yes |
| `--explain CODE` | print the long explanation of a diagnostic code | no |
| `--version` | print `vera <release>`: the VerA release, which every device it generates carries as `vera_version` | no |
| `--lsp` | a language server for an editor, on stdin/stdout (below) | no |

With no mode flag, `vera FILE.va` is `vera --lint FILE.va`.

`--emit-exe` prints the artifact's path on **stdout** and every diagnostic on
**stderr**, so `P=$(vera --emit-exe model.va)` captures only the path.
Testbenches are covered in [Testbenches and `//!` directives](testbenches.md),
`--emit-so` in [Shared libraries, validation and GPUs](../host/linking.md),
`--emit-osdi` in [OSDI interoperability](../host/osdi.md), and
`--emit-verilog` below.

## Editors: `--lsp`

`vera --lsp` speaks the Language Server Protocol on stdin and stdout. Every
open Verilog-A document is linted as `--lint` would lint it, on open and on
every change, and its diagnostics appear in the editor: one inside an
`` `include `` file lands on that file, and a diagnostic with a fix-it (a
missing `;`, a misspelt name) offers it as a quick fix. An included file is
read from disk, so save a header to see its edits.

The options on the command line apply, then the ones in a `.vera-flags` file
at the workspace root: `vera` flags separated by spaces or newlines, with a
relative `-I` taken from the root. For example:

```text
-I include
--deny=W0650
```

Neovim 0.11 and later needs `editors/nvim` on its runtime path and
`vim.lsp.enable('vera')`; VS Code takes the extension in `editors/vscode`.
`.v` documents get no diagnostics yet.

## Source options

| Flag | Meaning |
|---|---|
| `-I DIR` | add a directory to the `` `include `` search path (repeatable, in order) |
| `--param NAME=VALUE` | compile with top-module parameter `NAME` set to `VALUE` (LRM §3.4). A parameter that sizes an array or selects a generate arm is fixed at that value; any other stays a value the model card can change |
| `--spice PATH` | read a SPICE netlist; its `.MODEL` and `.SUBCKT` cards become modules the source can instantiate (LRM Annex E.2) |
| `--std=SPEC` | the source language, as a `` `begin_keywords `` specifier: `1364-1995`, `1364-2001`, `1364-2005` or `VAMS-2023` (the default). A 1364 language frees every AMS keyword as an identifier. Verilog-AMS is compiled as VAMS-2023 only; `` `begin_keywords "VAMS-2.3" `` in the source still selects that keyword set (LRM §10.6) |
| `--sim=verilogAMS\|verilogA\|verilog` | the language family: all of Verilog-AMS (the default); annex C's Verilog-A subset, in which a digital or mixed-signal construct is E0250 (`vera --explain E0250`) and a `.v` design is refused; or IEEE 1364-2005 Verilog alone, which reads as `--std=1364-2005` unless `--std` names another 1364 set, and refuses a `.va` model |
| `--no-std-defs` | do not prepend the LRM Annex D prelude (`disciplines.vams`, `constants.vams`) |
| `--discipline-resolution=basic\|detail` | LRM §7.4.4's mode for undeclared interconnect (default `basic`; `detail` is Annex F.2.2) |
| `--libmap FILE`, `-L LIB` | a `.v` design's IEEE 1364-2005 §13 libraries: a library map file (repeatable), and the libraries an instance's cell is searched in |
| `--expect-module=NAME` | fail unless the compiled module is called `NAME` |

`` `include "disciplines.vams" `` and `` `include "constants.vams" `` always
resolve to VerA's built-in copies of LRM Annex D, so a model needs no files
beside it.

The macro `__VERA__` is predefined by VerA, the tool-specific macro LRM
§10.5 asks every simulator to provide: text under `` `ifdef __VERA__ `` is
compiled by VerA and skipped by any other tool, and `` `ifndef __VERA__ ``
the reverse. The LRM's own `__VAMS_ENABLE__` and `__VAMS_COMPACT_MODELING__`
are predefined too.

## Diagnostics

| Flag | Meaning |
|---|---|
| `--diagnostics=text\|json` | how to report; `json` is one object per diagnostic for tools |
| `--color=auto\|always\|never` | colour in text diagnostics. `--explain` colours unless `--color=never` comes **before** it |
| `--allow=CODE`, `--warn=CODE`, `--deny=CODE`, `--forbid=CODE` | per-code lint level. An error code cannot be allowed |
| `--unknown-bound=X` | the solver compliance limit, in volts or amps, behind the W0650 finiteness proof (`vera --explain W0650`) |

[Diagnostics](diagnostics.md) explains the format and the levels.

## Build options

These matter to `--check`, `--emit-exe`, `--run` and `--emit-so`.

| Flag | Meaning |
|---|---|
| `--zig PATH` | the Zig compiler to run (default: `zig` on `PATH`) |
| `--optimize=MODE` | `Debug`, `ReleaseSafe`, `ReleaseFast` or `ReleaseSmall`. Default: Debug for a testbench, ReleaseFast for `--emit-so` |
| `--zig-backend=auto\|llvm\|native` | `auto` uses Zig's own x86_64 backend for Debug builds on x86_64 (fast to compile), LLVM otherwise. `native` does not optimise |
| `--debug-info` | keep DWARF in a ReleaseFast or ReleaseSmall artifact (stripped by default) |
| `--work-dir DIR` | where sources and artifacts are written (`--emit-so` requires it; testbenches default to `.zig-cache/vera-tb`) |
| `--contract PATH` | the `contract` module to build against (default: the copy built into this `vera`) |
| `--dyn PATH` | your host's `dyn` module, which exports the device (`--emit-so`) |
| `--validate-contract` | run the contract's conformance checks inside an `--emit-exe`/`--run` testbench (`--check` always runs them) |

## Device options

| Flag | Meaning |
|---|---|
| `--jac-f32` | mark the device as tolerating a single-precision Jacobian. It emits `pub const jac_f32 = true`, not different arithmetic: the host decides |
| `--jac-f32-host` | and ask the host to use it on its CPU path too |
| `--display=record\|drop\|emit` | LRM chapter 9 display tasks (`$strobe`, `$display`, ...). `record` (the default): the device records them, and its host prints the records once per accepted point. `drop`: compiled to nothing. `emit`: the device prints them itself, which is what `--emit-exe` and `--run` default to; with `--display=record` a testbench prints the device's records instead |

## Digital options (`.v` designs)

| Flag | Meaning |
|---|---|
| `--schedule=static\|fifo` | order of same-time events: combinational logic levelized (`static`, the default; IEEE 1364-2005 §11.4.1) or the interpreter's order |
| `--state=auto\|2\|4` | `auto` (default) simulates 4-state until no x or z is live, then 2-state; `4` always 4-state; `2` makes every x or z a 0, which is **not** IEEE 1364 4-state logic (E1101) |
| `--two-state` | `--state=2` |
| `--event-budget=N` | events allowed at one time step before a zero-delay loop is refused (default 10000000) |

## `--emit-verilog`

`vera model.va --emit-verilog -o model_beh.v` writes a behavioural Verilog
stand-in of an analog model, for digital simulators (Icarus Verilog,
Verilator). It keeps the module's name and port order. Digital pins become
logic; each net the model drives switches at VDD/2 after its own RC time
constant (τ·ln 2) plus any `transition` or `absdelay` delay; analog pins stay
undriven `inout wire`s.

| Flag | Meaning |
|---|---|
| `--digital-pins LIST\|FILE` | the ports that are logic: a comma- or space-separated list, or a file of names. `(* vera_pin = "digital" *)` on a port declaration says the same in the source |
| `--power-pins` | put the supply pins under `` `ifdef USE_POWER_PINS `` |
| `--vdd=X` | the logic-high potential in volts (default 1.8) |

`(* vera_pin = "digital"|"analog"|"power"|"ground" *)` and
`(* vera_delay = 2n *)` may be written on a port's direction declaration or a
net's declaration. Event-driven models (`@(cross ...)`, held variables) are
refused, since a combinational stand-in cannot reproduce them.

## The full list

This is `vera --help`, run against the current tree:

```console
{{#include ../examples/using/help.out}}
```
