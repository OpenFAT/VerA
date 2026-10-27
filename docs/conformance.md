# Conformance and performance

VerA is measured against the
[VAMS Conformance Suite](https://github.com/OmarSiwy/VAMS-Conformance-Suite),
checked out as the `tests/conformance` submodule. The suite is tool-neutral:
it holds the Verilog-A, Verilog-AMS, IEEE 1364 and Annex E fixtures by
language and chapter, plus the external corpora (ivtest, sv-tests' IEEE
1364-2005 subset, the ISP RAS examples, OpenVAF, gnucap-modelgen,
VA-Models), and VerA runs it through the suite's own `conform` harness like
any other tool.

## Run it

```sh
git submodule update --init --recursive tests/conformance
nix develop .#external -c zig build -Doptimize=ReleaseFast conformance
```

`conform` judges each test by the suite's rules and writes every verdict to
`zig-out/conformance.tsv`. A known failure is a line of
[`tools/vera.xfail`](https://github.com/OmarSiwy/VerA/blob/main/tools/vera.xfail);
the run fails on any FAIL not listed there and on any listed test that passes
(XPASS), so the list cannot go stale. Compare two runs by test *name*, not
by count: a count can stay the same while one case is fixed and another
breaks.

`python3 tools/conformance.py` turns a run into the per-language score a
release carries (`--changelog` writes it into `CHANGELOG.md`, `--check`
re-measures and refuses a tag whose number differs).

VerA's own fixture runner (`zig build suite -- ams`, `-- devices`, `-- vpi`)
runs the same fixtures with VerA's testbench semantics; its known failures
are lines of `tests/suite.xfail`. See
[the test guide](https://github.com/OmarSiwy/VerA/blob/main/tests/README.md)
for the focused commands and fixture conventions.

## The live report

The [conformance and speed report](https://omarsiwy.github.io/VerA/report/)
is rebuilt from scratch on every push to `main`. It holds the fixture
results, the open gaps and defects, the compile-time distribution, and the
build time of the ARPice compact models.
