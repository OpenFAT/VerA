#!/usr/bin/env python3
"""VerA's `--emit-osdi` devices in ngspice, against hand-derived values.

    tools/external_analog.py [--vera PATH] [--out DIR]

Run it in `nix develop .#external` (ngspice). Each `tests/osdi/<name>.sp`
beside `<name>.va` carries `*! expect <vector> <value> <reltol>` lines: the
oracle is the hand derivation, checked against ngspice's `print` of that
vector with `{osdi}` replaced by VerA's library. Every simulator run is killed
after $VERA_EXTERNAL_TIMEOUT seconds (default 120): a deck that never
converges FAILs by name.

Prints one `PASS <name>` or `FAIL <name>: <why>` line per expectation, writes
the sorted FAIL names to `<out>/fail.txt` and exits 1 on any FAIL.
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OSDI = ROOT / "tests" / "osdi"

results = []  # (name, ok, why)

SIM_TIMEOUT = float(os.environ.get("VERA_EXTERNAL_TIMEOUT", "120"))


def record(name, ok, why=""):
    results.append((name, ok, why))
    print(f"PASS {name}" if ok else f"FAIL {name}: {why}", flush=True)


def digest(va, extra):
    h = hashlib.sha256(extra.encode())
    for f in sorted(va.parent.rglob("*")):
        if f.is_file() and f.suffix.lower() in (".va", ".v", ".vams", ".h", ".include", ".inc"):
            h.update(f.name.encode() + f.read_bytes())
    return h.hexdigest()[:16]


class Compiler:
    def __init__(self, vera, cache):
        self.vera = Path(vera).resolve()
        self.cache = cache
        st = self.vera.stat() if self.vera.exists() else None
        self.vera_id = f"{st.st_mtime_ns}:{st.st_size}" if st else ""

    def osdi(self, va):
        """`va` (a .va or .v) compiled by `vera --emit-osdi`, cached; (path, error)."""
        va = Path(va).resolve()
        key = digest(va, self.vera_id)
        out = self.cache / "osdi" / f"{va.stem}{va.suffix}.vera.{key}.osdi"
        if out.exists():
            return out, None
        out.parent.mkdir(parents=True, exist_ok=True)
        if not self.vera.exists():
            return None, f"{self.vera} not found: run `zig build install`"
        r = subprocess.run([str(self.vera), "--emit-osdi", "--work-dir", str(self.cache / "vera-work"), str(va), "-o", str(out)],
                           cwd=va.parent, capture_output=True, text=True, timeout=1800)
        if r.returncode != 0 or not out.exists():
            errs = [line for line in (r.stderr + r.stdout).splitlines() if "error" in line.lower()]
            return None, (errs[0] if errs else f"exit {r.returncode}")[:300]
        return out, None


def ngspice(deck, workdir):
    """Runs `deck`; returns (stdout+stderr, ok)."""
    path = workdir / "deck.sp"
    path.write_text(deck)
    try:
        r = subprocess.run(["ngspice", "-b", str(path)], cwd=workdir, capture_output=True, text=True, timeout=SIM_TIMEOUT)
    except subprocess.TimeoutExpired:
        return f"Error: timeout after {SIM_TIMEOUT:g} s", False
    out = r.stdout + r.stderr
    bad = re.search(r"(?m)^(Error|.*[Tt]imestep too small|.*singular matrix|.*no convergence|.*simulation\(s\) aborted)", out)
    return out, r.returncode == 0 and not bad


def suite_osdi(ctx):
    """Hand-derived decks: each `<name>.sp` beside `<name>.va` carries
    `*! expect <vector> <value> <reltol>` lines, checked against ngspice's
    `print` of that vector with `{osdi}` replaced by VerA's library, and
    `{osdi_v}` by its library of a `<name>.v` beside it."""
    d = OSDI
    with tempfile.TemporaryDirectory(prefix="vera-osdi-") as tmp:
        for sp in sorted(d.glob("*.sp")):
            name = f"osdi/{sp.stem}"
            osdi, err = ctx.cc.osdi(sp.with_suffix(".va"))
            text = sp.read_text()
            if not err and sp.with_suffix(".v").exists():
                osdi_v, err = ctx.cc.osdi(sp.with_suffix(".v"))
                text = text.replace("{osdi_v}", str(osdi_v))
            expects = re.findall(r"(?m)^\*! expect (\S+) (\S+) (\S+)", text)
            if err:
                for v, _, _ in expects:
                    record(f"{name}/{v}", False, f"vera --emit-osdi: {err}")
                continue
            log, _ = ngspice(text.replace("{osdi}", str(osdi)), Path(tmp))
            got = dict(re.findall(r"(?m)^(\w+) = (\S+)", log))
            for v, want, tol in expects:
                if v not in got:
                    record(f"{name}/{v}", False, "not printed")
                    continue
                g, w = float(got[v]), float(want)
                ok = abs(g - w) <= float(tol) * abs(w)
                record(f"{name}/{v}", ok, "" if ok else f"got {g:.12g}, want {w:.12g} (rel {float(tol):g})")


class Ctx:
    pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vera", default=str(ROOT / "zig-out" / "bin" / "vera"))
    ap.add_argument("--out", default=str(ROOT / ".zig-cache" / "external-out"))
    a = ap.parse_args()
    ctx = Ctx()
    ctx.cc = Compiler(a.vera, Path(os.environ.get("VERA_EXTERNAL_CACHE", ROOT / ".zig-cache" / "external")).resolve())
    if shutil.which("ngspice"):
        suite_osdi(ctx)
    else:
        record("osdi/harness", False, "ngspice not on PATH: run in `nix develop .#external`")
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    fails = sorted(n for n, ok, _ in results if not ok)
    (out / "fail.txt").write_text("".join(n + "\n" for n in fails))
    print(f"external-analog: {len(results) - len(fails)} PASS, {len(fails)} FAIL ({out / 'fail.txt'})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
