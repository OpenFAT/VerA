# External accuracy suites

VerA's own fixtures check VerA against values derived by hand from the
standard. The external suites check it against other people's tests and
other people's tools: published QA references for compact models, the
Icarus Verilog regression suite, and the simulators the industry already
trusts. Where VerA and a reference disagree, one of them is wrong, and the
suite prints the case by name so someone can find out which.

None of the external code is stored in the repository. Each suite is a
folder under
`tests/conformance/vera/external/` (the VAMS Conformance Suite submodule)
holding a manifest that pins what is fetched (a URL and a commit, or a file
and its SHA-256) and states its license. The scripts fetch it at run time
into `.zig-cache/external/`, which git ignores.

## The tools they need

The reference tools come from one Nix shell:

```sh
nix develop .#benchmarking
```

It carries Icarus Verilog, Verilator and Yosys (IEEE 1364), ngspice (which
loads VerA's devices as OSDI libraries), Xyce, gnucap, and OpenVAF-Reloaded
(`openvaf-r`, x86_64 Linux only). Build `vera` in the shell first:
`zig build -Doptimize=ReleaseFast`.

## Analog: `tools/external_analog.py`

```sh
python3 tools/external_analog.py                 # every suite
python3 tools/external_analog.py osdi va-models  # some of them
```

| Suite | What it compares |
|---|---|
| `osdi` | small decks whose answers are derived by hand, run in ngspice over `vera --emit-osdi` libraries: the proof that ngspice loads a VerA device and gets the right numbers |
| `va-models` | the compact models of [dwarning/VA-Models](https://github.com/dwarning/VA-Models), compiled by VerA and by OpenVAF-Reloaded, the same QA tests run on both in one ngspice, every output compared |
| `cmcqa` | the CMC QA test specifications and their published reference results ([ominux/cmcqa](https://github.com/ominux/cmcqa)), through ngspice and VerA |
| `hicum-qa` | TU Dresden's HICUM/L2 QA tests and their published references |
| `xyce` | VerA in ngspice against Xyce's own built-in model of the same version: a third opinion |

Two numbers are compared with the CMC's rule (from cmcqa's
`compareSimulationResults.pl`): they match when both are below a clip
value, when they agree to a number of significant digits, or when their
relative error is under a tolerance. The script's header lists the values
for DC, AC and noise.

It prints `PASS <name>` or `FAIL <name>: <why>` per model, analysis and
quantity, writes the sorted FAIL names to `fail.txt` in its output
directory (`--out DIR`), and exits 1 on a FAIL that no row of its suite's
`TRIAGE.md` names, or on a row that names no FAIL. A model's QA tests run
in parallel (`VERA_EXTERNAL_JOBS`, default one per CPU), and each simulator
run is killed after `VERA_EXTERNAL_TIMEOUT` seconds (default 120), so a deck
that never converges is one FAIL, not a hung job. CI runs it in the
`external-analog` jobs, one per suite, on every push to `main` and every
pull request.

## The conformance suite: `zig build conformance`

The digital suites (ivtest, sv-tests' IEEE 1364-2005 subset, the ISP RAS
examples of the standard) moved to the
[VAMS Conformance Suite](https://github.com/OmarSiwy/VAMS-Conformance-Suite),
checked out at `tests/conformance`, with VerA's own Verilog, Verilog-A,
Verilog-AMS and Annex E tests and the OpenVAF, gnucap-modelgen and VA-Models
corpora:

```sh
git submodule update --init --recursive tests/conformance
nix develop .#external -c zig build -Doptimize=ReleaseFast conformance
```

Its harness, `conform`, judges each test by the suite's own rules and writes
every verdict to `zig-out/conformance.tsv`. A failure is untriaged until a
line of `tools/vera.xfail` names it; a listed test that passes is an XPASS and
fails too. CI runs it in the `conformance` job.

## Reading a FAIL

A FAIL is a question, not a verdict. The reference can be wrong, or two
readings of the standard can both be legal; VerA's choices where the
standard leaves one open are in [Implementation-defined
choices](implementation.md). When you compare two runs, compare the FAIL
*names*, not their count: a count can stay the same while one case is fixed
and another breaks.
