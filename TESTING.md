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
| Front end (`lib/frontend`, `src/elab`) | crash or hang on any input | no signal, a diagnostic from the declared set | `tests/fuzz.zig` (`zig build fuzz --fuzz`), `conformance.py adversarial` (L10) |
| | wrong accept or refusal | the language reference, clause by clause | `//! lrm` fixtures (`suite -- ams`, `suite -- devices`), the requirement ledger (`conformance.py obligations`), the VAMS Conformance Suite (`zig build conformance`) |
| Analog pipeline (`src/ir`, `src/analog`, `src/prove`) | wrong derivative | central difference of the residual | `suite -- --certify` (L4a, nightly) |
| | wrong number, no crash | hand-derived values; ngspice, Xyce, OpenVAF-Reloaded, CMC and TU Dresden QA decks | `//!` checks in fixtures; `tools/external_analog.py` (gated by `TRIAGE.md` rows) |
| | a check too loose to see an error | the same check with its expected value moved 0.1% must fail | `suite -- --perturb` (L2b) |
| Codegen backends (`src/codegen`) | emitted code wrong for a host | the host that drives it, beside the device | `tests/conformance/vera/host/*_host.zig` (in `test`) |
| | emitted Verilog / RTLIL wrong | verilator, iverilog, yosys reading it | `zig build test-external` |
| | nondeterministic output | the same command twice, and from another cwd, byte-identical | `conformance.py determinism` (L11, nightly) |
| | target-dependent output | native `vera` against `vera.wasm`, byte-identical | `cross.yaml`'s `wasm` job |
| | unintended change | a reviewed snapshot | `suite -- golden <tag>` / `golden diff` (by hand, before and after) |
| Digital runtime (`lib/sim`) | wrong transcript | the recorded `.expected.txt`/`.vcd`, and iverilog on ivtest | `suite -- devices`, `suite -- ieee1364 --native`, the conformance suite's manifests |
| Kernels (`lib/kernels`) | wrong RNG stream | the IEEE 1364 §17.9.3 C listing | `tests/rng_reference.zig` (in `test`) |
| | wrong `%e/%f/%g` | glibc `snprintf` | `tests/printf_reference.zig` (in `test`) |
| VPI (`src/vpi`) | ABI or behaviour drift | the C applications' expected stdout and exit | `tests/conformance/tests/**/*.c` (`test`; `suite -- vpi` compiles only) |
| Downstream (ESPice) | a VerA change breaks a consumer | ESPice's decks and their oracle records | `spice.yaml` imports a pinned ESPice release and runs `zig build test-spice -Despice=PATH` (disabled until a release exists; not in the merge gate: VerA's build does not depend on ESPice); `pages.yaml` compiles ESPice's models |
| Every module | an allocation failure swallowed or leaked | `checkAllAllocationFailures` | `tests/unit.zig`'s `oom_tests` |
| The harness itself | a judge that passes everything | wrong-on-purpose fixtures must FAIL | `tests/conformance/vera/canary/` (in `test`), `host.py selftest`, `conformance.py selftest` |
| The tests | a test that cannot fail | a mutant of the code must be killed | `conformance.py mutate` (by hand, needs `vq`) |

Assertions in production code multiply every layer: tests run in Debug
with safety checks on, so a broken invariant is a crash the fuzzer sees.

## Tiers

| Tier | Budget | Command | Measured |
|---|---|---|---|
| Pre-commit | under 10 s | `nix develop -c zig build check` | 7 s cold, under 1 s with `--watch -fincremental` |
| Merge (required) | under 15 min | `test.yaml` (`zig build test` on Linux, macOS, Windows), `cross.yaml` (`build-all` on five targets, wasm), `conformance.yaml` (`conformance.py run`, the ratchet, `--native`), `external.yaml`, `nix.yaml` | `test` 73 s locally, 9-12 min in CI; `conformance` 13-21 min; `nix` 14-18 min |
| Nightly | hours | `nightly.yaml`: perturb, certify, fuzz, determinism, adversarial, sweep, the evidence-level ratchet | 19-31 min |
| Release | unbounded | `publish.yaml`: the merge gate again, `conformance.py --check <tag>`, every target, `sources.json` through `nix flake check` | |

`conformance` and `nix` are over the merge budget; they are the first to
split when the queue backs up.

Ratchets are by name, never by count: `conformance.py ratchet` fails on a
fixture that moves from pass to fail, `LEVELS.tsv` on a requirement whose
evidence level drops, `STEPS.txt` on a build step that disappears.

## What a release shows

- The fixture suites pass, with only named expected failures (`//! xfail`,
  `tools/vera.xfail`, `TRIAGE.md` rows), none of them stale.
- The CHANGELOG's measures equal the tree's (`conformance.py --check`).
- The external suites agree, or each disagreement is a triaged row.
- Determinism holds on every fixture; native and wasm emit the same bytes.
- No evidence level dropped (`LEVELS.tsv`); no build step vanished.
- Zero open crash bugs.

## Not yet tested

- GPU devices: NVPTX and AMDGCN objects are compiled and their kernel
  symbol checked, never run on a card. "Compiles for CUDA/HIP; untested."
- Metamorphic relations (node renumbering, impedance scaling) over the
  analog corpus.
- Mutation testing runs by hand, not in a tier.
- Fuzzing is bounded at 200K runs nightly; no CPU-hour floor and no
  checked-in corpus.
- `vera.wasm` in a browser: only under wasmtime, on one fixture.
