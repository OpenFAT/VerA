# Shared libraries, validation and GPUs

There are two ways to put a VerA device into a simulator.

- **As a module.** Generate `device.zig` (`vera --emit-zig model.va -o
  device.zig`) and compile it into your own Zig program, as the
  [minimal host](minimal-host.md) does. The device is then ordinary source in
  your build: inlined, specialised to your family, and checked against your
  host at compile time.
- **As a shared library.** `vera --emit-so` compiles the device together with
  a small module of yours, the `dyn` module, into a `.so` (`.dll`, `.dylib`)
  your simulator loads at run time. Whatever the `dyn` module exports is the
  library's interface, so a host in any language can call it through the C
  ABI.

## `--emit-so` and the `dyn` module

```sh
vera --emit-so --dyn dyn.zig --work-dir build model.va
```

VerA writes the device and a generated *shim* under `build/`, then compiles
them with your `dyn.zig` and the `contract` module. Apart from forwarding
your `vera_validate_contract` (below), the shim is:

```zig
comptime {
    @import("dyn").exportDevice(@import("device"), "<name>");
}
```

So `dyn.zig` declares

```zig
pub fn exportDevice(comptime D: type, comptime name: []const u8) void
```

and `@export`s whatever functions your simulator calls, instantiated for
`D`. A complete one, exporting the residual and dense Jacobian at a point:

```zig
{{#include ../examples/host/dyn.zig}}
```

and a program that loads the library and calls it:

```zig
{{#include ../examples/host/load.zig}}
```

```console
{{#include ../examples/host/so.out}}
```

`load.zig` passes the operating point the minimal host solved, rounded to a
microvolt. Each row is the current leaving that node into the device: at
the anode +367.2 µA, the series resistor's (0.632872 − 0.629200) V / 10 Ω;
at the cathode −367.1 µA, the junction current, negative because it flows
out of the device into `k`. The internal node's row would be exactly zero at the
unrounded solution; here it is −76 nA, the 0.114 S of `df[ai]/dx[ai]` (the
series 0.1 S plus the junction's I/V<sub>T</sub>) times the rounding.

`--emit-so` prints the library's path: `<work-dir>/lib<name>.<generation>.so`
(the platform's prefix and suffix). The command line always builds
generation 1; a host that embeds VerA as a library (`vera.buildArtifact`)
passes its own generation per rebuild, so each rebuild is a fresh file and a
fresh inode to `dlopen`. The build is ReleaseFast with the LLVM backend by
default (`--optimize`, `--zig-backend`, `--debug-info` change that).

`tools/report.py`'s `DYN` is a real `dyn` module: it exports one `evalQ` over
the sparse reference family with every operand from the caller.
`tests/conformance/vera/host/vdev_dyn.zig` exports a digital device's transient as one C call.

### Large devices

A device past a size threshold is built as one object per part, in parallel,
then linked (`contract.DevicePart`: `.setup`, `.state`, `.eval`). A `dyn`
module may declare

```zig
pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: contract.DevicePart) void
```

beside `exportDevice`; the split build calls it once per part, and it must
export each symbol from exactly one part. Without it, `exportDevice` runs in
the setup object. A large `setup` comes in chunks (`D.setup_chunks`); a `dyn`
that also declares `pub fn SetupValue(comptime D: type) type`, the value
scalar it passes `setup`, gets each chunk compiled in its own object.

### Build time

What a device costs to compile is LLVM's time over the core, the one
function every entry point inlines, once per family it is instantiated
with. Measured on psp103 (12 unknowns, 1.5 MB of Zig) and bsimcmg (2.4 MB)
with Zig's LLVM backend at ReleaseFast on one 2024 desktop core: Zig's own
frontend takes about a quarter of a second, each instantiation of the core
takes 2 s (psp103) to 4 s (bsimcmg) on x86-64, and an AMDGPU kernel over the
same core 6 to 10 s, half of it in LLVM's machine scheduler, which is
superlinear in the size of a straight-line region. ReleaseSmall is slower,
not faster. So:

- Reference `evalQ`, or `eval` and `q`, but not `evalQ` beside `eval`: each
  distinct entry point a `dyn` reaches inlines the core again, and a host
  that references both pays twice. `lib/osdi_dyn.zig` picks one at comptime.
- Instantiate one family. A value-only family (`RefFamily` with every lane
  `no_lane`) beside the dual family costs a second, cheaper core.
- Let the split build run: with `exportDevicePart` the parts compile in
  parallel and the wall time is the `eval` part's alone.
- On a GPU target the kernel is one object and inlines the core once; its
  time is the scheduler's, and a smaller model is the only lever today.

## Validation

The contract can check a device and a host at compile time. The checks are
**opt-in**: they run only where the program's root module declares

```zig
pub const vera_validate_contract = true;
```

(`contract.validating`). For an `--emit-so` build, declare it in the `dyn`
module; the shim forwards it. The minimal host and the `dyn.zig` above both
opt in. The contract's header records their cost at 0.4-1.8% of a device
build's instructions (measured 2026-10-01).

With the checks on:

- `contract.validate(D)` (called inside every generated device) checks every
  declaration's shape and the tables' invariants, and refuses an unknown
  public declaration.
- `contract.validateHost(H, D)`, which your host calls once per device,
  checks the obligations the device puts on the host. `H` declares each one
  it meets as a `true` constant:

| Declaration on `H` | Needed when the device has | Promise |
|---|---|---|
| `calls_setup` | `setup` or `setupInstance` | you call `setup` per `Model` row after `derive` and after every card, `temperature__` or `setup_simparams` write, then `setupInstance` per instance, before `eval` |
| `mutable_eval` | `mutable_eval` | each evaluation gets exclusive `*Instance` |
| `iteration_hooks` | `advanceIteration` or `checkConvergence` | you call the first after every iterate and the second before accepting one |
| `noise_table_points` | `noiseTablePoints` | you read the card's noise-table knots, through `contract.noiseTable` (the row's `noise_table_points__`) or the hook |
| `shape_check` | `checkShape` | you call it after `derive` and refuse a card it names |
| `calls_ac_dyn` | `ac_dyn_slots` | `true`: every small-signal matrix adds `acDyn`; `false`: you run no small-signal analysis |
| `systf` | a non-empty `systf_calls` | `fn (*const Model) ?*const SystfHost`, binding the VPI application |

One check runs whether or not you opt in: `validateHost` refuses a device
whose `vera_version` is not `contract.vera_version`, naming both releases
and saying to regenerate it with this contract's VerA. `--contract PATH` builds against
another contract file; by default VerA uses the copy built into it, so the
contract always matches the compiler.

## GPUs

The generated device imports only `std` and `contract`, calls no OS, and
reaches transcendental functions only through `contract.gm`: VerA's own
`exp`, `log` and `pow` (one implementation on every target, faithful to under
1 ulp) and GPU forms of `tanh`, `sinh`, `cosh`, `sin`, `cos`, `expm1` and
`atan`, since NVPTX and AMDGCN have no libm. On the host those are the Zig
builtins or `std.math`, so a GPU result may differ slightly from the CPU's
(`gm`'s comments say what each GPU form is and how far it may differ;
`exp`, `log` and `pow` are the same bits everywhere). `RefFamily` computes through
`gm` too. So the same `device.zig` compiles for `nvptx64-cuda` and
`amdgcn-amdhsa` with the LLVM backend.

`tests/conformance/vera/host/status_gpu.zig` is the pattern: a `callconv(.kernel)` export that
runs `evalQ` and `updateState` over a `RefFamily`
(`tests/conformance/vera/host/say_gpu.zig` does the same for `say`). `zig build test` compiles both
for `nvptx64-cuda` (`sm_70`, to LLVM IR, because the NVPTX backend refuses
the alias `@export` of a kernel makes; a host rewrites the IR) and for
`amdgcn-amdhsa` (`gfx906`, to an object). No GPU runs them in CI.

What is not covered: only the math functions device code is known to reach
are ported (`gm`'s header says so); a model that reaches another builtin on a
GPU target fails its kernel compile, and `gm` is where to add it. The
reference family's `log1p` calls `std.math.log1p` directly rather than a
`gm` function; whether that compiles for both GPU targets is not covered by
those two kernels.
