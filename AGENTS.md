# Agents

## Building

- Run every `zig build` inside `nix develop -c …`. The shell gives each Zig store path its own global cache (`ZIG_GLOBAL_CACHE_DIR=~/.cache/zig-<store path>`). ESPice pins a different build of the same Zig version, so with a shared `~/.cache/zig` the two evict each other's build runner and every `zig build`, even `--help`, takes about 2 minutes. The first build in a fresh cache pays a one-time compile of about 70 s.
- Edit loop: keep `zig build check --watch -fincremental` running. `check` type-checks every root without emitting or running anything, so an edit is re-checked in under a second. `zig build test-<x> --watch -fincremental` also works, but each rerun costs the tests' run time.
- `zig build test-spice --fork .` builds ESPice against this tree and runs the `.sp` decks on it. ESPice is a lazy dependency fetched only for this step: ESPice, Gompute and the model tarballs, network once, into `zig-pkg/`. Add `--fork ../ESPice` to build a local ESPice checkout instead. `-Despice=PATH` runs an installed espice and then takes no `--fork`, since an unused fork is an error. `-Dgpu`, `-Dcuda-arch` and `-Dhip-arch` forward to ESPice's build. Once `zig-pkg/` holds ESPice, every `zig build` configures it, and one without `--fork .` also fetches the VerA that ESPice pins; delete `zig-pkg/` to drop it.

## Worktrees

- Symlink a new worktree's `.zig-cache` to the main checkout's (`ln -s <main>/.zig-cache <worktree>/.zig-cache`) so they share build results.
- Shared caches share incremental state: run one `--watch -fincremental` per artifact at a time across all worktrees.

## Layout

Laid out like the Zig compiler: `src/` is the compiler, `lib/` is what it
ships, `tests/` the tests, `tools/` the scripts.

- `lib/`: everything a `vera` artifact links or a host compiles against, and
  nothing else. `contract.zig` (the device ABI, installed as
  `share/vera/contract.zig`), `osdi_dyn.zig` (the OSDI 0.4 dyn), `sim/` (the
  runtime of `--emit-exe` executables and `.v` devices) and the modules the
  runtime imports: `base/`, `diag/`, `frontend/`, `kernels/`. `build.zig`
  embeds the whole of `lib/` into `vera` (`simSources`), which writes it out
  beside a build (`src/main.zig`'s `simTree`); `src/zigbuild/exe.zig`'s
  `runtime_modules` names the module roots inside it.
- `src/`: `main.zig` and `cli/` (the driver), `Compilation.zig` (the `vera`
  module: the spine), `elab/`, `ir/`, `analog/`, `prove/` (the analog
  pipeline), `codegen/` (one directory per backend: `device/` the contract
  device for `--emit-zig`/`--emit-so`/`--emit-osdi`, `exe/` the analog
  testbench, `digital/` the `.v` executable, device and `--emit-rtlil`,
  `verilog/` the behavioural `--emit-verilog`), `zigbuild/` (drives `zig`),
  `vpi/` (the VPI library), `dynlib.zig`.
- `tests/`: flat, `fixtures/` its only directory, every other file a root
  the build compiles or runs: `unit.zig` (every module's public-API tests,
  one namespace per module), `suite.zig` (the fixture runner, one namespace
  per mode over the shared harness), `fuzz.zig`, `rng_reference.zig` (+ `.c`),
  `printf_reference.zig`, `codegen_probe.zig`, `host.py` (the host
  observation runners and their `selftest`). A nested namespace may not
  redeclare a file-scope name, so a merged root's file scope declares only
  its namespaces, `main` and the test that references them. `src/` and
  `lib/` keep only the `test` blocks beside the private declaration they
  check, as in Zig's std, and the test support a module exports for the unit
  namespaces (`Lower.Harness`, `codegen.Harness`, `elab/fixture.zig`,
  `prove/fixture.zig`). `fixtures/` holds the HDL, C and SPICE inputs by
  chapter with the host that drives a device beside it, plus `canary/`,
  `beh_verilog/`, `rtlil/`, `conformance/` (ledgers, baselines, registries)
  and `external/`; `tests/README.md` lists the suites.
- `tools/`: one file per script (`conformance.py` owns `run`'s evidence
  accounting and its selftests, `report.py`, `doctest.py`, the three
  `external_*.py` runners, `update-sources.py`) and `zrunner.zig`.
- A module imports `lib/` freely and `src/` never imports a module above it in
  `build.zig`'s `module_specs`; `lib/` imports nothing from `src/`.

