#!/usr/bin/env python3
"""VAMPyRE against VerA: the CMC's Verilog-A rule checker and VerA's own
analyses, on the same compact models, compared finding by finding.

    tools/external_vampyre.py [--vera PATH] [--out DIR] [MODEL ...]

The models: the suite's own self-test probes (tests/fixtures/external/vampyre/
*.va, each naming with `// vampyre-agree: <finding>/<key>` (a plain comment,
so the fixture suite does not collect them) the agreements it must
produce, so an empty comparison cannot pass), the va-models suite's rows
(dwarning/VA-Models) and the cmcqa suite's (ominux/cmcqa), each at its pin.
VAMPyRE is tests/conformance/vera/external/vampyre/MANIFEST's pin. Both land in
the cache (`$VERA_EXTERNAL_CACHE`, default `.zig-cache/external`). Two findings
both tools make are compared; every other VAMPyRE message is reported, not
judged:

    hidden   a variable read before it is set in an evaluation. VAMPyRE:
             "... depends on X, which has not been set". VerA: X is held
             across evaluations for retention (§5.10, `HeldVar.Why`
             `retained` or `unless_invariant`), an `Instance` field
             `<m>__held__X` whose comment names the reason.
    intdiv0  integer division by a divisor that may be zero. VAMPyRE:
             "Integer divide" and "Possible division by zero" on one line.
             VerA: W0653 on that line.

Prints `PASS <name>` for a finding both report and `FAIL <name>: <why>` for
one only one reports, `<model>/<finding>/<key>`, and writes the sorted FAIL
names to `<out>/fail.txt`. A FAIL is KNOWN when a row of the suite's TRIAGE.md
names it (fnmatch); a row that names no FAIL of a full run is STALE. Exits 1
on any untriaged FAIL or STALE row.
"""
import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import external_analog as ea  # noqa: E402  (manifest, fetch_git, triage, judge, models_of)

ROOT = ea.ROOT
ANNEX_D = ROOT / "lib" / "frontend" / "pp" / "annex_d.zig"


def annex_d(dest):
    """VerA's own D.1/D.2 text as files, so both tools read the same
    disciplines.vams and constants.vams (VAMPyRE ships neither)."""
    src = ANNEX_D.read_text()
    dest.mkdir(parents=True, exist_ok=True)
    for decl, name in (("constants_vams", "constants.vams"), ("disciplines_vams", "disciplines.vams")):
        m = re.search(r"pub const " + decl + r" =\n((?:[ \t]*\\\\.*\n)+)", src)
        (dest / name).write_text("".join(re.sub(r"^[ \t]*\\\\", "", l) + "\n" for l in m.group(1).splitlines()))
    return dest


def vampyre(tool, va, incs):
    """(hidden names, intdiv0 lines, other message kinds) from one VAMPyRE run."""
    argv = [sys.executable, str(tool), "-n", "--max_num", "0"]
    for d in incs:
        argv += ["-I", str(d)]
    out = ea.run(argv + [str(va)]).stdout
    hidden, div, idiv, other = set(), set(), set(), {}
    for kind, f, line, msg in re.findall(r"^(ERROR|WARNING|NOTICE) in file (.+?), line (\d+): (.*)$", out, re.M):
        key = (Path(f).name, int(line))
        m = re.search(r"depends on ([A-Za-z_]\w*), which has not been set", msg)
        if m:
            hidden.add(m.group(1))
        elif msg.startswith("Integer divide"):
            idiv.add(key)
        elif msg.startswith("Possible division by zero"):
            div.add(key)
        else:
            k = re.sub(r"'[^']*'|\b\w+\d\w*\b", "_", msg)[:60]
            other[k] = other.get(k, 0) + 1
    return hidden, {f"{f}:{n}" for f, n in div & idiv}, other


def vera(exe, va, incs):
    """(held names, W0653 lines) from one `vera --emit-zig` run, or None and
    the diagnostics when VerA refuses the model."""
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "dev.zig"
        argv = [str(exe), "--emit-zig", "--diagnostics=json", "-o", str(out)]
        for i in incs:
            argv += ["-I", str(i)]
        r = ea.run(argv + [str(va)])
        diags = [json.loads(l) for l in r.stderr.splitlines() if l.startswith("{")]
        if r.returncode != 0:
            return None, [d["code"] for d in diags if d["level"] == "error"] or [r.stderr.strip()[:200]]
        # A latch (`event`, `a2d`) is set before every read; only retention
        # is a read that sees the last evaluation's value (`HeldVar.Why`).
        held = set(re.findall(r"^\s+\w+?__held__(\w+):.*// §5\.10 held across evaluations: (?:retained|unless_invariant)$",
                              out.read_text(), re.M))
    w = {f"{Path(d['span']['file']).name}:{d['span']['line']}" for d in diags if d["code"] == "W0653"}
    return held, w


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vera", default=str(ROOT / "zig-out" / "bin" / "vera"))
    ap.add_argument("--out", default=str(ROOT / ".zig-cache" / "external" / "vampyre-out"))
    ap.add_argument("only", nargs="*")
    a = ap.parse_args()
    cache = Path(os.environ.get("VERA_EXTERNAL_CACHE", ROOT / ".zig-cache" / "external"))
    tool = ea.fetch_git(cache, "vampyre") / "vampyre.py"
    models = ea.fetch_git(cache, "va-models")
    qa = ea.fetch_git(cache, "cmcqa")
    annex = annex_d(cache / "vampyre-annex-d")
    corpus = []  # (name, .va, required agreements)
    for va in sorted((ea.EXT / "vampyre").glob("*.va")):
        want = re.findall(r"(?m)^// vampyre-agree: (\S+)", va.read_text())
        # A probe that names no agreement would pass on an empty comparison.
        corpus.append((f"self/{va.stem}", va, want or ["(none declared)"]))
    for name, rel, _spec, *_mod in ea.models_of("va-models"):
        corpus.append((f"va-models/{name}", models / rel, []))
    # The cmcqa rows' last columns are qaSpec defines (which simulator the QA
    # deck targets), not Verilog macros, so neither tool gets them.
    for name, folder, rel, *_rest in ea.models_of("cmcqa"):
        corpus.append((f"cmcqa/{name}", qa / "model_qa" / folder / rel, []))
    fails = []
    for name, va, required in corpus:
        if a.only and name not in a.only:
            continue
        va = va.resolve()
        incs = [annex, va.parent]
        v_hidden, v_div, other = vampyre(tool, va, incs)
        held, w0653 = vera(a.vera, va, incs)
        if held is None:
            fails.append(f"{name}/compile")
            ea.record(f"{name}/compile", False, f"VerA refused it: {' '.join(w0653)}")
            continue
        agreed = set()
        for finding, ours, theirs in (("hidden", held, v_hidden), ("intdiv0", w0653, v_div)):
            for key in sorted(ours | theirs):
                n = f"{name}/{finding}/{key}"
                if key in ours and key in theirs:
                    agreed.add(f"{finding}/{key}")
                    ea.record(n, True)
                else:
                    fails.append(n)
                    ea.record(n, False, "VerA only" if key in ours else "VAMPyRE only")
        for want in required:
            if want not in agreed:
                fails.append(f"{name}/missing/{want}")
                ea.record(f"{name}/missing/{want}", False, "a self-test agreement did not happen")
        for k, c in sorted(other.items()):
            print(f"INFO {name}: VAMPyRE {c}x {k}")
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "fail.txt").write_text("".join(f"{n}\n" for n in sorted(fails)))
    known, new, stale = ea.judge(sorted(fails), ea.triage("vampyre"))
    for n, pat in known:
        print(f"KNOWN {n} ({pat})")
    if a.only:
        stale = []
    for p in stale:
        print(f"STALE {p}")
    passed = sum(1 for _, ok, _ in ea.results if ok)
    print(f"vampyre: {passed} agree, {len(fails)} disagree ({len(known)} triaged, {len(new)} untriaged), {len(stale)} stale")
    return 1 if new or stale else 0


if __name__ == "__main__":
    sys.exit(main())
