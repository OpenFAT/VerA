# External accuracy suites

VerA's own fixtures check VerA against values derived by hand from the
standard. The external suites check it against other people's tests and
other people's tools. Where VerA and a reference disagree, one of them is
wrong, and the suite prints the case by name so someone can find out which.

The reference tools come from one Nix shell:

```sh
nix develop .#external
```

It carries Icarus Verilog, Verilator and Yosys (IEEE 1364), ngspice (which
loads VerA's devices as OSDI libraries) and the conformance suite's `conform`
harness. Build `vera` in the shell first: `zig build -Doptimize=ReleaseFast install`.

## The conformance suite: `zig build conformance`

The [VAMS Conformance Suite](https://github.com/OmarSiwy/VAMS-Conformance-Suite),
checked out at `tests/conformance`, carries the Verilog, Verilog-A,
Verilog-AMS and Annex E tests and the external corpora (ivtest, sv-tests'
IEEE 1364-2005 subset, the ISP RAS examples of the standard, OpenVAF,
gnucap-modelgen, VA-Models):

```sh
git submodule update --init --recursive tests/conformance
nix develop .#external -c zig build -Doptimize=ReleaseFast conformance
```

Its harness, `conform`, judges each test by the suite's own rules and writes
every verdict to `zig-out/conformance.tsv`. A failure is untriaged until a
line of `tools/vera.xfail` names it; a listed test that passes is an XPASS and
fails too. CI runs it in the `conformance` job.

## OSDI in ngspice: `tools/external_analog.py`

```sh
python3 tools/external_analog.py
```

Small decks in `tests/osdi/` whose answers are derived by hand, run in
ngspice over `vera --emit-osdi` libraries: the proof that ngspice loads a
VerA device and gets the right numbers (`mixed.sp` loads a `.v` design's
library beside a `.va` model's). It prints `PASS <name>` or
`FAIL <name>: <why>` per expected value, writes the sorted FAIL names to
`fail.txt` in its output directory (`--out DIR`) and exits 1 on any FAIL.
Each simulator run is killed after `VERA_EXTERNAL_TIMEOUT` seconds (default
120), so a deck that never converges is one FAIL, not a hung job. CI runs it
in the `external-analog` job.

## VerA's output in the reference tools: `zig build test-external`

`--emit-verilog`'s modules get a verilator `-Wall` lint and an iverilog
testbench each, and `--emit-rtlil` of `tests/rtlil/*.v` is read, proc'ed and
checked by Yosys.

## Reading a FAIL

A FAIL is a question, not a verdict. The reference can be wrong, or two
readings of the standard can both be legal; VerA's choices where the
standard leaves one open are in [Implementation-defined
choices](implementation.md). When you compare two runs, compare the FAIL
*names*, not their count: a count can stay the same while one case is fixed
and another breaks.
