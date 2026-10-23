#!/usr/bin/env python3
"""The external analog suites: VerA's `--emit-osdi` devices in ngspice, against
hand-derived values, OpenVAF-Reloaded, published QA references and Xyce.

    tools/external_analog.py [--vera PATH] [--out DIR] [SUITE ...]

Run it in `nix develop .#external` (ngspice, openvaf-r, Xyce; `.#benchmarking`
has them too). SUITE is one or more of the folders under
tests/conformance/vera/external/, or osdi (tests/conformance/vera/osdi) (default: all):

    selftest   the harness's own compare, sweep and qaSpec parsing
    osdi       hand-derived ngspice decks over `vera --emit-osdi` devices
    va-models  dwarning/VA-Models compiled by VerA and by openvaf-r, the same
               QA tests run on both, every output compared
    cmcqa      ominux/cmcqa's published references through ngspice + VerA
    hicum-qa   TU Dresden's HICUM/L2 QA references through ngspice + VerA
    xyce       VerA (in ngspice) against Xyce's built-in model of the same
               version: a third opinion

A model's QA tests run in parallel ($VERA_EXTERNAL_JOBS, default one per CPU),
and every simulator run is killed after $VERA_EXTERNAL_TIMEOUT seconds
(default 120): a deck that never converges FAILs by name.

Each folder's MANIFEST pins what is fetched (`url`, `commit` or `sha256`) and
its license. Nothing fetched is committed: it lands in the cache
(`$VERA_EXTERNAL_CACHE`, default `.zig-cache/external`, git-ignored).

Prints one `PASS <name>` or `FAIL <name>: <why>` line per (model x analysis x
quantity) and writes the sorted FAIL names to `<out>/fail.txt` (the name list
to diff). A FAIL is `KNOWN` when a row of its suite's
TRIAGE.md names it (`| `pattern` | verdict | ... |`, an fnmatch pattern over
the whole name, so one root cause is one row); a row that names no FAIL of a
suite that ran in full is `STALE`. Exits 1 on any untriaged FAIL or STALE row.

QA tests use the CMC qaSpec format and compare with the CMC rule (ominux/cmcqa
`lib/compareSimulationResults.pl`): two numbers match when either is under the
clip, when they agree to nDigits significant digits (to 10 units in the next
one), or when their relative error is under relTol. Default clip / nDigits /
relTol: DC 1e-13 / 6 / 1e-6, AC 1e-20 / 6 / 1e-6, noise 1e-30 / 5 / 1e-5.
The netlists follow ominux/cmcqa `lib/spice.pm` (every pin voltage-driven, a
floating pin fed 0 A; AC: g = Re Y, c = Im Y / w on the diagonal and -Im Y / w
off it; noise: the pin current's PSD through a unit CCVS) with the instance
wired straight to the sources (the `standard` variant only).
"""
import argparse
import concurrent.futures
import fnmatch
import hashlib
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXT = ROOT / "tests" / "conformance" / "vera" / "external"
OSDI = ROOT / "tests" / "conformance" / "vera" / "osdi"
SUITES = ["selftest", "osdi", "va-models", "cmcqa", "hicum-qa", "xyce"]

# The solver tolerances every QA deck runs under: tight enough that Newton's
# leftover error at an internal node sits far below the compare's 1e-6, and
# no tighter than double precision can meet. abstol is 100x under the DC clip
# (1e-13 A); at 1e-18 A it sat under the rounding of a KCL sum of mA
# currents (an ulp of 1e-3 is 2e-19), so Newton never converged and ngspice
# stepped gmin, the sources and a transient op for minutes before failing
# (mosvar igvg, the Mextram Gummel sweeps, VBIC; OpenVAF's libraries alike).
OPTIONS = ".options reltol=1e-9 abstol=1e-15 vntol=1e-12"

results = []  # (name, ok, why)

# Every simulator run is capped: no passing deck takes more than seconds, and
# a deck that never converges (ngspice's transient op can step forever) is a
# FAIL by name instead of the job's whole budget.
SIM_TIMEOUT = float(os.environ.get("VERA_EXTERNAL_TIMEOUT", "120"))
JOBS = int(os.environ.get("VERA_EXTERNAL_JOBS", "0")) or os.cpu_count() or 1


def record(name, ok, why=""):
    results.append((name, ok, why))
    print(f"PASS {name}" if ok else f"FAIL {name}: {why}", flush=True)


def run(cmd, cwd=None, timeout=1800):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def pmap(fn, items):
    """`fn` over `items` on JOBS threads (each call runs a simulator
    process), results in order so the PASS/FAIL lines are deterministic."""
    with concurrent.futures.ThreadPoolExecutor(JOBS) as pool:
        yield from pool.map(fn, items)


# ---------------------------------------------------------------------------
# fetching and compiling
# ---------------------------------------------------------------------------


def manifest(suite):
    """`key: value` lines of the suite's MANIFEST (first occurrence wins)."""
    m = {}
    for line in (EXT / suite / "MANIFEST").read_text().splitlines():
        k, sep, v = line.partition(":")
        if sep and not line.startswith((" ", "#")) and k.strip() not in m:
            m[k.strip()] = v.strip()
    return m


def fetch_git(cache, suite):
    """The MANIFEST's `url` at its pinned `commit`, shallow-fetched once."""
    m = manifest(suite)
    dest = cache / suite
    if (dest / ".git").exists() and run(["git", "-C", str(dest), "rev-parse", "HEAD"]).stdout.strip() == m["commit"]:
        return dest
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    for argv in (["git", "init", "-q"], ["git", "fetch", "-q", "--depth", "1", m["url"], m["commit"]],
                 ["git", "checkout", "-q", "FETCH_HEAD"]):
        subprocess.run(argv, cwd=dest, check=True, timeout=1800)
    return dest


def triage(suite):
    """pattern -> verdict, from the suite's TRIAGE.md `| `pattern` | verdict |` rows."""
    p = EXT / suite / "TRIAGE.md"
    return dict(re.findall(r"(?m)^\|\s*`([^`]+)`\s*\|\s*([^|]+?)\s*\|", p.read_text())) if p.is_file() else {}


def judge(fails, rows):
    """(known, untriaged, stale): `fails` names split by whether an fnmatch
    pattern of `rows` covers them, and the patterns that cover none."""
    known, new, used = [], [], set()
    for n in fails:
        pat = next((p for p in rows if fnmatch.fnmatchcase(n, p)), None)
        (known if pat else new).append((n, pat))
        used.add(pat)
    return known, [n for n, _ in new], [p for p in rows if p not in used]


def fetch_zip(cache, suite, url, sha256):
    """`url` downloaded once, its sha256 checked against the MANIFEST, and
    unpacked into `<cache>/<suite>/<zip stem>/`."""
    dest = cache / suite / Path(url).name
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(url, timeout=120) as r:
            data = r.read()
        got = hashlib.sha256(data).hexdigest()
        if got != sha256:
            raise RuntimeError(f"{url}: sha256 {got}, MANIFEST pins {sha256}")
        dest.write_bytes(data)
    out = dest.with_suffix("")
    if not out.exists():
        with zipfile.ZipFile(dest) as z:
            z.extractall(out)
    return out


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
        st = self.vera.stat() if self.vera.exists() else None  # selftest needs none
        self.vera_id = f"{st.st_mtime_ns}:{st.st_size}" if st else ""

    def osdi(self, tool, va, includes=()):
        """`va` (a .va, or for vera a .v) compiled by `tool` ("vera" or
        "openvaf"), cached; (path, error)."""
        va = Path(va).resolve()
        key = digest(va, f"{tool}:{self.vera_id if tool == 'vera' else ''}:{includes}")
        out = self.cache / "osdi" / f"{va.stem}{va.suffix}.{tool}.{key}.osdi"
        if out.exists():
            return out, None
        out.parent.mkdir(parents=True, exist_ok=True)
        inc = [a for d in includes for a in ("-I", str(d))]
        # $VERA_EXTERNAL_WRAP prefixes each compile (a shared machine's
        # `flock <lock>`): a compile is the one step that needs real memory.
        wrap = os.environ.get("VERA_EXTERNAL_WRAP", "").split()
        if tool == "vera":
            cmd = [str(self.vera), "--emit-osdi", "--work-dir", str(self.cache / "vera-work"), *inc, str(va), "-o", str(out)]
        else:
            cmd = ["openvaf-r", *inc, str(va), "-o", str(out)]
        if not shutil.which(cmd[0]):
            return None, f"{cmd[0]} not found: run in `nix develop .#external`"
        r = run(wrap + cmd, cwd=va.parent)
        if r.returncode != 0 or not out.exists():
            errs = [line for line in (r.stderr + r.stdout).splitlines() if "error" in line.lower()]
            return None, (errs[0] if errs else f"exit {r.returncode}")[:300]
        return out, None


# ---------------------------------------------------------------------------
# ngspice
# ---------------------------------------------------------------------------


def ngspice(deck, workdir):
    """Runs `deck`; returns (stdout+stderr, ok)."""
    path = workdir / "deck.sp"
    path.write_text(deck)
    try:
        r = run(["ngspice", "-b", str(path)], cwd=workdir, timeout=SIM_TIMEOUT)
    except subprocess.TimeoutExpired:
        return f"Error: timeout after {SIM_TIMEOUT:g} s", False
    out = r.stdout + r.stderr
    bad = re.search(r"(?m)^(Error|.*[Tt]imestep too small|.*singular matrix|.*no convergence|.*simulation\(s\) aborted)", out)
    return out, r.returncode == 0 and not bad


def read_wrdata(path):
    """Rows of numbers from an appended `wrdata` file (header lines skipped)."""
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        f = line.split()
        try:
            rows.append([float(x) for x in f])
        except ValueError:
            continue
    return rows


class Printed(float):
    """A reference number and its printed significant digits: `0.0011276` is
    0.0011276 +- 5e-8, so no compare can ask it for a sixth digit."""

    def __new__(cls, text):
        x = super().__new__(cls, text)
        x.digits = len(re.sub(r"[eE].*|[^0-9]", "", text).lstrip("0")) or 1
        return x


def read_reference(path):
    """A published `.standard` file's rows, every number a `Printed`."""
    rows = []
    for line in path.read_text().splitlines() if path.exists() else []:
        try:
            rows.append([Printed(x) for x in line.split()])
        except ValueError:
            continue
    return rows


# ---------------------------------------------------------------------------
# the CMC compare
# ---------------------------------------------------------------------------

TOLS = {"dc": (1e-13, 6, 1e-6), "ac": (1e-20, 6, 1e-6), "noise": (1e-30, 5, 1e-5), "tran": (1e-13, 4, 1e-4)}


def cmc_match(a, b, clip, ndig, reltol):
    """compareSimulationResults.pl's per-number rule; (ok, relErr)."""
    if a == b:
        return True, 0.0
    if not (math.isfinite(a) and math.isfinite(b)):  # the Perl dies on a non-number
        return False, math.inf
    if abs(a) < clip or abs(b) < clip:
        return True, 0.0
    err = abs(a - b)
    rel = err / (0.5 * (abs(a) + abs(b) + err))
    if a * b <= 0:
        return False, rel
    lo, hi = sorted((abs(a), abs(b)))
    mag = int(math.log10(lo)) + 1
    if lo < 1:
        mag -= 1
    scale = 10 ** (ndig + 1 - mag)
    if abs(int(0.5 + lo * scale) - int(0.5 + hi * scale)) <= 10:
        return True, rel
    return rel < reltol, rel


def compare_cols(name, cols, ref, sim, kind):
    """One record per output column of `ref`/`sim` ([x, q1, q2, ...] rows).
    A `Printed` reference is matched to no more digits than it prints."""
    clip, ndig, reltol = TOLS[kind]
    if len(ref) != len(sim) or not ref:
        for c in cols:
            record(f"{name}/{c}", False, f"{len(sim)} rows simulated, {len(ref)} expected")
        return
    for j, c in enumerate(cols, start=1):
        worst, where = 0.0, None
        bad = False
        for r, s in zip(ref, sim):
            ok, rel = cmc_match(r[j], s[j], clip, min(ndig, getattr(r[j], "digits", ndig)), reltol)
            if not ok and (not bad or rel > worst):
                bad, worst, where = True, rel, (r[0], r[j], s[j])
        if bad:
            record(f"{name}/{c}", False, f"relErr {worst:.3g} at x={where[0]:g}: want {where[1]:.9g} got {where[2]:.9g}")
        else:
            record(f"{name}/{c}", True)


# ---------------------------------------------------------------------------
# qaSpec (ominux/cmcqa lib/modelQaTestRoutines.pm)
# ---------------------------------------------------------------------------

NUM = r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?"


def read_qaspec(path, defined):
    lines = []
    for raw in hier_lines(path):
        s = re.sub(r"\s*//.*", "", raw).strip()
        if not s:
            continue
        s = re.sub(r"\s*=\s*", "=", s)
        if s.startswith("+"):
            lines[-1] = re.sub(r"\s*\\$", "", lines[-1]) + " " + s[1:].strip()
        elif lines and lines[-1].endswith("\\"):
            lines[-1] = re.sub(r"\s*\\$", "", lines[-1]) + " " + s
        else:
            lines.append(s)
    lines = ifdefs(lines, dict.fromkeys(defined, True))
    setup, tests, cur = [], {}, None
    for s in lines:
        if re.match(r"(?i)test(name)?\s+", s):
            cur = s.split()[1]
            tests[cur] = []
        elif cur is None:
            setup.append(s)
        else:
            tests[cur].append(s)
    return setup, tests


def hier_lines(path, base=None):
    """`path`'s lines with every `` `include `` inlined. Like
    modelQaTestRoutines' readHierarchicalFile, an include names a file
    relative to the directory the QA runs in: the top qaSpec's."""
    base = base or Path(path).parent
    out = []
    for line in Path(path).read_text(errors="replace").splitlines():
        m = re.match(r'\s*`include\s+"?([^"\s]+)', line)
        out += hier_lines(base / m.group(1), base) if m else [line]
    return out


def ifdefs(lines, defined):
    out, stack = [], []  # stack of (taking, any_taken)
    for s in lines:
        live = all(t for t, _ in stack)
        if s.startswith("`ifdef") or s.startswith("`ifndef"):
            name = s.split()[1] if len(s.split()) > 1 else ""
            t = bool(defined.get(name)) ^ s.startswith("`ifndef")
            stack.append((t, t))
        elif s.startswith("`else"):
            t, _ = stack.pop()
            stack.append((not t, True))
        elif s.startswith("`end"):  # processIfdefs takes `end for `endif
            stack.pop()
        elif s.startswith("`define") and live:
            defined[s.split()[1]] = True
        elif s.startswith("`undef") and live:
            defined[s.split()[1]] = False
        elif live:
            out.append(s)
    return out


def drange(a, b, step):
    """modelQaTestRoutines' BiasSweepList: start, start+step, ... while within 0.1 step of stop."""
    step = abs(step) if b > a else -abs(step)
    out, v = [], a
    while (v <= b + 0.1 * step) if step > 0 else (v >= b + 0.1 * step):
        out.append(v)
        v += step
    return out


class Setup:
    def __init__(self, lines):
        self.pins, self.temps, self.float = [], [], set()
        self.ntype = None
        for s in lines:
            f = re.split(r"[\s,]+", s)
            k = f[0].lower()
            if k in ("pins", "terminals"):
                self.pins += f[1:]
            elif k == "temperature":
                self.temps += [float(x) for x in f[1:]]
            elif k.startswith("float"):
                self.float |= set(f[1:])
            elif re.match(r"(?i)(ntype|type|model)selectionarguments", k):
                self.ntype = s.split(None, 1)[1]
        self.temps = self.temps or [27.0]


class Test:
    """One qaSpec test (processTestSpec)."""

    def __init__(self, name, lines, setup):
        self.name = name
        self.pins = list(setup.pins)
        self.float = set(setup.float)
        self.temps, self.inst, self.model = [], [], []
        self.outputs, self.kind = [], None
        self.bias, self.ref = {}, {}
        self.sweep = self.blist = None
        self.freq = None
        self.tran = None
        for s in lines:
            k = s.split()[0].lower()
            rest = s.split(None, 1)[1] if len(s.split()) > 1 else ""
            if k in ("output", "outputs"):
                f = re.split(r"[\s,]+", rest.replace("(", " ").replace(")", ""))
                i = 0
                while i < len(f):
                    t = f[i]
                    if t in ("I", "V"):
                        self.kind = "dc"
                        self.outputs.append(f[i + 1])
                        i += 2
                    elif t in ("C", "G", "Q"):
                        self.kind = "ac"
                        self.outputs.append((t.lower(), f[i + 1], f[i + 2]))
                        i += 3
                    elif t == "N":
                        self.kind = "noise"
                        self.outputs.append(f[i + 1])
                        i += 2
                        if i < len(f) and f[i] in self.pins:
                            self.outputs.append(f[i])  # a correlation: cross noise
                            i += 1
                    else:
                        i += 1
            elif k == "biases":
                for m in re.finditer(r"V\(\s*(\w+)\s*(?:,\s*(\w+)\s*)?\)=(" + NUM + ")", rest):
                    self.bias[m.group(1)] = float(m.group(3))
                    if m.group(2):
                        self.ref[m.group(1)] = m.group(2)
            elif k in ("biassweep", "sweepbias"):
                f = re.split(r"[=,\s]+", re.sub(r"V\s*\(\s*|\s*\)", "", rest, count=2))
                a, b, st = float(f[1]), float(f[2]), float(f[3])
                self.sweep = (f[0], a, b, st if b > a else -abs(st))
                self.bias[f[0]] = a
            elif k in ("biaslist", "listbias"):
                f = re.split(r"[=,\s]+", re.sub(r"V\s*\(\s*|\s*\)", "", rest, count=2))
                self.blist = (f[0], [float(x) for x in f[1:] if x])
                self.bias[f[0]] = self.blist[1][0]
            elif k == "pins" or k == "terminals":
                self.pins = re.split(r"[\s,]+", rest)
            elif k == "instanceparameters":
                self.inst += rest.split()
            elif k == "modelparameters":
                for a in rest.split():
                    if "=" in a:
                        self.model.append(a)
                    else:  # a parameter file, relative to the qaSpec
                        self.model += [line for line in setup_param_file(a)]
            elif k.startswith("freq"):
                self.freq = rest
            elif k == "temperature":
                self.temps += [float(x) for x in re.split(r"[,\s]+", rest)]
            elif k.startswith("float"):
                self.float |= set(re.split(r"[\s,]+", rest))
            elif k == "tran":  # VerA's extension: `tran <tstep> <tstop> V(pin)=pulse(...)`
                f = rest.split(None, 2)
                self.tran = (f[0], f[1], f[2])
                self.kind = "tran"
        self.temps = self.temps or list(setup.temps)
        if self.tran:  # `outputs I(...)` after `tran` must not make it a DC test
            self.kind = "tran"
        if self.kind == "noise" and not self.freq:
            self.freq = "lin 1 1 1"
        if self.kind == "ac" and not self.freq:
            w = 1 / (2 * math.pi)
            self.freq = f"lin 1 {w!r} {w!r}"
        # Dedupe repeated model parameters, last wins (modelQaTestRoutines).
        seen = {}
        for a in self.model:
            seen[a.split("=")[0].lower()] = a
        self.model = list(seen.values())

    def single_freq(self):
        f = self.freq.split()
        return float(f[2]) == float(f[3])

    def sweep_list(self):
        if self.sweep:
            return [(self.sweep[0], v) for v in drange(self.sweep[1], self.sweep[2], self.sweep[3])]
        return [(None, None)]

    def bias_list(self):
        return [(self.blist[0], v) for v in self.blist[1]] if self.blist else [(None, None)]


_param_files = {}


def setup_param_file(path):
    """`name=value` of every parameter in a parameter file: a qaSpec one
    (`+ c10 = ( 9.074e-030 )`, relative to the qaSpec) or a SPICE `.model`
    card (`$SRC/<path>`, relative to the suite's checkout; `<path>#<name>`
    takes only the card `.model <name>` of a library)."""
    path, _, card = path.partition("#")
    if path.startswith("$SRC/"):
        f = Path(_param_files["src"], path[5:])
    else:
        f = Path(_param_files.get("dir", "."), path)
    text = re.sub(r"(?m)(^\s*\*|\$|//).*$", "", f.read_text(errors="replace"))
    if card:
        text = next(c for c in re.split(r"(?im)^\s*\.model\s+", text) if c.split()[:1] == [card])
    text = re.sub(r"\(\s*([^()]*?)\s*\)", r"\1", text)
    return [f"{k}={v}" for k, v in re.findall(r"([A-Za-z_]\w*)\s*=\s*([^\s=]+)", text)]


def fmt(v):
    return repr(float(v))


def source(pin, t, val, ac=False, suffix=""):
    """A pin's voltage source (or 0 A source when floating)."""
    node = pin + suffix
    if pin in t.float:
        return f"i_{pin}{suffix} {node} 0 0"
    ref = t.ref[pin] + suffix if pin in t.ref else "0"
    return f"v_{pin}{suffix} {node} {ref} dc {fmt(val)}" + (" ac 1" if ac else "")


def header(osdi, model, args, t):
    typ = args.split()
    return [
        f"* {t.name}",
        ".control",
        f"pre_osdi {osdi}",
        ".endc",
        OPTIONS,
        f".model mymodel {model} " + " ".join(typ[1:] + t.model),
    ]


def instance(t, suffix=""):
    return f"N1{suffix} " + " ".join(p + suffix for p in t.pins) + " mymodel " + " ".join(t.inst)


def deck_dc(osdi, model, args, t, out):
    d = header(osdi, model, args, t)
    d += [source(p, t, t.bias.get(p, 0.0)) for p in t.pins]
    d += [instance(t), ".control", "set numdgt=15", "set wr_singlescale", "set wr_vecnames", "set appendwrite"]
    sp, a, b, st = t.sweep
    vecs = " ".join(f"v({p})" if p in t.float else f"i(v_{p})" for p in t.outputs)
    for T in t.temps:
        for lp, lv in t.bias_list():
            d.append(f"set temp={fmt(T)}")
            if lp:
                d.append(f"alter v_{lp} dc = {fmt(lv)}")
            d.append(f"dc v_{sp} {fmt(a)} {fmt(b)} {fmt(st)}")
            d.append(f"wrdata {out} {vecs}")
    return d + [".endc", ".end"]


def parse_dc(t, out):
    rows = []
    for r in read_wrdata(out):
        # x then one value per output; a floating pin's voltage keeps its sign,
        # a pin current is the device's (into the pin): -i(v_pin).
        rows.append([r[0]] + [r[1 + j] if p in t.float else -r[1 + j] for j, p in enumerate(t.outputs)])
    return rows


def deck_ac(osdi, model, args, t, out):
    fpins = sorted({o[2] for o in t.outputs}, key=t.pins.index)
    d = header(osdi, model, args, t)
    for f in fpins:
        d += [source(p, t, t.bias.get(p, 0.0), ac=(p == f), suffix="_" + f) for p in t.pins]
        d.append(instance(t, "_" + f))
    d += [".control", "set numdgt=15", "set wr_singlescale", "set wr_vecnames", "set appendwrite"]
    vecs = " ".join(f"i(v_{m}_{f})" for (_, m, f) in t.outputs)
    for T in t.temps:
        for lp, lv in t.bias_list():
            for sp, sv in t.sweep_list():
                d.append(f"set temp={fmt(T)}")
                for f in fpins:
                    if lp:
                        d.append(f"alter v_{lp}_{f} dc = {fmt(lv)}")
                    if sp:
                        d.append(f"alter v_{sp}_{f} dc = {fmt(sv)}")
                d.append(f"ac {t.freq}")
                d.append(f"wrdata {out} {vecs}")
    return d + [".endc", ".end"]


def parse_ac(t, out):
    """g, c, q per output from the complex pin currents (spice.pm runAcTest)."""
    xs = [v for _ in t.temps for _ in t.bias_list() for (_, v) in t.sweep_list()]
    rows = []
    raw = read_wrdata(out)
    per = len(raw) // max(len(xs), 1)
    for k, r in enumerate(raw):
        freq = r[0]
        w = 2 * math.pi * freq
        row = [xs[k // per] if t.single_freq() and per else freq]
        for j, (typ, m, f) in enumerate(t.outputs):
            re_, im = -r[1 + 2 * j], -r[2 + 2 * j]  # current into the device pin
            if typ == "g":
                row.append(re_)
            elif typ == "c":
                row.append(im / w if m == f else -im / w)
            else:
                row.append(im / re_ if abs(re_) > 1e-99 else 1e99)
        rows.append(row)
    return rows


def deck_noise(osdi, model, args, t, out):
    pin = t.outputs[0]
    d = header(osdi, model, args, t)
    d += [source(p, t, t.bias.get(p, 0.0)) for p in t.pins]
    d += [instance(t), "vin dummy 0 0 ac 1", "rin dummy 0 1"]
    if pin in t.float:
        target = f"v({pin})"
    else:
        d.append(f"hn n_{pin} 0 v_{pin} 1")
        target = f"v(n_{pin})"
    d += [".control", "set numdgt=15", "set wr_singlescale", "set wr_vecnames", "set appendwrite"]
    for T in t.temps:
        for lp, lv in t.bias_list():
            for sp, sv in t.sweep_list():
                d.append(f"set temp={fmt(T)}")
                if lp:
                    d.append(f"alter v_{lp} dc = {fmt(lv)}")
                if sp:
                    d.append(f"alter v_{sp} dc = {fmt(sv)}")
                d.append(f"noise {target} vin {t.freq}")
                # A sweep leaves the spectrum plot then the integrated one;
                # a single frequency leaves only the spectrum, and `previous`
                # would be the last bias point's.
                if not t.single_freq():
                    d.append("setplot previous")
                d.append(f"wrdata {out} onoise_spectrum")
    return d + [".endc", ".end"]


def parse_noise(t, out):
    xs = [v for _ in t.temps for _ in t.bias_list() for (_, v) in t.sweep_list()]
    raw = read_wrdata(out)
    per = len(raw) // max(len(xs), 1)
    return [[xs[k // per] if t.single_freq() and per else r[0], r[1] ** 2] for k, r in enumerate(raw)]


def deck_tran(osdi, model, args, t, out):
    tstep, tstop, stim = t.tran
    pin, wave = re.match(r"V\((\w+)\)=(.*)", stim).groups()
    d = header(osdi, model, args, t)
    for p in t.pins:
        s = source(p, t, t.bias.get(p, 0.0))
        d.append(s + (f" {wave}" if p == pin else ""))
    d += [instance(t), ".control", "set numdgt=15", "set wr_singlescale", "set wr_vecnames", "set appendwrite"]
    vecs = " ".join(f"i(v_{p})" for p in t.outputs)
    for T in t.temps:
        d += [f"set temp={fmt(T)}", f"tran {tstep} {tstop} 0 {tstep}", f"linearize {vecs}", f"wrdata {out} {vecs}"]
    return d + [".endc", ".end"]


def parse_tran(t, out):
    return [[r[0]] + [-v for v in r[1:]] for r in read_wrdata(out)]


DECKS = {"dc": (deck_dc, parse_dc), "ac": (deck_ac, parse_ac), "noise": (deck_noise, parse_noise), "tran": (deck_tran, parse_tran)}


def out_names(t):
    if t.kind == "ac":
        return [f"{typ}({m},{f})" for (typ, m, f) in t.outputs]
    if t.kind == "noise":
        return [f"N({t.outputs[0]})"]
    return [f"V({p})" if p in t.float else f"I({p})" for p in t.outputs]


def simulate(osdi, model, args, t, work):
    """Runs test `t` on `osdi`; (rows, error)."""
    if t.kind == "noise" and len(t.outputs) > 1:
        return None, "cross-noise outputs N(a,b) are not run (one-pin noise only)"
    if t.kind == "dc" and not t.sweep:
        return None, "a DC test with no biasSweep"
    deck, parse = DECKS[t.kind]
    out = work / f"{t.name}.txt"
    out.unlink(missing_ok=True)
    log, ok = ngspice("\n".join(deck(osdi, model, args, t, out)) + "\n", work)
    rows = parse(t, out)
    if not ok or not rows:
        why = re.findall(r"(?m)^(?:Error|.*[Tt]imestep too small|.*no convergence|.*singular).*$", log)
        return None, "ngspice: " + (why[0] if why else "no output")[:200]
    return rows, None


def run_qaspec(prefix, spec, model, defined, sims, refdir=None, skip=(), src=None):
    """Every test of `spec`: against `refdir/<test>.standard` when given, else
    `sims[0]` against `sims[1]` (each an (osdi, label) pair). `src` is the
    checkout a `$SRC/` parameter file names."""
    setup_lines, tests = read_qaspec(spec, defined)
    setup = Setup(setup_lines)
    _param_files["dir"] = str(Path(spec).parent)
    _param_files["src"] = str(src or Path(spec).parent)
    # Tests are built here, in order: a parameter file is read through
    # _param_files. Only the simulator runs go to the pool.
    ts = [Test(name, lines, setup) for name, lines in tests.items() if name not in skip]

    def sim(t):
        with tempfile.TemporaryDirectory(prefix="vera-qa-") as tmp:
            got = []
            for osdi, label in sims:
                rows, err = simulate(osdi, model, setup.ntype, t, Path(tmp))
                if err:
                    return f"{label}: {err}", got
                got.append(rows)
            return None, got

    for t, (err, got) in zip(ts, pmap(sim, ts)):
        cols = out_names(t)
        if err:
            for c in cols:
                record(f"{prefix}/{t.name}/{c}", False, err)
        elif refdir is not None:
            ref = read_reference(Path(refdir) / f"{t.name}.standard")
            compare_cols(f"{prefix}/{t.name}", cols, ref, got[0], t.kind)
        else:
            compare_cols(f"{prefix}/{t.name}", cols, got[1], got[0], t.kind)


# ---------------------------------------------------------------------------
# the suites
# ---------------------------------------------------------------------------


def suite_osdi(ctx):
    """Hand-derived decks: each `<name>.sp` beside `<name>.va` carries
    `*! expect <vector> <value> <reltol>` lines, checked against ngspice's
    `print` of that vector with `{osdi}` replaced by VerA's library, and
    `{osdi_v}` by its library of a `<name>.v` beside it."""
    d = OSDI
    with tempfile.TemporaryDirectory(prefix="vera-osdi-") as tmp:
        for sp in sorted(d.glob("*.sp")):
            name = f"osdi/{sp.stem}"
            osdi, err = ctx.cc.osdi("vera", sp.with_suffix(".va"))
            text = sp.read_text()
            if not err and sp.with_suffix(".v").exists():
                osdi_v, err = ctx.cc.osdi("vera", sp.with_suffix(".v"))
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


def models_of(suite):
    """`model <name> <path.va> <qaSpec> [<module>]` lines of a MANIFEST."""
    out = []
    for line in (EXT / suite / "MANIFEST").read_text().splitlines():
        if line.startswith("model "):
            out.append(line.split()[1:])
    return out


def suite_va_models(ctx):
    """VerA against openvaf-r on our own qaSpec per model (tests/conformance/vera/
    external/va-models/<model>.qa), over the fetched Verilog-A."""
    src = fetch_git(ctx.cache, "va-models")
    for name, va, spec, *mod in models_of("va-models"):
        if ctx.only and name not in ctx.only:
            continue
        va = src / va
        sims = []
        for tool in ("vera", "openvaf"):
            osdi, err = ctx.cc.osdi(tool, va)
            if err:
                record(f"va-models/{name}/compile/{tool}", False, err)
                break
            record(f"va-models/{name}/compile/{tool}", True)
            sims.append((osdi, tool))
        else:
            run_qaspec(f"va-models/{name}", EXT / "va-models" / spec, mod[0] if mod else name, ["ngspice"], sims, src=src)


def suite_cmcqa(ctx):
    """ominux/cmcqa's qaSpec and `.standard` references, VerA's library run
    in ngspice. The model's own Verilog-A comes from the same release folder."""
    src = fetch_git(ctx.cache, "cmcqa")
    for name, folder, va, module, defines, *skip in models_of("cmcqa"):
        if ctx.only and name not in ctx.only:
            continue
        base = src / "model_qa" / folder
        osdi, err = ctx.cc.osdi("vera", base / va)
        record(f"cmcqa/{name}/compile/vera", err is None, err or "")
        if err:
            continue
        run_qaspec(f"cmcqa/{name}", base / "qaSpec", module, defines.split(","), [(osdi, "vera")], refdir=base / "reference", skip=skip)


def suite_hicum_qa(ctx):
    """TU Dresden's HICUM/L2 QA: the setup zip's qaSpec and parameter files,
    the results zip's `.standard` references, and the same version's
    Verilog-A from the va-models checkout, VerA's library run in ngspice."""
    m = manifest("hicum-qa")
    lines = [line.split() for line in (EXT / "hicum-qa" / "MANIFEST").read_text().splitlines()]
    zips = {}
    try:
        for kind, name, sha in [x for x in lines if x and x[0] in ("setup", "results")]:
            zips[kind] = fetch_zip(ctx.cache, "hicum-qa", m["url"].rstrip("/") + "/" + name, sha)
    except Exception as e:  # noqa: BLE001 - a fetch failure is a FAIL line, not a crash
        record("hicum-qa/fetch", False, str(e)[:200])
        return
    src = fetch_git(ctx.cache, "va-models")
    for name, va, module in [x[1:] for x in lines if x and x[0] == "model"]:
        if ctx.only and name not in ctx.only:
            continue
        osdi, err = ctx.cc.osdi("vera", src / va)
        record(f"hicum-qa/{name}/compile/vera", err is None, err or "")
        if err:
            continue
        run_qaspec(f"hicum-qa/{name}", zips["setup"] / "qaSpec", module, ["spectre", "ngspice"], [(osdi, "vera")], refdir=zips["results"])


XYCE_TYPE = {"d": "D", "q": "NPN", "m": "NMOS"}


def xyce_dc(t, letter, level, xpins, run_dir):
    """Test `t`'s DC sweep in Xyce on its built-in `letter` model at `level`,
    one run per (temperature, bias-list value), rows as `parse_dc`'s."""
    sp, a, b, st = t.sweep
    rows = []
    for T in t.temps:
        for lp, lv in t.bias_list():
            bias = dict(t.bias, **({lp: lv} if lp else {}))
            out = run_dir / "xyce.prn"
            out.unlink(missing_ok=True)
            d = [f"* {t.name}", f".options device temp={fmt(T)}", ".options nonlin reltol=1e-9 abstol=1e-18",
                 f".model mymodel {XYCE_TYPE[letter]} level={level} " + " ".join(t.model)]
            for p in xpins:
                d.append(f"i_{p} {p} 0 0" if p in t.float else f"v_{p} {p} 0 dc {fmt(bias.get(p, 0.0))}")
            d.append(f"{letter}1 " + " ".join(xpins) + " mymodel " + " ".join(t.inst))
            d.append(f".dc v_{sp} {fmt(a)} {fmt(b)} {fmt(st)}")
            vecs = " ".join(f"v({p})" if p in t.float else f"i(v_{p})" for p in t.outputs)
            d += [f".print dc format=noindex file={out} v({sp}) {vecs}", ".end"]
            (run_dir / "deck.cir").write_text("\n".join(d) + "\n")
            try:
                r = run(["Xyce", str(run_dir / "deck.cir")], cwd=run_dir, timeout=SIM_TIMEOUT)
            except subprocess.TimeoutExpired:
                return None, f"Xyce: timeout after {SIM_TIMEOUT:g} s"
            got = read_wrdata(out)
            if r.returncode != 0 or not got:
                why = [line for line in (r.stdout + r.stderr).splitlines() if "error" in line.lower()]
                return None, "Xyce: " + (why[0] if why else f"exit {r.returncode}")[:200]
            rows += [[x[0]] + [x[1 + j] if p in t.float else -x[1 + j] for j, p in enumerate(t.outputs)] for x in got]
    return rows, None


def suite_xyce(ctx):
    """VerA in ngspice against Xyce's built-in model of the same version: the
    DC tests of each model's va-models qaSpec, run on both and compared with
    the CMC rule. A third opinion beside openvaf-r."""
    src = fetch_git(ctx.cache, "va-models")
    va_models = {m[0]: m for m in models_of("va-models")}
    for name, letter, level, xpins in models_of("xyce"):
        if ctx.only and name not in ctx.only:
            continue
        _, va, spec, module = va_models[name]
        osdi, err = ctx.cc.osdi("vera", src / va)
        record(f"xyce/{name}/compile/vera", err is None, err or "")
        if err:
            continue
        spec = EXT / "va-models" / spec
        setup_lines, tests = read_qaspec(spec, {"ngspice": True})
        setup = Setup(setup_lines)
        _param_files["dir"], _param_files["src"] = str(spec.parent), str(src)
        ts = [t for t in (Test(tname, lines, setup) for tname, lines in tests.items()) if t.kind == "dc"]

        def both(t):
            with tempfile.TemporaryDirectory(prefix="vera-xyce-") as tmp:
                got, err = simulate(osdi, module, setup.ntype, t, Path(tmp))
                ref, xerr = (None, None) if err else xyce_dc(t, letter, level, xpins.split(","), Path(tmp))
                return got, ref, err and f"vera: {err}" or xerr

        for t, (got, ref, err) in zip(ts, pmap(both, ts)):
            cols = out_names(t)
            if err:
                for c in cols:
                    record(f"xyce/{name}/{t.name}/{c}", False, err)
            else:
                compare_cols(f"xyce/{name}/{t.name}", cols, ref, got, "dc")


def suite_selftest(_ctx):
    """The harness's own logic against hand-worked cases: no simulator runs."""
    m = cmc_match
    assert m(1.0, 1.0, 1e-13, 6, 1e-6)[0]
    assert m(1e-14, 5.0, 1e-13, 6, 1e-6)[0]  # under the clip
    assert m(1.00000099, 1.0, 1e-13, 6, 1e-6)[0]  # 6 digits, 10 units of the 7th
    assert not m(1.00002, 1.0, 1e-13, 6, 1e-6)[0]
    assert not m(-1e-3, 1e-3, 1e-13, 6, 1e-6)[0]  # opposite signs
    assert not m(math.nan, 1.0, 1e-13, 6, 1e-6)[0]
    assert [Printed(x).digits for x in ("0.0011276", "-8.1141e-06", "1000000", "0", "8.89243071283542e-14")] == [5, 5, 7, 1, 15]
    assert m(Printed("0.0011276"), 0.00112763923, 1e-13, Printed("0.0011276").digits, 1e-6)[0]  # rounding of a 5-digit print
    assert not m(Printed("0.0011276"), 0.0011278, 1e-13, 5, 1e-6)[0]  # 2 units of its 5th digit
    assert drange(0, 1, 0.25) == [0, 0.25, 0.5, 0.75, 1.0]
    assert drange(1, -0.7, -0.5) == [1, 0.5, 0.0, -0.5]
    assert ifdefs(["`ifdef a", "x", "`else", "y", "`end", "`ifdef b", "z", "`endif"], {"a": True}) == ["x"]
    rows = {"va-models/bsim4/*": "upstream", "osdi/diode/n1k": "reading", "osdi/gone": "fixed"}
    assert judge(["va-models/bsim4/dc/I(d)", "osdi/diode/n1k", "osdi/r/va"], rows) == (
        [("va-models/bsim4/dc/I(d)", "va-models/bsim4/*"), ("osdi/diode/n1k", "osdi/diode/n1k")], ["osdi/r/va"], ["osdi/gone"])
    with tempfile.TemporaryDirectory() as tmp:
        f = Path(tmp, "card")
        f.write_text("* c\n.model n1 nmos type=1\n+ c10 = ( 9.074e-030 ) vth0= 0.4 $ note\n.model n2 nmos type=-1\n")
        _param_files["dir"] = tmp
        assert setup_param_file("card#n1") == ["type=1", "c10=9.074e-030", "vth0=0.4"]
        assert setup_param_file("card#n2") == ["type=-1"]
    record("selftest", True)


class Ctx:
    pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("suites", nargs="*", default=SUITES)
    ap.add_argument("--vera", default=str(ROOT / "zig-out" / "bin" / "vera"))
    ap.add_argument("--out", default=str(ROOT / ".zig-cache" / "external-out"))
    ap.add_argument("--only", action="append", default=[], help="run only this model (repeatable)")
    a = ap.parse_args()
    ctx = Ctx()
    ctx.cache = Path(os.environ.get("VERA_EXTERNAL_CACHE", ROOT / ".zig-cache" / "external")).resolve()
    ctx.cc = Compiler(a.vera, ctx.cache)
    ctx.only = set(a.only)
    fns = {"selftest": suite_selftest, "osdi": suite_osdi, "va-models": suite_va_models, "cmcqa": suite_cmcqa, "hicum-qa": suite_hicum_qa, "xyce": suite_xyce}
    for s in a.suites:
        if s != "selftest" and not shutil.which("ngspice"):
            record(f"{s}/harness", False, "ngspice not on PATH: run in `nix develop .#external`")
            continue
        try:
            fns[s](ctx)
        except Exception as e:  # noqa: BLE001 - one suite's crash is a FAIL line, the rest still run
            record(f"{s}/harness", False, f"{type(e).__name__}: {e}"[:300])
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    fails = sorted(n for n, ok, _ in results if not ok)
    (out / "fail.txt").write_text("".join(n + "\n" for n in fails))
    untriaged = stale = 0
    for s in a.suites:
        mine = [n for n in fails if n.split("/", 1)[0] == s]
        known, new, gone = judge(mine, triage(s))
        for n, pat in known:
            print(f"KNOWN {n} [{pat}: {triage(s)[pat]}]")
        untriaged += len(new)
        if not ctx.only:  # a partial run cannot show a row is stale
            for p in gone:
                print(f"STALE {s}/TRIAGE.md `{p}`: names no FAIL; delete the row")
            stale += len(gone)
    print(f"external-analog: {len(results) - len(fails)} PASS, {len(fails)} FAIL, {untriaged} untriaged, {stale} STALE ({out / 'fail.txt'})")
    return 1 if untriaged or stale else 0


if __name__ == "__main__":
    sys.exit(main())
