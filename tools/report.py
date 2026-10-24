#!/usr/bin/env python3
"""The conformance and speed report: one self-contained page, every number measured.

    tools/report.py                              # run what is missing, write report/
    tools/report.py --logs DIR                   # reuse DIR/<name>.txt logs where present
    tools/report.py --models ../ARPice/models    # also time the model corpus
    tools/report.py --selftest                   # check the log parsers

Writes `report/index.html` (inline SVG, no external script) and
`report/data.json`. Each suite log is read from `--logs DIR` when the file is
there (CI has already run the suites and kept them) and otherwise produced by
running its command and saving it into DIR, so a second run re-renders without
re-measuring. The logs and the commands:

    strict.txt       zig build suite -- --strict     (stdout and stderr, merged)
    coverage1364.txt zig build suite -- ieee1364 --coverage
    devices.txt      zig build suite -- devices
    vpi.txt          zig build suite -- vpi
    sweep.txt        zig build suite -- --sweep
    models.json      `vera --emit-so` per model, this script (--models)

Everything is built ReleaseFast: the suite's timing table says Debug is "NOT
the shipping number". The page states what it read, never a typed number.
The parsing of the measures lines is conformance.py's.
"""
import argparse
import datetime
import html
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import conformance as C  # noqa: E402

ROOT = C.ROOT
OPT = "-Doptimize=ReleaseFast"
SUITES = {
    "strict": ["zig", "build", OPT, "suite", "--", "--strict"],
    "coverage1364": ["zig", "build", OPT, "suite", "--", "ieee1364", "--coverage"],
    "devices": ["zig", "build", OPT, "suite", "--", "devices"],
    "vpi": ["zig", "build", OPT, "suite", "--", "vpi"],
    "sweep": ["zig", "build", OPT, "suite", "--", "--sweep"],
}
MODELS = ["diode", "mos1", "bsim4va", "psp103", "psp103_nqs", "vbic13_4t"]
# The `--dyn` host the model timing builds under. NOT a no-op one (`NOOP_DYN`):
# that exports nothing, so Zig never analyses the device and the .so is a
# ~1 KB stub (measured: every model, 1312-1320 bytes). This one exports one
# `evalQ` over the sparse reference family (the SIMD lanes a host runs; the
# dense one failed to build psp103_nqs on 2026-10-04) with every operand from the
# caller, so the device's eval and charge code is compiled. A real host
# (ARPice's vtable) also compiles updateState and the rest: a lower bound.
DYN = """//! The `--dyn` host for checking a Verilog-A device really compiles.
//! In: a VerA device type D. Out: one exported C symbol, `bench_evalq`, that
//! runs `D.evalQ` over the sparse reference family with every operand taken
//! from the caller, so nothing folds and the device's eval and charge code is
//! compiled. A no-op dyn exports nothing and Zig never analyses the device
//! (measured 2026-10-04: every model's .so was 1312-1320 bytes).
//! A real host (ARPice's vtable) also compiles updateState: a lower bound.
//! Used by tools/report.py's model-build timing.

/// Opt into the contract's conformance checks.
pub const vera_validate_contract = true;

const contract = @import("contract");

/// The `--dyn` hook (`src/zigbuild/orchestrator.zig`): exports `bench_evalq`
/// for `D`. `name` is unused: one device per `.so`, under a fixed symbol.
pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    _ = name;
    @export(&Bench(D).evalQ, .{ .name = "bench_evalq" });
}

fn Bench(comptime D: type) type {
    return struct {
        const n = contract.nU(D);
        const S = contract.RefFamily(f64, &lanes, .{});
        const lanes = blk: {
            var a: [n]u8 = undefined;
            for (&a, 0..) |*l, i| l.* = i;
            break :blk a;
        };
        // Every operand comes from the caller, so nothing folds: the whole
        // device is compiled, as a host's Newton loop would compile it.
        fn evalQ(x: *const [n]f64, m: *const D.Model, inst: *D.Instance, sim: *const contract.SimState, out: *anyopaque) callconv(.c) void {
            const r = D.evalQ(S, x, m, inst, sim.*);
            @as(*@TypeOf(r), @ptrCast(@alignCast(out))).* = r;
        }
    };
}
"""
# A no-op `dyn`: exports nothing, so no device code compiles.
NOOP_DYN = "pub fn exportDevice(comptime D: type, comptime name: []const u8) void {\n    _ = D;\n    _ = name;\n}\n"
BUILD_TIMEOUT_S = 1800
KINDS = ["non-normative", "no-prohibition", "optional", "implementation-defined",
         "resource-limit", "unspecified", "not-supported"]


def log(logs, name):
    """DIR/name.txt, running its command first when it is not there. The exit
    status is kept on the log's last line, as CI's `strict exit: N` is."""
    path = logs / f"{name}.txt"
    if not path.exists():
        cmd = SUITES[name] if name != "strict" else suite_binary()
        print(f"report.py: running {' '.join(cmd)}", file=sys.stderr)
        p = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        path.write_bytes(p.stdout + f"\nstrict exit: {p.returncode}\n".encode())
    return path.read_text(errors="replace")


def suite_binary():
    """`benchmark --strict` as the suite binary itself: the build runner
    truncates a failed step's output, and --strict
    fails while any XFAIL remains. A filter that matches nothing makes the
    step fail fast and print the command it ran."""
    p = subprocess.run(SUITES["strict"] + ["zzz-none"], cwd=ROOT, capture_output=True, text=True)
    line = next(l for l in (p.stdout + p.stderr).split("\n") if l.startswith("failed command: "))
    suite, vera = line.split()[2:4]
    return [suite, vera, "--strict"]


def tsv(text, header):
    """The rows under the TSV line `header`, up to the first blank line."""
    lines = text.split("\n")
    try:
        i = lines.index(header)
    except ValueError:
        return []
    cols = header.split("\t")
    rows = []
    for line in lines[i + 1:]:
        cells = line.split("\t")
        if len(cells) != len(cols):
            break
        rows.append(dict(zip(cols, cells)))
    return rows


def top(clause):
    return clause.split(".")[0]


# ---------------------------------------------------------------------------
# Fixtures: what each one declares
# ---------------------------------------------------------------------------

def fixture_tags(rel):
    """(reject substrings, xfail reason or None) from a fixture's `//!` lines."""
    try:
        source = (ROOT / rel).read_text(errors="replace")
    except OSError:
        return [], None
    rejects = re.findall(r"(?m)^\s*//! reject\b[ \t]*(.*)$", source)
    xf = re.search(r"(?m)^\s*//! xfail\b[ \t]*(.*)$", source)
    if not rejects and re.search(r"(?m)^\s*// digital-runner: reject\s*$", source):
        rejects = ["(digital-runner: reject)"]
    return [r.strip() or "(any diagnostic)" for r in rejects], (xf.group(1).strip() if xf else None)


def classifications():
    """{(std, clause): (kind, evidence)} from every CLAUSES.tsv: the kind of a
    clause that states no rule an input can break, and the quote that justifies it."""
    out = {}
    for path in sorted(C.CLAUSES_DIR.rglob("CLAUSES.tsv")):
        ieee = "ieee1364" in path.parts
        for line in path.read_text().split("\n"):
            if not line.strip() or line.startswith("#"):
                continue
            cells = line.split("\t")
            if len(cells) > 1 and cells[1] != "-":
                evidence = cells[3] if ieee and len(cells) > 3 else (cells[2] if not ieee and len(cells) > 2 else "")
                out[("ieee" if ieee else "ams", cells[0].strip())] = (cells[1].strip(), evidence.strip())
    return out


def ieee_titles():
    out = {}
    for line in (ROOT / "tests/conformance/vera/clauses/ieee1364/CLAUSES.tsv").read_text().split("\n"):
        cells = line.split("\t")
        if line.startswith("#") or len(cells) < 3:
            continue
        out[cells[0].strip()] = cells[2].strip()
    return out


# ---------------------------------------------------------------------------
# Coverage logs -> one row per clause
# ---------------------------------------------------------------------------

BUCKETS = {"POSITIVE CITATIONS ONLY": "positive-only", "REJECTION CITATIONS ONLY": "rejection-only",
           "UNCITED": "uncited", "CLASSIFIED": "classified"}
ROW = re.compile(r"^§(\S+) (.*?)(?:  \[([\w-]+)\])?(?:  \((.+?)\))?(?:  ~ .*)?$")


def buckets(text):
    """{clause: (bucket, title)} from the one-way, uncited and classified lists
    the coverage reports print (tests/suite.zig's Coverage and Ieee1364)."""
    out, current = {}, None
    for line in text.split("\n"):
        head = next((b for h, b in BUCKETS.items() if line.startswith(h + " ")), None)
        if head:
            current = head
        elif not line.strip():
            current = None
        elif current and line.startswith("§"):
            m = ROW.match(line)
            if m:
                out[m.group(1)] = (current, m.group(2))
    return out


def clause_rows(cov1364):
    kinds = classifications()
    rows = []

    def entry(std, cid, bucket, title, pos, neg):
        kind, why = kinds.get((std, cid), (None, ""))
        negs = []
        for p in sorted(set(neg)):
            codes, _ = fixture_tags(p)
            negs.append({"path": p, "reject": codes})
        xf = []
        for p in sorted(set(pos) | set(neg)):
            _, reason = fixture_tags(p)
            if reason is not None:
                xf.append({"path": p, "reason": reason})
        rows.append({"std": std, "id": cid, "chapter": top(cid), "title": title,
                     "status": bucket, "kind": kind if bucket == "classified" else None,
                     "reason": why if bucket == "classified" else "",
                     "positive": sorted(set(pos)), "rejection": negs, "xfail": xf})

    cites = C.fixture_cites()
    bk = buckets(cov1364)
    for cid, title in sorted(ieee_titles().items(), key=lambda kv: C.sort_key(kv[0])):
        # tests/suite.zig's Ieee1364 counts verilog/*.v and the `.c` VPI runs only.
        c = cites.get(("ieee", cid), {"pos": [], "neg": []})
        keep = [p for p in c["pos"] if "/tests/verilog/" in p or p.endswith(".c")]
        keepn = [p for p in c["neg"] if "/tests/verilog/" in p or p.endswith(".c")]
        bucket, _ = bk.get(cid, ("both", title))
        entry("ieee", cid, bucket, title, keep, keepn)
    return rows


def chapter_table(rows, std):
    out = {}
    for r in rows:
        if r["std"] != std:
            continue
        ch = out.setdefault(r["chapter"], {"chapter": r["chapter"], "both": 0, "classified": 0,
                                           "one-way": 0, "uncited": 0, "xfail": 0,
                                           "kinds": {k: 0 for k in KINDS}})
        key = {"positive-only": "one-way", "rejection-only": "one-way"}.get(r["status"], r["status"])
        ch[key] += 1
        if r["kind"]:
            ch["kinds"][r["kind"].replace("_", "-")] = ch["kinds"].get(r["kind"].replace("_", "-"), 0) + 1
        ch["xfail"] += bool(r["xfail"])
    return sorted(out.values(), key=lambda c: C.sort_key(c["chapter"]))


# ---------------------------------------------------------------------------
# Gaps: what the documents say is open
# ---------------------------------------------------------------------------

def open_defects():
    """The named open defects (a paragraph opening with a bold name) of the
    "Open defects" section of docs/specification/Vague_Decisions.md. Unnamed
    paragraphs there record what is gone."""
    out = []
    for name in ("docs/specification/Vague_Decisions.md",):
        path = ROOT / name
        if not path.exists():
            continue
        m = re.search(r"(?ms)^##+ (?:[\w.]+ )?Open defects\s*$(.*?)(?=^## |\Z)", path.read_text())
        if not m:
            continue
        for para in re.split(r"\n\s*\n", m.group(1)):
            para = " ".join(para.split())
            t = re.match(r"\*\*(.+?)\*\*\s*(.*)", para)
            if t:
                out.append({"source": name, "title": t.group(1).rstrip("."), "text": t.group(2)})
    return out


def vpi_xfails():
    """`.c` fixtures build.zig runs (`//! design`) carrying `//! xfail`: a known gap that must exit 1 saying so."""
    root = ROOT / "tests/conformance/tests"
    out = []
    for path in sorted(root.rglob("*.c")):
        text = path.read_text(errors="replace")
        m = re.search(r"(?m)^//! xfail (.*)$", text)
        if m and re.search(r"(?m)^//! design ", text):
            out.append({"path": str(path.relative_to(ROOT).as_posix()), "reason": m.group(1)})
    return out


def vague_open():
    """docs/specification/Vague_Decisions.md entries that say CHANGE NEEDED and are not DONE."""
    path = ROOT / "docs/specification/Vague_Decisions.md"
    if not path.exists():
        return []
    out = []
    for block in re.split(r"(?m)^### ", path.read_text())[1:]:
        title, _, body = block.partition("\n")
        if "CHANGE NEEDED" not in body or re.search(r"\bDONE\b", title + body):
            continue
        change = body[body.index("CHANGE NEEDED"):].split("\n")[0]
        out.append({"id": title.split(":")[0].strip(), "title": title.partition(":")[2].strip(),
                    "change": change.removeprefix("CHANGE NEEDED:").strip()})
    return out


# ---------------------------------------------------------------------------
# Speed
# ---------------------------------------------------------------------------

def quantile(sorted_vals, p):
    """suite.zig's `pct`: the element at index n*p/100."""
    return sorted_vals[min(len(sorted_vals) * p // 100, len(sorted_vals) - 1)]


def speed(strict, sweep):
    rows = tsv(strict, "fixture\tdemands\tvera_ns\tvera_out\tvera_ok")
    fx = [{"path": r["fixture"], "demands": r["demands"], "ns": int(r["vera_ns"]),
           "ok": r["vera_ok"] == "1"} for r in rows if C.is_num(r["vera_ns"])]
    chapters = {}
    for f in fx:
        chapters.setdefault(f["path"].split("/")[0], []).append(f["ns"])
    per_ch = [{"chapter": k, "n": len(v), "total_ns": sum(v), "p50_ns": quantile(sorted(v), 50),
               "p90_ns": quantile(sorted(v), 90)} for k, v in sorted(chapters.items())]
    header = re.search(r"^# VerA benchmark — (.*)$", strict, re.M)
    return {
        "header": header.group(1) if header else "",
        "summary": tsv(strict, "scope\tcompiler\tn\ttotal_ns\tp50_ns\tp90_ns\tp99_ns\tmax_ns"),
        "fixtures": fx,
        "per_chapter": per_ch,
        "footprint": tsv(sweep, "case\tn\tinsts\tdefs\tblocks\textra\tmir_bytes"),
        "phases": tsv(sweep, "mode\tcase\tn\tphase\tmin_ns\tbytes"),
    }


def time_models(models, reps, scratch):
    """Device build time per model: `vera --emit-so`, the arpice-models job's
    command under `DYN`. Cold means cold for the device and only the device:

    - Zig's GLOBAL cache keeps whole compilations keyed by their inputs, so a
      second build of the same device with a fresh local cache is a hit
      (measured: mos1 6.6 s, then 0.26 s). Each run therefore gets its own
      copy of a base global cache.
    - The base holds what every first build on a machine pays once
      (compiler_rt and friends): it is primed by building one model under
      a no-op `dyn` (`NOOP_DYN`), which compiles no device code. That priming,
      timed from an empty global cache, is reported as the one-time cost.
    - The work dir and vera's cwd (whose `.zig-cache` the spawned builds use)
      are fresh per run.

    Median of `reps`. The front end alone (`--emit-zig`) is timed too, so the
    split between VerA and the Zig compile of its output is visible."""
    vera = ROOT / "zig-out/bin/vera"
    contract = ROOT / "lib/contract.zig"
    dyn, noop = scratch / "dyn.zig", scratch / "noop.zig"
    dyn.write_text(DYN)
    noop.write_text(NOOP_DYN)
    base = scratch / "base-global"
    env = dict(os.environ)
    env.pop("ZIG_LOCAL_CACHE_DIR", None)

    def so(model, host, global_cache):
        cwd = Path(tempfile.mkdtemp(dir=scratch))
        if global_cache is None:
            global_cache = cwd / "global"
            shutil.copytree(base, global_cache, symlinks=True)
        t = time.perf_counter()
        try:
            p = subprocess.run([str(vera), "--emit-so", "--contract", str(contract), "--dyn", str(host),
                                "-I", str(models), "--work-dir", "out", str(models / f"{model}.va")],
                               cwd=cwd, env=dict(env, ZIG_GLOBAL_CACHE_DIR=str(global_cache)),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=BUILD_TIMEOUT_S)
            rc, out, err = p.returncode, p.stdout.decode().strip(), p.stderr.decode(errors="replace")
        except subprocess.TimeoutExpired:
            rc, out, err = "timeout", "", f"killed after {BUILD_TIMEOUT_S} s"
        dt = time.perf_counter() - t
        size = (cwd / out).stat().st_size if rc == 0 and out and (cwd / out).exists() else None
        shutil.rmtree(cwd, ignore_errors=True)
        # The diagnostics' tail, minus the W0650 speed notes every model prints.
        tail = "\n".join(l for l in err.split("\n") if "error" in l.lower())[-1500:] if rc != 0 else ""
        return dt, rc, size, tail

    def front(model):
        t = time.perf_counter()
        p = subprocess.run([str(vera), "--emit-zig", "-I", str(models), "-o", os.devnull,
                            str(models / f"{model}.va")], cwd=scratch, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        return time.perf_counter() - t, p.returncode

    first = so(MODELS[0], noop, base)
    out = {"reps": reps, "first_build_s": first[0], "first_build_model": MODELS[0], "models": [],
           "load_before": os.getloadavg()[0], "cpus": os.cpu_count()}
    for m in MODELS:
        if not (models / f"{m}.va").exists():
            out["models"].append({"model": m, "exit": "missing", "so_runs_s": []})
            continue
        print(f"report.py: timing {m}", file=sys.stderr)
        builds = [so(m, dyn, None) for _ in range(reps)]
        fronts = [front(m) for _ in range(reps)]
        ok = all(b[1] == 0 for b in builds)
        out["models"].append({
            "model": m, "exit": builds[-1][1] if not ok else 0, "error": next((b[3] for b in builds if b[3]), ""),
            "so_s": statistics.median(b[0] for b in builds) if ok else None, "so_runs_s": [b[0] for b in builds],
            "frontend_s": statistics.median(f[0] for f in fronts), "frontend_exit": max(f[1] for f in fronts),
            "so_bytes": builds[-1][2], "source_bytes": (models / f"{m}.va").stat().st_size,
        })
    out["load_after"] = os.getloadavg()[0]
    return out


# ---------------------------------------------------------------------------
# SVG
# ---------------------------------------------------------------------------

E = html.escape
SERIES = [f"var(--s{i})" for i in range(1, 9)]


def fmt_ns(ns):
    for unit, d in (("s", 1e9), ("ms", 1e6), ("µs", 1e3)):
        if ns >= d:
            return f"{ns / d:.3g} {unit}"
    return f"{ns:.0f} ns"


def legend(names, colors):
    return '<div class="legend">' + "".join(
        f'<span><i style="background:{c}"></i>{E(n)}</span>' for n, c in zip(names, colors)) + "</div>"


def hstack(rows, label, keys, names, colors, note=lambda r: ""):
    """Horizontal stacked bars, one per row, scaled to the largest total."""
    bar_h, gap, lw, w = 16, 6, 46, 640
    peak = max((sum(r[k] for k in keys) for r in rows), default=1) or 1
    h = len(rows) * (bar_h + gap) + 4
    out = [f'<svg viewBox="0 0 {w} {h}" class="chart" role="img">']
    for i, r in enumerate(rows):
        y = i * (bar_h + gap)
        out.append(f'<text x="{lw - 6}" y="{y + 12}" class="lab" text-anchor="end">{E(r[label])}</text>')
        x = lw
        for k, n, c in zip(keys, names, colors):
            v = r[k]
            if not v:
                continue
            bw = (w - lw - 70) * v / peak
            out.append(f'<rect x="{x:.1f}" y="{y}" width="{max(bw - 2, 1):.1f}" height="{bar_h}" rx="2" '
                       f'fill="{c}"><title>{E(r[label])} · {E(n)}: {v}</title></rect>')
            x += bw
        out.append(f'<text x="{x + 4:.1f}" y="{y + 12}" class="val">{sum(r[k] for k in keys)}{E(note(r))}</text>')
    out.append("</svg>")
    return "".join(out)


def histogram(values_ns):
    """Log-binned compile-time histogram, quarter-decade bins."""
    if not values_ns:
        return "<p>No timing rows.</p>"
    lo = math.floor(math.log10(min(values_ns)) * 4)
    hi = math.floor(math.log10(max(values_ns)) * 4)
    counts = [0] * (hi - lo + 1)
    for v in values_ns:
        counts[math.floor(math.log10(v) * 4) - lo] += 1
    w, h, pad = 640, 200, 30
    bw = (w - pad) / len(counts)
    peak = max(counts)
    out = [f'<svg viewBox="0 0 {w} {h + 34}" class="chart" role="img">']
    for i, c in enumerate(counts):
        bh = (h - 10) * c / peak
        a, b = 10 ** ((lo + i) / 4) , 10 ** ((lo + i + 1) / 4)
        out.append(f'<rect x="{pad + i * bw + 1:.1f}" y="{h - bh:.1f}" width="{max(bw - 2, 1):.1f}" '
                   f'height="{bh:.1f}" rx="2" fill="var(--s1)"><title>{fmt_ns(a)} – {fmt_ns(b)}: {c} fixtures</title></rect>')
        if (lo + i) % 4 == 0:
            out.append(f'<text x="{pad + i * bw:.1f}" y="{h + 14}" class="lab">{fmt_ns(a)}</text>')
    out.append(f'<line x1="{pad}" x2="{w}" y1="{h}" y2="{h}" class="axis"/>')
    out.append(f'<text x="{pad}" y="{h + 30}" class="lab">compile time per fixture (log scale) · tallest bar {peak}</text>')
    out.append("</svg>")
    return "".join(out)


def hbars(rows, label, key, fmt, color="var(--s1)", extra=lambda r: ""):
    bar_h, gap, lw, w = 16, 6, 190, 680
    peak = max((r[key] for r in rows), default=1) or 1
    h = len(rows) * (bar_h + gap) + 4
    out = [f'<svg viewBox="0 0 {w} {h}" class="chart" role="img">']
    for i, r in enumerate(rows):
        y = i * (bar_h + gap)
        bw = (w - lw - 140) * r[key] / peak
        out.append(f'<text x="{lw - 6}" y="{y + 12}" class="lab" text-anchor="end">{E(r[label])}</text>')
        out.append(f'<rect x="{lw}" y="{y}" width="{max(bw, 1):.1f}" height="{bar_h}" rx="2" fill="{color}">'
                   f'<title>{E(r[label])}: {fmt(r[key])}{E(extra(r))}</title></rect>')
        out.append(f'<text x="{lw + bw + 4:.1f}" y="{y + 12}" class="val">{fmt(r[key])}{E(extra(r))}</text>')
    out.append("</svg>")
    return "".join(out)


def lines(series, xlabel, ylabel, fmt_y):
    """Log-log line chart: {name: [(x, y)]}, one hue per series in fixed order."""
    pts = [p for s in series.values() for p in s if p[0] > 0 and p[1] > 0]
    if not pts:
        return "<p>No sweep rows.</p>"
    w, h, pad, bottom = 640, 260, 60, 30
    lx = [math.log10(p[0]) for p in pts]
    ly = [math.log10(p[1]) for p in pts]
    x0, x1 = min(lx), max(lx) or 1
    y0, y1 = math.floor(min(ly)), math.ceil(max(ly))
    sx = lambda v: pad + (w - pad - 30) * (math.log10(v) - x0) / ((x1 - x0) or 1)
    sy = lambda v: h - bottom - (h - bottom - 10) * (math.log10(v) - y0) / ((y1 - y0) or 1)
    out = [f'<svg viewBox="0 0 {w} {h + 10}" class="chart" role="img">']
    for d in range(y0, y1 + 1):
        y = sy(10 ** d)
        out.append(f'<line x1="{pad}" x2="{w - 10}" y1="{y:.1f}" y2="{y:.1f}" class="grid"/>'
                   f'<text x="{pad - 4}" y="{y + 4:.1f}" class="lab" text-anchor="end">{fmt_y(10 ** d)}</text>')
    xs = sorted({p[0] for p in pts})
    for x in xs:
        out.append(f'<text x="{sx(x):.1f}" y="{h - bottom + 16}" class="lab" text-anchor="middle">{x}</text>')
    out.append(f'<text x="{(w + pad) / 2}" y="{h + 6}" class="lab" text-anchor="middle">{E(xlabel)}</text>')
    for (name, s), c in zip(series.items(), SERIES):
        s = [p for p in s if p[0] > 0 and p[1] > 0]
        d = " ".join(f"{'M' if i == 0 else 'L'}{sx(x):.1f},{sy(y):.1f}" for i, (x, y) in enumerate(s))
        out.append(f'<path d="{d}" fill="none" stroke="{c}" stroke-width="2"/>')
        for x, y in s:
            out.append(f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="4" fill="{c}" stroke="var(--bg)" stroke-width="2">'
                       f'<title>{E(name)}, n={x}: {fmt_y(y)}</title></circle>')
    out.append("</svg>")
    return "".join(out) + legend(list(series), SERIES) + f'<p class="note">y: {E(ylabel)}, log scale.</p>'


# ---------------------------------------------------------------------------
# Page
# ---------------------------------------------------------------------------

CSS = """
:root{--bg:#fcfcfb;--fg:#0b0b0b;--mut:#52514e;--line:#dcdbd6;--card:#f3f2ef;
--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--s4:#eda100;--s5:#e87ba4;--s6:#008300;--s7:#4a3aa7;--s8:#e34948;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#1a1a19;--fg:#fff;--mut:#c3c2b7;--line:#3a3a37;--card:#242422;
--s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500;--s5:#d55181;--s6:#008300;--s7:#9085e9;--s8:#e66767;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#1a1a19;--fg:#fff;--mut:#c3c2b7;--line:#3a3a37;--card:#242422;
--s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500;--s5:#d55181;--s6:#008300;--s7:#9085e9;--s8:#e66767;color-scheme:dark}
body{background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif;margin:0 auto;max-width:980px;padding:16px}
h1{font-size:1.5rem;margin:.2em 0}h2{margin-top:2em;border-bottom:1px solid var(--line)}h3{margin-bottom:.3em}
code,.mono{font-family:ui-monospace,monospace;font-size:.85em}
table{border-collapse:collapse;width:100%;font-size:.88em}td,th{border-bottom:1px solid var(--line);padding:4px 6px;text-align:left;vertical-align:top}
.wrap{overflow-x:auto}.chart{width:100%;height:auto;display:block}.chart .lab{fill:var(--mut);font-size:11px}
.chart .val{fill:var(--fg);font-size:11px}.chart .axis{stroke:var(--mut)}.chart .grid{stroke:var(--line)}
.legend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:.85em;color:var(--mut);margin:.4em 0}
.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px}
.tile{background:var(--card);border-radius:8px;padding:10px 12px}.tile b{font-size:1.4em;display:block}
.tile span{color:var(--mut);font-size:.85em}.note{color:var(--mut);font-size:.85em}
details summary{cursor:pointer}input,select{font:inherit;padding:3px 6px;background:var(--bg);color:var(--fg);border:1px solid var(--line);border-radius:4px}
.filters{display:flex;flex-wrap:wrap;gap:8px;margin:.5em 0}
.st-both{color:var(--s3)}.st-classified{color:var(--mut)}.st-uncited,.st-positive-only,.st-rejection-only{color:var(--s8)}
pre{white-space:pre-wrap;background:var(--card);padding:8px;border-radius:6px;font-size:.8em}
"""

JS = """
const q=document.getElementById('q'),fs=document.getElementById('fstd'),ft=document.getElementById('fst'),cnt=document.getElementById('cnt');
const rows=[...document.querySelectorAll('#rules tbody tr')];
function apply(){const t=q.value.toLowerCase();let n=0;for(const r of rows){const ok=(!t||r.dataset.k.includes(t))&&(!fs.value||r.dataset.std==fs.value)&&(!ft.value||r.dataset.st==ft.value);r.hidden=!ok;n+=ok}cnt.textContent=n+' of '+rows.length+' clauses'}
[q,fs,ft].forEach(e=>e.addEventListener('input',apply));apply();
"""


def tile(big, small):
    return f'<div class="tile"><b>{E(big)}</b><span>{E(small)}</span></div>'


def paths(items, fmt=lambda p: E(p)):
    return "<br>".join(fmt(p) for p in items)


def render(d):
    m, s = d["measures"], d["speed"]
    a = m["A"]
    o = [f"<!doctype html><html lang=en><head><meta charset=utf-8>"
         f"<meta name=viewport content='width=device-width,initial-scale=1'><title>VerA Conformance Report</title>"
         f"<style>{CSS}</style></head><body>"]
    meta = d["meta"]
    o.append(f"<h1>VerA conformance and speed</h1><p class=note>Commit <code>{E(meta['sha'])}</code> · "
             f"{E(meta['date'])} · Zig {E(meta['zig'])} · {E(meta['machine'])} · {E(meta['load'])}</p>")
    o.append("<p>Every number on this page was read from the logs of the commands below "
             "(<code>tools/report.py</code>; raw data in <a href=data.json>data.json</a>). "
             "B and C are static citation inventories: a cite is not a passing test."
             "</p><details><summary>Commands</summary><pre>"
             + E("\n".join(meta["commands"])) + "</pre></details>")

    o.append("<p><a href=#conf>Conformance</a> · <a href=#speed>Speed</a> · <a href=#gaps>Gaps</a> · "
             "<a href=#rules-h>Rule map</a></p>")
    # --- Conformance -------------------------------------------------------
    o.append("<h2 id=conf>Conformance</h2><div class=tiles>")
    o.append(tile(f"{a['pass']} / {a['total']}", f"A — fixtures behaving as stated · FAIL {a['fail']} · "
                  f"unasserted {a['unasserted']} · XFAIL {a['xfail']} · --strict exit {a['strict_rc']}"))
    for key, name in (("B", "IEEE 1364-2005 clauses"),):
        x = m[key]
        o.append(tile(f"{x['both']} / {x['clauses']} both ways", f"{key} — {name} · classified {x['classified']} · "
                      f"positive-only {x['pos']} · rejection-only {x['neg']} · uncited {x['unc']}"))
    o.append(tile("hand-entered", "D — ARCHITECTURE.md §6 phases; not measured by any command"))
    o.append(tile(m["devices"] or "(no summary line)", "zig build suite -- devices"))
    o.append(tile(m["vpi"] or "(no summary line)", "zig build suite -- vpi"))
    o.append("</div>")
    keys = ["both", "classified", "one-way", "uncited"]
    names = ["cited both ways", "classified (CLAUSES.tsv)", "one-way", "uncited"]
    cols = SERIES[:4]
    for std, title in (("ieee", "IEEE 1364-2005 clauses by chapter (measure B)"),):
        chs = d["chapters"][std]
        o.append(f"<h3>{title}</h3>" + legend(names, cols)
                 + hstack(chs, "chapter", keys, names, cols, lambda r: f"  · {r['xfail']} xfail" if r["xfail"] else ""))
        kinds = [k for k in KINDS if any(c["kinds"].get(k) for c in chs)]
        flat = [dict(c, **{k: c["kinds"].get(k, 0) for k in kinds}) for c in chs if any(c["kinds"].get(k) for k in kinds)]
        if flat:
            o.append(f"<details><summary>Classified clauses by kind</summary>{legend(kinds, SERIES)}"
                     f"{hstack(flat, 'chapter', kinds, kinds, SERIES)}</details>")
    o.append("<p class=note>A clause with an XFAIL fixture is counted in its bucket and marked “xfail” at the bar end.</p>")

    # --- Speed -------------------------------------------------------------
    o.append("<h2 id=speed>Speed</h2>")
    o.append(f"<p class=note>Suite timing table: {E(s['header'])}. One accept/reject compilation per fixture, "
             "source in, device text out.</p><div class=tiles>")
    for r in s["summary"]:
        for k in ("p50_ns", "p90_ns", "p99_ns", "max_ns"):
            o.append(tile(fmt_ns(int(r[k])), f"{k[:-3]} compile time, {r['n']} fixtures"))
        o.append(tile(fmt_ns(int(r["total_ns"])), "total, all fixtures"))
    o.append("</div><h3>Compile-time distribution</h3>" + histogram([f["ns"] for f in s["fixtures"]]))
    slow = sorted(s["fixtures"], key=lambda f: -f["ns"])[:10]
    o.append("<details><summary>Ten slowest fixtures</summary><table>" + "".join(
        f"<tr><td class=mono>{E(f['path'])}</td><td>{fmt_ns(f['ns'])}</td></tr>" for f in slow) + "</table></details>")
    o.append("<h3>Compile time per fixture directory (median, total in label)</h3>"
             + hbars(sorted(s["per_chapter"], key=lambda r: r["chapter"]), "chapter", "p50_ns", fmt_ns,
                     extra=lambda r: f" · Σ {fmt_ns(r['total_ns'])} · n={r['n']}"))
    # The sweep's phases are cumulative (harness/sweep.zig): `codegen` is
    # source text in, device.zig out, the whole compile. One line per axis.
    by_case = {}
    for r in s["phases"]:
        if r["phase"] == "codegen":
            by_case.setdefault(r["case"], []).append((int(r["n"]), int(r["min_ns"])))
    o.append("<h3>Size sweep: compile time (benchmark --sweep)</h3>"
             + (lines(by_case, "n (generated size along each axis)",
                      "min time to `codegen` (source → device.zig, cumulative phase)", fmt_ns)
                if by_case else "<p>No sweep data.</p>"))
    fp = {}
    for r in s["footprint"]:
        fp.setdefault(r["case"], []).append((int(r["n"]), int(r["mir_bytes"])))
    o.append("<h3>Size sweep: MIR footprint</h3>" + (lines(fp, "n", "MIR bytes",
                                                          lambda v: f"{v / 1e3:g} kB" if v >= 1e3 else f"{v:g} B") if fp else "<p>No sweep data.</p>"))
    o.append("<details><summary>Sweep phase table</summary><div class=wrap><table><tr><th>case</th><th>n</th><th>phase</th>"
             "<th>min</th><th>bytes</th></tr>" + "".join(
                 f"<tr><td>{E(r['case'])}</td><td>{r['n']}</td><td>{E(r['phase'])}</td><td>{fmt_ns(int(r['min_ns']))}</td>"
                 f"<td>{r['bytes']}</td></tr>" for r in s["phases"]) + "</table></div></details>")

    md = d["models"]
    o.append("<h3>Device build time: ARPice model corpus</h3>")
    if md:
        ok = [r for r in md["models"] if r.get("so_s")]
        for r in ok:
            r["vera"], r["zig"] = r["frontend_s"], max(r["so_s"] - r["frontend_s"], 0)
        o.append(legend(["VerA front end (--emit-zig)", "Zig compile of the device (rest of --emit-so)"], SERIES[:2]))
        o.append(hstack_s(ok))
        o.append("<div class=wrap><table><tr><th>model</th><th>source</th><th>--emit-zig</th><th>--emit-so</th>"
                 "<th>runs (s)</th><th>.so</th><th>exit</th></tr>" + "".join(
                     f"<tr><td>{E(r['model'])}</td><td>{r.get('source_bytes', '')} B</td>"
                     f"<td>{r['frontend_s']:.3f} s</td><td>{secs(r.get('so_s'))}</td>"
                     f"<td>{', '.join(f'{x:.2f}' for x in r['so_runs_s'])}</td>"
                     f"<td>{r['so_bytes'] or '–'} B</td><td>{E(str(r['exit']))}</td></tr>"
                     + (f"<tr><td></td><td colspan=6><pre>{E(r['error'])}</pre></td></tr>" if r.get("error") else "")
                     for r in md["models"] if "frontend_s" in r) + "</table></div>")
        o.append(f"<p class=note>Median of {md['reps']} runs, ReleaseFast device, built under a <code>--dyn</code> that "
                 "exports one <code>evalQ</code> over the sparse reference family (the device's eval and charge code; "
                 "a full host also compiles <code>updateState</code> and the rest of its vtable, so this is a lower "
                 "bound). A no-op <code>dyn</code> exports nothing, so Zig never analyses the device: it "
                 "cannot be timed. Cold for the device: every run has a fresh work dir, a fresh local cache, and its "
                 "own copy of a global cache that holds only compiler_rt and the other per-machine one-time builds "
                 "(Zig's global cache would otherwise return a whole previous build of the same device). Priming "
                 f"that base from empty, with a {E(md['first_build_model'])} build that compiles no device code, took "
                 f"{md['first_build_s']:.2f} s: the extra cost of a machine's very first build."
                 + (f" 1-minute load average {md['load_before']:.1f} before and {md['load_after']:.1f} after, on "
                    f"{md['cpus']} CPUs: a loaded machine inflates these times." if "load_before" in md else "") + "</p>")
    else:
        o.append("<p>Not measured in this run (pass <code>--models DIR</code>).</p>")
    o.append("<h3>Generated-device eval speed</h3><p>No eval-speed benchmark exists in <code>tests/</code> or "
             "<code>build.zig</code>, so this report measures none. Dated one-off measurements (ns/eval, Ir/eval, "
             "with their own bench hosts) were in <code>docs/measurements/</code>, removed in 6e59b3d4 (<code>git show 6e59b3d4^:docs/measurements/</code> lists them); they are not re-run here.</p>")
    # --- Gaps --------------------------------------------------------------
    g = d["gaps"]
    o.append("<h2 id=gaps>Gaps</h2>")
    o.append(f"<h3>Normative clauses closed by classification ({len(g['classified_normative'])})</h3>"
             "<p class=note>Classified under a kind other than non-normative: a reviewed claim that nothing "
             "can be pinned both ways, not evidence. Each is a place a future fixture could replace the claim.</p>"
             "<details><summary>list</summary><div class=wrap><table>"
             + "".join(f"<tr><td class=mono>{'LRM' if c['std'] == 'ams' else '1364'} {E(c['id'])}</td><td>{E(c['title'])}</td>"
                       f"<td>{E(c['kind'])}</td></tr>" for c in g["classified_normative"]) + "</table></div></details>")
    o.append(f"<h3>XFAIL fixtures ({len(g['xfail'])})</h3>"
             + ("<ul>" + "".join(f"<li class=mono>{E(x['path'])}: {E(x['reason'])}</li>" for x in g["xfail"]) + "</ul>"
                if g["xfail"] else "<p>None: no fixture carries <code>//! xfail</code> and no running <code>.c</code> fixture a <code>//! xfail</code>.</p>"))
    o.append(f"<h3>Open defects ({len(g['defects'])})</h3>"
             + ("<ul>" + "".join(f"<li><b>{E(x['title'])}</b> {E(x['text'])} <span class=note>({E(x['source'])})</span></li>"
                                 for x in g["defects"]) + "</ul>" if g["defects"] else "<p>None named.</p>"))
    o.append(f"<h3>docs/specification/Vague_Decisions.md: CHANGE NEEDED, not DONE ({len(g['vague'])})</h3><details><summary>list</summary><ul>"
             + "".join(f"<li><b>{E(v['id'])}</b> {E(v['title'])}: {E(v['change'])}</li>" for v in g["vague"]) + "</ul></details>")

    # --- Rule map ----------------------------------------------------------
    o.append("<h2 id=rules-h>Rule map</h2><p class=note>One row per clause. Positive (+) and rejection (−) "
             "fixtures are the citing files; rejection fixtures show the diagnostic their <code>//! reject</code> "
             "names.</p><div class=filters><input id=q placeholder='filter: clause, title, fixture, E-code' size=30>"
             "<select id=fstd><option value=''>both standards</option><option value=ams>LRM</option>"
             "<option value=ieee>IEEE 1364</option></select><select id=fst><option value=''>any status</option>"
             + "".join(f"<option>{x}</option>" for x in ("both", "classified", "positive-only", "rejection-only", "uncited"))
             + "</select><span id=cnt class=note></span></div><div class=wrap><table id=rules><thead><tr>"
             "<th>Clause</th><th>Title</th><th>Status</th><th>Fixtures</th></tr></thead><tbody>")
    for r in d["clauses"]:
        std = "LRM" if r["std"] == "ams" else "1364"
        neg = [f"{n['path']} [{', '.join(n['reject'])}]" for n in r["rejection"]]
        key = " ".join([r["id"], r["title"], r["status"], r["kind"] or "", *r["positive"], *neg]).lower()
        status = r["status"] + (f" · {r['kind']}" if r["kind"] else "") + (" · xfail" if r["xfail"] else "")
        detail = ""
        if r["reason"]:
            detail += f"<div class=note>{E(r['reason'][:600])}</div>"
        if r["positive"] or neg or r["xfail"]:
            detail += (f"<details><summary>+{len(r['positive'])} −{len(neg)}"
                       f"{' xfail ' + str(len(r['xfail'])) if r['xfail'] else ''}</summary><div class=mono>"
                       + paths(["+ " + p for p in r["positive"]] + ["− " + p for p in neg]
                               + [f"xfail {x['path']}: {x['reason']}" for x in r["xfail"]]) + "</div></details>")
        o.append(f"<tr data-std={r['std']} data-st={r['status']} data-k=\"{E(key)}\"><td class=mono>{std} {E(r['id'])}</td>"
                 f"<td>{E(r['title'])}</td><td class=st-{r['status']}>{E(status)}</td><td>{detail}</td></tr>")
    o.append("</tbody></table></div>")

    o.append(f"<script>{JS}</script></body></html>")
    return "\n".join(o)


def secs(v):
    return f"{v:.2f} s" if v else "failed"


def hstack_s(rows):
    """Model build time, stacked front end + Zig compile, seconds."""
    for r in rows:
        r["label"] = r["model"]
    bar_h, gap, lw, w = 18, 6, 90, 640
    peak = max((r["so_s"] for r in rows), default=1) or 1
    out = [f'<svg viewBox="0 0 {w} {len(rows) * (bar_h + gap) + 4}" class="chart" role="img">']
    for i, r in enumerate(rows):
        y, x = i * (bar_h + gap), lw
        out.append(f'<text x="{lw - 6}" y="{y + 13}" class="lab" text-anchor="end">{E(r["model"])}</text>')
        for k, c, n in (("vera", SERIES[0], "VerA front end"), ("zig", SERIES[1], "Zig compile")):
            bw = (w - lw - 70) * r[k] / peak
            out.append(f'<rect x="{x:.1f}" y="{y}" width="{max(bw - 2, 1):.1f}" height="{bar_h}" rx="2" fill="{c}">'
                       f'<title>{E(r["model"])} · {n}: {r[k]:.3f} s</title></rect>')
            x += bw
        out.append(f'<text x="{x + 4:.1f}" y="{y + 13}" class="val">{r["so_s"]:.2f} s</text>')
    out.append("</svg>")
    return "".join(out)


# ---------------------------------------------------------------------------

def git(*argv):
    return subprocess.run(["git", *argv], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def machine():
    if os.environ.get("GITHUB_ACTIONS"):
        return f"GitHub Actions {os.environ.get('RUNNER_OS', '')} {os.environ.get('ImageOS', '')} runner, {os.cpu_count()} CPUs"
    cpu = ""
    try:
        cpu = next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
    except (OSError, StopIteration):
        cpu = platform.processor()
    return f"{platform.system()} {platform.release()}, {cpu}, {os.cpu_count()} CPUs"


def load():
    """The 1-minute load average when the report was rendered: timings taken
    on a shared machine say so."""
    try:
        return f"load average {os.getloadavg()[0]:.1f} on {os.cpu_count()} CPUs at render time"
    except OSError:
        return "load average unavailable"


def selftest():
    """The parsers against the frozen report shapes they read."""
    cov = ("STATIC CITATION INVENTORY\n\n§3.1\n  + verilog/03/a.v\n\n"
           "UNCITED — no fixture names these at all:\n§2.1 Lexical  (x/CLAUSES.tsv)  ~ compile-only .c cite\n\n"
           "CLASSIFIED — CLAUSES.tsv: ...\n§3 Data types  [no_prohibition]  (x/CLAUSES.tsv)\n")
    assert buckets(cov) == {"2.1": ("uncited", "Lexical"), "3": ("classified", "Data types")}
    assert buckets("POSITIVE CITATIONS ONLY — x:\n§17.1 Display tasks\n") == {"17.1": ("positive-only", "Display tasks")}
    assert tsv("a\tb\n1\t2\n3\t4\n\nx", "a\tb") == [{"a": "1", "b": "2"}, {"a": "3", "b": "4"}]
    assert quantile([1, 2, 3, 4], 50) == 3
    assert isinstance(open_defects(), list) and isinstance(vpi_xfails(), list)
    print("report.py: selftest ok", file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------
# Standalone SVGs for the README (`--svg DIR`): the page's own charts, each
# wrapped with its title, an in-image legend and both palettes, so GitHub's
# <img> renders it without the page's CSS.
# ---------------------------------------------------------------------------

# Literal colours, no `var()`: an SVG rendered as an image (GitHub's <img>,
# rsvg) need not support custom properties. Each `fill`/`stroke` of
# `var(--x)` becomes class `f-x`/`k-x` (`svg_classes`), and dark mode
# overrides the classes.
SVG_LIGHT = {'bg': '#fcfcfb', 'fg': '#0b0b0b', 'mut': '#52514e', 'line': '#dcdbd6', 's1': '#2a78d6', 's2': '#eb6834', 's3': '#1baf7a', 's4': '#eda100', 's5': '#e87ba4', 's6': '#008300', 's7': '#4a3aa7', 's8': '#e34948'}
SVG_DARK = {'bg': '#1a1a19', 'fg': '#ffffff', 'mut': '#c3c2b7', 'line': '#3a3a37', 's1': '#3987e5', 's2': '#d95926', 's3': '#199e70', 's4': '#c98500', 's5': '#d55181', 's6': '#008300', 's7': '#9085e9', 's8': '#e66767'}


def _svg_rules(c):
    r = "".join(f".f-{k}{{fill:{v}}}.k-{k}{{stroke:{v}}}" for k, v in c.items())
    return (r + f".bg{{fill:{c['bg']}}}.t{{fill:{c['fg']}}}.lab{{fill:{c['mut']}}}.val{{fill:{c['fg']}}}"
            f".axis{{stroke:{c['mut']}}}.grid{{stroke:{c['line']}}}")


SVG_CSS = (_svg_rules(SVG_LIGHT) + ".t{font-size:15px;font-weight:600}.lab,.val{font-size:11px}"
           "@media (prefers-color-scheme:dark){" + _svg_rules(SVG_DARK) + "}")


def svg_classes(text):
    """Move every `fill="var(--x)"` / `stroke="var(--x)"` into a class."""
    def tag(m):
        body, cls = m.group(2), []
        for attr, pre in (("fill", "f"), ("stroke", "k")):
            v = re.search(attr + r'="var\(--(\w+)\)"', body)
            if v:
                cls.append(f"{pre}-{v.group(1)}")
                body = body.replace(v.group(0), "")
        if not cls:
            return m.group(0)
        old = re.search(r'class="([^"]*)"', body)
        if old:
            return f"<{m.group(1)}" + body.replace(old.group(0), f'class="{old.group(1)} {" ".join(cls)}"') + ">"
        return f'<{m.group(1)} class="{" ".join(cls)}"' + body + ">"
    return re.sub(r"<(\w+)([^<>]*)>", tag, text)


VAR = ["var(--s1)", "var(--s2)", "var(--s3)", "var(--s4)"]


def standalone(chart, title, sub, legend_items=()):
    m = re.match(r'<svg viewBox="0 0 ([\d.]+) ([\d.]+)"[^>]*>(.*?)</svg>', chart, re.S)
    w, h, inner = float(m.group(1)), float(m.group(2)), m.group(3)
    top = 52 + (20 if legend_items else 0)
    leg, x = [], 16
    for name, c in legend_items:
        leg.append(f'<rect x="{x}" y="58" width="10" height="10" rx="2" fill="{c}"/>'
                   f'<text x="{x + 14}" y="67" class="lab">{E(name)}</text>')
        x += 24 + 6.2 * len(name)
    W, H = w + 32, h + top + 12
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}" width="{W:.0f}" height="{H:.0f}" '
            f'font-family="system-ui,-apple-system,Segoe UI,Helvetica,sans-serif" role="img" aria-label="{E(title)}">'
            f'<title>{E(title)}</title><style>{SVG_CSS}</style><rect class="bg" width="100%" height="100%" rx="8"/>'
            f'<text class="t" x="16" y="26">{E(title)}</text><text class="lab" x="16" y="44">{E(sub)}</text>'
            + svg_classes("".join(leg) + f'<g transform="translate(16,{top})">{inner}</g>') + "</svg>\n")


def pct_rows(rows):
    """One 100% bar per measure: rows of (label, [(name, count, color)])."""
    bar_h, gap, lw, w = 18, 10, 150, 640
    out = [f'<svg viewBox="0 0 {w} {len(rows) * (bar_h + gap)}" class="chart" role="img">']
    for i, (label, segs) in enumerate(rows):
        y, x, total = i * (bar_h + gap), lw, sum(c for _, c, _ in segs) or 1
        out.append(f'<text x="{lw - 8}" y="{y + 13}" class="lab" text-anchor="end">{E(label)}</text>')
        for name, c, col in segs:
            bw = (w - lw - 10) * c / total
            if c:
                out.append(f'<rect x="{x:.1f}" y="{y}" width="{max(bw - 2, 1):.1f}" height="{bar_h}" rx="3" fill="{col}">'
                           f'<title>{E(label)} · {E(name)}: {c}</title></rect>')
            x += bw
        main = segs[0][1]
        out.append(f'<text x="{lw + 6}" y="{y + 13}" class="val" style="fill:#fff">{main} / {total}</text>')
    out.append("</svg>")
    return "".join(out)


def export_svgs(d, out):
    out.mkdir(parents=True, exist_ok=True)
    m, s, meta = d["measures"], d["speed"], d["meta"]
    a = m["A"]
    sub = f"VerA {meta['sha'][:8]} · {meta['date'][:10]} · measured by tools/report.py"
    rows = [("A · fixtures", [("pass", int(a["pass"]), VAR[0]), ("known gap (XFAIL)", int(a["xfail"]), VAR[1]),
                              ("FAIL", int(a["fail"]) + int(a["unasserted"]), VAR[3])])]
    for key, name in (("B", "B · IEEE 1364 clauses"),):
        x = m[key]
        rows.append((name, [("tested both ways", int(x["both"]), VAR[0]),
                            ("one-way or uncited", int(x["pos"]) + int(x["neg"]) + int(x["unc"]), VAR[1]),
                            ("classified", int(x["classified"]), VAR[2])]))
    files = {"conformance.svg": standalone(pct_rows(rows), "Conformance: measures A and B", sub,
                                           [("pass / tested both ways", VAR[0]), ("known gap", VAR[1]),
                                            ("classified (CLAUSES.tsv)", VAR[2])])}
    keys = ["both", "classified", "one-way", "uncited"]
    names = ["tested both ways", "classified", "one-way", "uncited"]
    for std, fname, title in (("ieee", "ieee-chapters.svg", "IEEE 1364-2005 clauses by chapter (B)"),):
        chs = d["chapters"][std]
        cols = [VAR[0], VAR[2], VAR[1], VAR[3]]  # the same roles as conformance.svg
        files[fname] = standalone(hstack(chs, "chapter", keys, names, cols), title, sub, list(zip(names, cols)))
    r = s["summary"][0] if s["summary"] else None
    hsub = sub + (f" · median {fmt_ns(int(r['p50_ns']))}, p99 {fmt_ns(int(r['p99_ns']))}, n={r['n']}" if r else "")
    files["compile-time.svg"] = standalone(histogram([f["ns"] for f in s["fixtures"]]),
                                           "Compile time per fixture (source → device code)", hsub)
    md = d["models"]
    ok = [x for x in (md or {}).get("models", []) if x.get("so_s")]
    if ok:
        for x in ok:
            x["vera"], x["zig"] = x["frontend_s"], max(x["so_s"] - x["frontend_s"], 0)
        files["model-build.svg"] = standalone(
            hstack_s(ok), "Building ARPice's compact models to a loadable .so (CPU)",
            sub + f" · median of {md.get('reps', '?')} cold builds, evalQ only (a host compiles more)",
            [("VerA front end", SERIES[0]), ("Zig compile of the device", SERIES[1])])
    by_case = {}
    for x in s["phases"]:
        if x["phase"] == "codegen":
            by_case.setdefault(x["case"], []).append((int(x["n"]), int(x["min_ns"])))
    if by_case:
        sw = lines(by_case, "n (generated size along each axis)", "", fmt_ns)
        sw = sw[:sw.index("</svg>") + 6]
        files["scaling.svg"] = standalone(sw, "Compile time vs design size (log–log)", sub,
                                          list(zip(by_case, SERIES)))
    for name, text in files.items():
        (out / name).write_text(text)
    print(f"report.py: wrote {', '.join(files)} to {out}", file=sys.stderr)


def main(argv):
    if argv == ["--selftest"]:
        return selftest()
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--logs", type=Path, default=ROOT / "report/logs")
    ap.add_argument("--out", type=Path, default=ROOT / "report")
    ap.add_argument("--models", type=Path, help="directory holding the ARPice .va models")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--svg", type=Path, help="also write the README's standalone SVG charts here")
    args = ap.parse_args(argv)
    args.logs.mkdir(parents=True, exist_ok=True)
    args.out.mkdir(parents=True, exist_ok=True)

    if subprocess.run(["zig", "build", OPT, "install"], cwd=ROOT, stdout=sys.stderr).returncode:
        return 2
    strict, cov1364 = log(args.logs, "strict"), log(args.logs, "coverage1364")
    devices, vpi, sweep = log(args.logs, "devices"), log(args.logs, "vpi"), log(args.logs, "sweep")

    # Measures A and B, parsed the way conformance.py parses them.
    head = [i for i, l in enumerate(strict.split("\n")) if l == "pass\tfail\tunasserted\txfail"]
    row = strict.split("\n")[head[-1] + 1].split("\t") if head else ["?"] * 4
    rcs = re.findall(r"^(?:strict exit: |exit=)(\d+)", strict, re.M)
    measures = {"A": dict(zip(("pass", "fail", "unasserted", "xfail"), row), strict_rc=rcs[-1] if rcs else "?")}
    measures["A"]["total"] = sum(int(v) for v in row if C.is_num(v))
    for key, text, pat in (("B", cov1364, r"^\d+ of (\d+)(?= IEEE 1364-2005 clauses cited)"),):
        both, pos, neg, unc = C.polarity(text)
        measures[key] = {"both": both, "pos": pos, "neg": neg, "unc": unc, "clauses": C.first(pat, text),
                         "classified": C.first(r"(\d+)(?= classified$)", text)}
    measures["devices"] = C.first(r"^devices: (.*)$", devices)
    measures["vpi"] = C.first(r"^vpi: (.*)$", vpi)

    clauses = clause_rows(cov1364)
    for key, std in (("B", "ieee"),):
        n = sum(r["std"] == std for r in clauses)
        if str(n) != measures[key]["clauses"]:
            print(f"report.py: {std} rule map has {n} rows, the tally says {measures[key]['clauses']}", file=sys.stderr)

    xfail = []
    for p in C.fixture_files("*.va", "*.v"):
        _, reason = fixture_tags(str(p.relative_to(ROOT)))
        if reason is not None:
            xfail.append({"path": str(p.relative_to(ROOT)), "reason": reason})

    models = None
    if args.models:
        mj = args.logs / "models.json"
        if not mj.exists():
            scratch = Path(tempfile.mkdtemp(prefix="vera-report-"))
            try:
                mj.write_text(json.dumps(time_models(args.models.resolve(), args.reps, scratch), indent=1))
            finally:
                shutil.rmtree(scratch, ignore_errors=True)
        models = json.loads(mj.read_text())

    zig = subprocess.run(["zig", "version"], capture_output=True, text=True).stdout.strip()
    data = {
        "meta": {"sha": git("rev-parse", "HEAD"), "date": git("show", "-s", "--format=%cI", "HEAD"),
                 "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                 "zig": zig, "machine": machine(), "load": load(),
                 "commands": [" ".join(c) for c in SUITES.values()]
                 + ([f"vera --emit-so --contract lib/contract.zig --dyn dyn.zig (report.py's DYN) -I {args.models} --work-dir out <model>.va"
                     f"  (x{args.reps}, median; and vera --emit-zig)"] if args.models else [])},
        "measures": measures,
        "chapters": {"ieee": chapter_table(clauses, "ieee")},
        "clauses": clauses,
        "gaps": {"classified_normative": [{k: r[k] for k in ("std", "id", "title", "kind")} for r in clauses
                                          if r["kind"] and r["kind"] != "non-normative"],
                 "xfail": xfail + vpi_xfails(), "defects": open_defects(), "vague": vague_open()},
        "speed": speed(strict, sweep),
        "models": models,
    }
    (args.out / "data.json").write_text(json.dumps(data, indent=1))
    (args.out / "index.html").write_text(render(data))
    if args.svg:
        export_svgs(data, args.svg)
    print(f"report.py: wrote {args.out / 'index.html'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
