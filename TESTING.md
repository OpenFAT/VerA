# Testing

How VerA is tested, what each layer's oracle is, and what a release has to
show. `tests/README.md` has the commands, the layout and the evidence
accounting; this file is the map.

**Input**: Verilog-AMS (Accellera VAMS-2023) and IEEE 1364-2005 source.
**Output**: Zig device code (and `.so`, OSDI, testbench executables,
behavioural Verilog, RTLIL), and the diagnostics on refused input.
**Correct**: the output behaves as the standard says, the numbers agree
with an independent reference within its own accuracy, and every refusal
names the clause behind it.

## Domains and their oracles

| Domain | Bug class | Oracle | Layer, file |
|---|---|---|---|
| Front end (`lib/frontend`, `src/elab`) | crash or hang on any input | no signal, a diagnostic from the declared set | `tests/fuzz.zig` (`zig build fuzz --fuzz`) |
| | wrong accept or refusal | the language reference, clause by clause | `//! lrm` fixtures (`suite -- ams`, `suite -- devices`), the VAMS Conformance Suite (`zig build conformance`) |
| Driver (`src/main.zig`, `src/cli`) | an abort or panic on a degenerate command line (an assertion on argv: `vera ""`) | the exit contract in `src/main.zig`: exit 0, 1 or 2, a nonzero exit with its reason on stderr, never a signal; every flag `vera --help` documents x "", "-", "=", a 128 KiB value (Linux's per-argument ceiling), missing, repeated, on no input, an empty and a real `.va`, a `.v`, and again after `--emit-so` | `tests/argv.zig` (`test-argv`, in `test`) |
| Analog pipeline (`src/ir`, `src/analog`, `src/prove`) | wrong derivative | central difference of the residual | `suite -- --certify` (L4a, nightly) |
| | wrong number, no crash | hand-derived values; ngspice | `//!` checks in fixtures; `tools/external_analog.py` (`tests/osdi` in ngspice) |
| | a check too loose to see an error | the same check with its expected value moved 0.1% must fail | `suite -- --perturb` (L2b) |
| | a domain proof that is wrong (`.optimized` on a slice that can produce a non-finite value, a refusal no point justifies) | 400 random MIR programs evaluated at 48 points inside their ranges with the device's own math (`contract.gm`), sharing none of the prover's reasoning | `src/prove/falsify.zig` (`test-prove`) |
| Every pass | a stack overflow on wide input: a walk one call per statement, arm or term, which no parse nesting measures (case_5000, chainNext) | the 1 MiB stack itself: N = 5000 statement chains, `case` arms, sum terms and else-if chains, and N-deep nesting to compare, as a `.va` through `--lint`, `--emit-zig`, the `--emit-so` tree and `--emit-verilog` and as a `.v` through `--elab`, `--run` and `--emit-rtlil`, one child per row; an emitter's text must hold the last element | `tests/generators.zig` `wide` (`test-generators`, in `test`; known rows in its `known`) |
| Front end (`lib/frontend`, `lib/diag`) | a crash past the 65535-file table (every location's file id is 16 bits; each `include registers its file again) | the coded refusal: 65535 `include lines (with the source, one file past the table) are E0154 under `vera.compile` and `digital.elaborate`, and one fewer is not | `tests/generators.zig` `files` (`test-generators`, in `test`) |
| Name resolution (`lib/sim/digital`, `src/codegen/digital`, `src/vpi`) | an escaped identifier (IEEE 1364-2005 §3.7.1: `\a[1] ` is one name) split, merged or asserted on: the defparam `segment()` abort | renaming: seeded escaped names holding a bracket, a parenthesis, a dot, a `[k]` suffix, a bare `[k]` or a leading backslash must behave as plain names, a three-level `defparam` and hierarchical reads under `--run` printing the hand-derived `8 2 7`, and `--emit-rtlil`'s text renamed equal to the plain design's; through VPI, each object's `vpiFullName` given back to `vpi_handle_by_name` names that object, and its `vpiName` is the declared identifier | `tests/generators.zig` `escaped` (`test-generators`), `tests/vpi_escaped/` (`test-vpi-escaped`); both in `test`, known rows in their `known` |
| Codegen backends (`src/codegen`) | emitted code wrong for a host | the host that drives it, beside the device | `tests/host/*_host.zig` (in `test`) |
| OSDI dyn (`lib/osdi_dyn`) | a wrong Jacobian entry or limited RHS, no crash | the residual's central difference; a diode's closed form at the clamp and OSDI's second RHS path | `lib/osdi_dyn/eval.zig` (in `test`); ngspice through `tools/external_analog.py` |
| Device contract (`lib/contract`) | a reference family's derivative lane wrong | a central difference of the family's own value | `lib/contract/family.zig` (`test-contract`) |
| | wrong `%e` text, wrong special-function value | the C11 7.21.6.1 and C99 F.10.2.1 rows | `lib/contract/c_format.zig`, `lib/contract/gm.zig` (`test-contract`) |
| Zig builds (`src/zigbuild`) | a stale cached library after an edit | metamorphic: an edit to any file under a module root changes the key, no edit keeps it, a relocated tree keys the same; end to end, the rebuilt library is the edited one | `src/zigbuild/artifact_cache.zig`, `src/zigbuild/library.zig` (`test-zigbuild`) |
| | emitted Verilog / RTLIL wrong | verilator, iverilog, yosys reading it | `zig build test-external` |
| | nondeterministic output | the same command twice, and from another cwd, byte-identical | `conformance.py determinism` (L11, nightly) |
| | target-dependent output | native `vera` against `vera.wasm`, byte-identical | `cross.yaml`'s `wasm` job |
| | unintended change | a reviewed snapshot of every fixture's `--emit-zig`, `--emit-verilog` (`.va`), `--emit-rtlil` (`.v`), runner, program and `--emit-so` tree, and the tree again with `vpi_contribs` on (the files that differ: the path only the VPI host reaches), plus `tests/rtlil` and `tests/beh_verilog` | `suite -- golden <tag> [filter]` / `golden diff` (by hand, before and after) |
| Digital runtime (`lib/sim`) | wrong transcript | the recorded `.expected.txt`/`.vcd`, and iverilog on ivtest | `suite -- devices`, `suite -- ieee1364 --native`, the conformance suite's manifests |
| Kernels (`lib/kernels`) | wrong RNG stream | the IEEE 1364 §17.9.3 C listing | `tests/rng_reference.zig` (in `test`) |
| | wrong `%e/%f/%g` | glibc `snprintf` | `tests/printf_reference.zig` (in `test`) |
| VPI (`src/vpi`) | ABI or behaviour drift | the C applications' expected stdout and exit | `tests/conformance/tests/**/*.c` (`test`; `suite -- vpi` compiles only) |
| | an unchecked C-application argument: a crash, or a quiet wrong answer, on a NULL, forged or wrong-type handle, a NULL value pointer, a bad format, type, property, flag or reason, an out-of-range index | IEEE 1364-2005 §27.4 `vpi_chk_error` reports an error and the routine returns its documented failure value (NULL, 0, `vpiUndefined`, EOF, the failed mcd); each row in its own child, so a crash names its row; known rows are `known[]` in the app, an XPASS fails | `tests/vpi_negative/negative.c` (`test`, `test-vpi-negative`) |
| Downstream (ESPice) | a VerA change breaks a consumer | ESPice's decks and their oracle records | `spice.yaml` imports a pinned ESPice release and runs `zig build test-spice -Despice=PATH` (disabled until a release exists; not in the merge gate: VerA's build does not depend on ESPice); `pages.yaml` compiles ESPice's models |
| Every module | an allocation failure swallowed or leaked | `checkAllAllocationFailures` | `tests/unit.zig`'s `oom_tests` |
| Base (`lib/base`) | an interned id renumbered or lost | a linear-scan model of first-seen order, over a seeded op sequence through an overlay | `lib/base/interner.zig` (`test-base`) |
| The harness itself | a verdict lost from the log (`suite -- ams > log 2>&1` lost its first FAIL lines: a positional stdio writer wrote from offset 0, under `zig build`'s summary) | the log itself; a source scan that no stdout/stderr writer is positional; the FAIL and XFAIL name lists after the summary, compared by name against `tests/suite.xfail` (an unlisted FAIL and a listed pass, XPASS, both fail the run) | `tests/suite.zig` (`test-suite`), `suite -- ams` |
| Kernels and emitters (`lib/kernels`, `src/codegen`, `lib/frontend`, `lib/sim/rt`) | a vectorised loop gone scalar, a branchless ladder (`limit_kernels`' `*Clamp`) branching again: right numbers, lost speed | the x86_64_v3 ReleaseFast assembly against each probe's `expect:` line (`vector>=N`, `branches==0`); the judge's own selftest must FAIL wrong assembly | `tests/codegen_probe.zig`, `tools/asm_probe.py` (`test-probe`, in `test`) |
| The harness itself | a judge that passes everything | wrong-on-purpose fixtures must FAIL | `tests/canary/` (in `test`), `host.py selftest`, `conformance.py selftest` |

Assertions in production code multiply every layer: tests run in Debug
with safety checks on, so a broken invariant is a crash the fuzzer sees.

## Tiers

| Tier | Budget | Command | Measured |
|---|---|---|---|
| Pre-commit | under 10 s | `nix develop -c zig build check` | 7 s cold, under 1 s with `--watch -fincremental` |
| Merge (required) | under 15 min | `test.yaml` (`zig build test` on Linux, macOS, Windows), `cross.yaml` (`build-all` on five targets, wasm), `conformance.yaml` (`suite -- ams`, `devices`, `vpi`, `--native`), `external.yaml`, `nix.yaml` | `test` 73 s locally, 9-12 min in CI; `conformance` 13-21 min; `nix` 14-18 min |
| Nightly | hours | `nightly.yaml`: perturb, certify, fuzz, determinism, sweep | 19-31 min |
| Release | unbounded | `publish.yaml`: the merge gate again, `conformance.py --check <tag>`, every target, `sources.json` through `nix flake check` | |

`conformance` and `nix` are over the merge budget; they are the first to
split when the queue backs up.

Baselines are by name, never by count: `zig build conformance` fails on any
FAIL not listed in `tools/vera.xfail` and on any listed test that passes.

## What a release shows

- The fixture suites pass, with only named expected failures (`//! xfail`,
  `tools/vera.xfail`, `tests/suite.xfail`), none of them stale.
- The CHANGELOG's measures equal the tree's (`conformance.py --check`).
- Determinism holds on every fixture; native and wasm emit the same bytes.
- Zero open crash bugs.

## Not yet tested

- GPU devices: NVPTX and AMDGCN objects are compiled and their kernel
  symbol checked, never run on a card. "Compiles for CUDA/HIP; untested."
- Metamorphic relations (node renumbering, impedance scaling) over the
  analog corpus.
- Mutation testing, and adversarial input sizes (deep nesting, huge counts).
- Fuzzing is bounded at 200K runs nightly; no CPU-hour floor and no
  checked-in corpus.
- `vera.wasm` in a browser: only under wasmtime, on one fixture.
- House style: `tools/check_style.py` (the code-style checklist's mechanical
  rows) runs by hand, not in `check`; the tree does not pass it yet.
