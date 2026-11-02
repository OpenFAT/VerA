#!/usr/bin/env python3
"""Hold tests/codegen_probe.zig's assembly to its `expect:` lines.

    tools/asm_probe.py PROBE.zig PROBE.s   # one row per `expect:` line; exit 1 on any FAIL
    tools/asm_probe.py selftest            # the judge must FAIL wrong assembly

`zig build test` builds PROBE.s (x86_64_v3, ReleaseFast, `-femit-asm`) and runs
this on it. An `expect:` line is `// expect: <function> <metric><op><N>`:

    vector     instructions with a packed `ymm` operand
    branches   conditional jumps (`j<cc>`; a `jmp` is not one)

`<function>` is the label's tail: `fill_f64` matches `.Lcodegen_probe.fill_f64`,
`limit_kernels.zFetlimClamp` the ladder that file keeps out of line. A function
missing from the assembly FAILs: an inlined or renamed probe is a stale probe.
"""
import operator
import re
import sys

EXPECT = re.compile(r"//\s*expect:\s*(\S+)\s+(vector|branches)(>=|==|<=)(\d+)")
LABEL = re.compile(r"^(?:\.L)?([A-Za-z_][\w.$]*):")
OPS = {">=": operator.ge, "==": operator.eq, "<=": operator.le}


def functions(asm):
    """{label: [instruction lines]} for every function body in `asm`."""
    bodies, current = {}, None
    for line in asm.splitlines():
        m = LABEL.match(line)
        if m and not re.match(r"(BB|CPI|func_end|tmp)", m.group(1)):
            current = bodies.setdefault(m.group(1), [])
        elif line.startswith(".Lfunc_end"):
            current = None
        elif current is not None and line[:1].isspace() and not line.strip().startswith("."):
            current.append(line.strip())
    return bodies


def metric(body, name):
    if name == "vector":
        return sum("ymm" in i for i in body)
    return sum(bool(re.match(r"j(?!mp)[a-z]+\s", i)) for i in body)


def judge(source, asm):
    """[(ok, row text)] for every `expect:` line of `source` against `asm`."""
    bodies = functions(asm)
    rows = []
    for fn, name, op, want in EXPECT.findall(source):
        hits = [b for label, b in bodies.items() if label == fn or label.endswith("." + fn)]
        if len(hits) != 1:
            rows.append((False, f"FAIL {fn}: {len(hits)} functions in the assembly match (want 1)"))
            continue
        got = metric(hits[0], name)
        ok = OPS[op](got, int(want))
        rows.append((ok, f"{'ok  ' if ok else 'FAIL'} {fn}: {name}={got}, expect {name}{op}{want}"))
    if not rows:
        rows.append((False, "FAIL: the probe source has no `expect:` line"))
    return rows


def selftest():
    asm = ".Lp.f:\n\tvaddpd\tymm0, ymm1, ymm2\n\tjne\t.LBB0_1\n\tjmp\tg\n.Lfunc_end0:\n"
    cases = [
        ("// expect: f branches==0", False),
        ("// expect: f branches==1", True),
        ("// expect: f vector>=1", True),
        ("// expect: f vector>=2", False),
        ("// expect: missing branches==0", False),
        ("no expectation", False),
    ]
    bad = [src for src, want in cases if all(ok for ok, _ in judge(src, asm)) != want]
    for src in bad:
        print(f"FAIL selftest: `{src}` judged wrongly")
    return 1 if bad else 0


def main(argv):
    if argv[1:] == ["selftest"]:
        return selftest()
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[1]) as s, open(argv[2]) as a:
        rows = judge(s.read(), a.read())
    ok = all(good for good, _ in rows)
    # A failure's rows on stderr: `zig build` shows a failed check's stderr,
    # and reports any stderr of a passing one as noise.
    for _, text in rows:
        print(text, file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
