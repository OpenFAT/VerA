#!/usr/bin/env python3
"""VerA's release measures and fixture-maintenance signals.

    tools/conformance.py                      # print the measures block
    tools/conformance.py --changelog v0.1.0   # set the version literals, prepend it to CHANGELOG.md
    tools/conformance.py --check v0.1.0       # check them, re-measure and diff vs CHANGELOG.md
    tools/conformance.py <subcommand> [...]   # one of the signals below

The measures block is the VAMS Conformance Suite's per-language score from
`zig build conformance` (the suite's `conform` harness, `tools/vera.xfail`).
Every number comes from that run; none is typed. Every subcommand is a
separate signal and none of them changes the block or CHANGELOG.md:

    ieee1364-audit       the IEEE 1364-2005 heading worklist (licensed local PDF)
    keywords             Table B.1 against the PDF, and its spelling fixtures
    determinism          `--emit-zig` device text across runs, cwds and binaries
    promote-reject-only  `//! reject` -> `//! reject-only` from a probe run
    link-neighbours      add `//! neighbour` where a refusal names its legal twin
    selftest             regression checks: the subcommands and the fixture layout
"""
import argparse
import datetime
import difflib
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# The VAMS Conformance Suite (a submodule). Its tests/ is the corpus; result
# paths are relative to it (`verilog-a/ch05_analog_behavior/x.va`).
SUITE = ROOT / "tests/conformance"
FIXTURES = SUITE / "tests"
# The corpus subtrees VerA runs: the AMS roots, plus the IEEE 1364 tree.
# netlist/ is ESPice's decks and include/ the shared headers: never fixtures.
AMS_ROOTS = ("verilog-a", "verilog-ams", "spice")
FIXTURE_ROOTS = AMS_ROOTS + ("verilog",)
INCLUDE = FIXTURES / "include"


def fixture_files(*patterns, roots=FIXTURE_ROOTS):
    """Every fixture under `roots` matching one of `patterns`, sorted. The
    wrong-on-purpose canary fixtures live in VerA's tests/canary, outside every root."""
    return sorted(p for root in roots for pattern in patterns for p in (FIXTURES / root).rglob(pattern)
                  if p.is_file())

# name -> function(argv) -> exit code. Each section below adds its own.
SUBCOMMANDS = {}


def die(msg):
    print(f"conformance.py: {msg}", file=sys.stderr)
    sys.exit(2)


def run(*argv):
    """`$(argv 2>&1)` and its exit status."""
    p = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.stdout.decode("utf-8", "replace").rstrip("\n"), p.returncode


SCORED = (("verilog-a", "Verilog-A"), ("verilog", "Verilog"), ("verilog-ams", "Verilog-AMS"))


def suite_scores(rows):
    """`zig-out/conformance.tsv` rows (status, test name, ...) -> {category:
    (passed, total)}, by the suite's own categories (its tools/report.py): a
    test's language is its directory under tests/ or its manifest row's first
    column. XFAIL counts as a fail and XPASS as a pass; a skip counts against."""
    spec = importlib.util.spec_from_file_location("vams_suite_report", SUITE / "tools" / "report.py")
    suite_report = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(suite_report)
    langs = suite_report.languages()
    out = {}
    for row in rows:
        status, name = row[0], row[1]
        cat = suite_report.category(name, langs)
        if cat is None:
            continue
        p, t = out.get(cat, (0, 0))
        out[cat] = (p + (status in ("PASS", "XPASS")), t + 1)
    return out


def measure():
    """The VAMS Conformance Suite's score per language, the one line a release
    carries. CONFORMANCE_TSV reuses a finished run (CI's); locally this runs
    `zig build conformance` itself."""
    tsv = Path(os.environ.get("CONFORMANCE_TSV", "") or ROOT / "zig-out" / "conformance.tsv")
    if not os.environ.get("CONFORMANCE_TSV"):
        if subprocess.run(["zig", "build", "-Doptimize=ReleaseFast", "conformance"], cwd=ROOT, stdout=sys.stderr).returncode:
            die("zig build conformance failed")
    try:
        rows = [l.split("\t") for l in tsv.read_text().splitlines() if l.strip()]
    except OSError:
        die(f"no suite results at {tsv}")
    scores = suite_scores(rows)
    if any(c not in scores for c, _ in SCORED):
        die(f"{tsv}: no tests in {', '.join(t for c, t in SCORED if c not in scores)}")
    passed = sum(scores[c][0] for c, _ in SCORED)
    total = sum(scores[c][1] for c, _ in SCORED)
    parts = ", ".join(f"{title} {scores[c][0]}/{scores[c][1]}" for c, title in SCORED)
    line = f"On Suite VAMS-CONFORMANCE, we score {parts}, Cumulative: {passed}/{total}."
    return line, f"{passed}/{total} suite tests"


def measured(lines):
    """The one line `--check` holds a release to."""
    return [l for l in lines if l.startswith("On Suite VAMS-CONFORMANCE")]


def section(text, version):
    """`sed -n '/^## <version> /,/^## .*—/p'`: from the entry's heading to the
    next entry's, both included."""
    start = re.compile("^## " + re.escape(version) + " ")
    end = re.compile("^## .*—")
    out, inside = [], False
    for line in text.split("\n"):
        if inside:
            out.append(line)
            inside = not end.search(line)
        elif start.search(line):
            out.append(line)
            inside = True
    return out


VERSION_LITERALS = (
    (ROOT / "build.zig.zon", re.compile(r'(\.version = ")([^"]*)(")')),
    (ROOT / "lib" / "contract.zig", re.compile(r'(^pub const vera_version = ")([^"]*)(";)', re.M)),
)


def release_version(mode, version):
    """`build.zig.zon`'s `.version` and `contract.vera_version` (which every
    device carries) name the release together; the CLI's test holds them
    equal. `--changelog vX.Y.Z` sets both to X.Y.Z before it measures;
    `--check vX.Y.Z` refuses a tree where either is another version."""
    if not re.fullmatch(r"v\d+\.\d+\.\d+", version):
        die(f"{version}: not a vX.Y.Z release")
    for path, pat in VERSION_LITERALS:
        text = path.read_text()
        m = pat.search(text)
        if not m:
            die(f"{path.name}: no version literal")
        if mode == "--changelog":
            path.write_text(text[:m.start(2)] + version[1:] + text[m.end(2):])
        elif m[2] != version[1:]:
            die(f"{path.name} says {m[2]}, not {version[1:]}. Run: tools/conformance.py --changelog {version}")


def measures(mode, version):
    changelog = ROOT / "CHANGELOG.md"
    if mode:
        release_version(mode, version)
    block, summary = measure()
    if not mode:
        print(block)
        return 0
    text = changelog.read_text() if changelog.exists() else ""
    if mode == "--check":
        if not re.search("^## " + re.escape(version) + " ", text, re.M):
            die(f"CHANGELOG.md has no {version} entry. Run: tools/conformance.py --changelog {version}")
        want = measured(section(text, version))
        got = measured(block.split("\n"))
        if want == got:
            print(f"conformance.py: {version} matches the tree — {summary}", file=sys.stderr)
            return 0
        print(f"conformance.py: CHANGELOG.md's {version} numbers are not what this tree measures.", file=sys.stderr)
        print("  Left is CHANGELOG.md, right is this run. Re-tag after re-measuring:", file=sys.stderr)
        print(f"    tools/conformance.py --changelog {version}", file=sys.stderr)
        sys.stderr.writelines(difflib.unified_diff(
            [l + "\n" for l in want], [l + "\n" for l in got], "CHANGELOG.md", "this tree"))
        return 1
    # --changelog: the `## Unreleased` section becomes `## <version> — date`,
    # the measured block goes under that heading above its bullets, and a new
    # empty `## Unreleased` opens above it. With no `## Unreleased`, the entry
    # is prepended after the preamble (everything before the first `## `).
    lines = text.splitlines(keepends=True)
    cut = next((i for i, l in enumerate(lines) if l.startswith("## ")), len(lines))
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    entry = f"## {version} — {date}\n\n{block}\n\n"
    if cut < len(lines) and lines[cut].strip() == "## Unreleased":
        changelog.write_text("".join(lines[:cut]) + "## Unreleased\n\n" + entry + "".join(lines[cut + 1:]).lstrip("\n"))
    else:
        changelog.write_text("".join(lines[:cut]) + entry + "".join(lines[cut:]))
    print(f"CHANGELOG.md: {version} written — {summary}", file=sys.stderr)
    return 0


def main(argv):
    if argv and argv[0] in SUBCOMMANDS:
        return SUBCOMMANDS[argv[0]](argv[1:])
    mode = argv[0] if argv else ""
    if mode not in ("", "--changelog", "--check"):
        print(f"usage: conformance.py [--changelog|--check vX.Y.Z] | {'|'.join(SUBCOMMANDS)} ...", file=sys.stderr)
        return 2
    version = argv[1] if len(argv) > 1 else ""
    if mode and not version:
        print(f"usage: conformance.py {mode} vX.Y.Z", file=sys.stderr)
        return 2
    return measures(mode, version)


# ---------------------------------------------------------------------------
# ieee1364-audit: the IEEE 1364-2005 heading worklist (the licensed local PDF)
# ---------------------------------------------------------------------------

IEEE_SHA256 = "3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e"
# The pinned PDF's TOC lists 212; the body heading is on printed page 213.
# Explicitly retain both, rather than silently searching past a bad anchor.
ANCHOR_CORRECTIONS = {"14.2.1": 213}
IEEE_ROW = re.compile(r"^\s*((?:[0-9]+|[A-I])(?:\.[0-9]+)*)\.?\s+(.+?)\s*\.{3,}\s*(\d+)\s*$")
IEEE_ANNEX = re.compile(r"^\s*Annex ([A-I]) \((normative|informative)\)\s+(.+?)\s*\.{3,}\s*(\d+)\s*$")


def worklist(text):
    pages = text.split("\f")
    if not pages[-1].strip():
        pages.pop()
    body_start = next((i for i, page in enumerate(pages)
                       if re.search(r"(?m)^\s*1\. Overview\s*$", page)), None)
    if body_start is None:
        raise ValueError("cannot locate body heading 1. Overview")
    toc = "\n".join(pages[:body_start])
    start = re.search(r"(?m)^\s*Contents\s*$", toc)
    if not start:
        raise ValueError("cannot locate Contents")
    rows = []
    seen = set()
    ended = False
    for line in toc[start.end():].splitlines():
        annex = IEEE_ANNEX.match(line)
        match = IEEE_ROW.match(line)
        if annex:
            clause, kind, title, printed = annex.groups()
        elif match:
            clause, title, printed = match.groups()
            kind = "informative" if clause.split(".")[0] in ("C", "D", "H", "I") else "normative"
        elif re.search(r"\.{3,}\s*\d+\s*$", line):
            raise ValueError("unparsed TOC entry: " + line.strip())
        else:
            continue
        if clause in seen:
            raise ValueError("duplicate TOC clause: " + clause)
        seen.add(clause)
        if clause.split(".")[0] in ("21", "22", "23", "24", "25", "E", "F"):
            kind = "deprecated-removed"
        body_printed = ANCHOR_CORRECTIONS.get(clause, int(printed))
        physical = body_printed + body_start
        if not 1 <= physical <= len(pages):
            raise ValueError("page outside document: " + clause)
        page = pages[physical - 1]
        # Require the heading identifier at a line start on its listed page.
        # This does not verify title typography or complete body boundaries.
        prefix = "Annex " + clause if annex else re.escape(clause) + (r"\." if "." not in clause else "")
        located = bool(re.search(r"(?m)^\s*" + prefix + r"(?:\s|$)", page))
        rows.append({"id": "IEEE1364-2005:" + clause, "clause": clause,
                     "title": title.strip(), "toc_printed_page": int(printed),
                     "printed_page": body_printed,
                     "pdf_page": physical, "classification": kind,
                     "heading_located": located, "rule_review": "not-assessed"})
        if clause == "I":
            ended = True
            break
    if not ended:
        raise ValueError("TOC incomplete: Annex I endpoint absent")
    return rows


def ieee1364_audit(argv):
    """Local licensed-source heading worklist, never a conformance denominator.

    No source body text is written. Requires the user's local IEEE PDF and
    Poppler. The table of contents locates headings; it does not enumerate
    atomic rules. 
    """
    parser = argparse.ArgumentParser(prog="conformance.py ieee1364-audit", description=ieee1364_audit.__doc__)
    parser.add_argument("--pdf", type=Path, default=ROOT / "docs/specification/1364-2005.pdf")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        digest = hashlib.sha256(args.pdf.read_bytes()).hexdigest()
        if digest != IEEE_SHA256:
            raise ValueError("source hash differs; verify edition/pagination before updating provenance")
        text = subprocess.run(["pdftotext", "-layout", str(args.pdf), "-"],
                              check=True, capture_output=True, text=True).stdout
        rows = worklist(text)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print("IEEE source audit: " + str(exc), file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({"source_sha256": digest, "warning": "Heading worklist only; no rule coverage claim",
                          "sections": rows}, indent=2))
    else:
        print("Heading worklist only; no rule coverage claim. SHA256 " + digest)
        for row in rows:
            print("\t".join((row["id"], str(row["pdf_page"]), row["classification"],
                              "located" if row["heading_located"] else "REVIEW-ANCHOR", row["title"])))
    return 1 if any(not row["heading_located"] for row in rows) else 0


SUBCOMMANDS["ieee1364-audit"] = ieee1364_audit


# ---------------------------------------------------------------------------
# keywords: Table B.1 against the PDF, and the exhaustive spelling fixtures
# ---------------------------------------------------------------------------

LRM_PDF = ROOT / "docs/specification/VAMS-LRM-2023.pdf"
LRM_SHA256 = "e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134"
# Table B.1 (physical pages 400-401), its negedgenmos defect split into
# negedge and nmos. Transcribed once from the retired HTML LRM; `keywords`
# re-reads the PDF against it.
VAMS_KEYWORDS = frozenset((
    "above", "abs", "absdelay", "absdelta", "abstol", "ac_stim", "access", "acos", "acosh", "aliasparam",
    "always", "analog", "analysis", "and", "asin", "asinh", "assign", "atan", "atan2", "atanh", "automatic",
    "begin", "branch", "break", "buf", "bufif0", "bufif1", "case", "casex", "casez", "ceil", "cell",
    "cmos", "config", "connect", "connectmodule", "connectrules", "continue", "continuous", "cos", "cosh",
    "cross", "ddt", "ddt_nature", "ddx", "deassign", "default", "defparam", "design", "disable", "discipline",
    "discrete", "domain", "driver_update", "edge", "else", "end", "endcase", "endconfig", "endconnectrules",
    "enddiscipline", "endfunction", "endgenerate", "endmodule", "endnature", "endparamset", "endprimitive",
    "endspecify", "endtable", "endtask", "event", "exclude", "exp", "expm1", "final_step", "flicker_noise",
    "floor", "flow", "for", "force", "forever", "fork", "from", "function", "generate", "genvar", "ground",
    "highz0", "highz1", "hypot", "idt", "idt_nature", "idtmod", "if", "ifnone", "incdir", "include",
    "inf", "initial", "initial_step", "inout", "input", "instance", "integer", "join", "laplace_nd",
    "laplace_np", "laplace_zd", "laplace_zp", "large", "last_crossing", "liblist", "library", "limexp",
    "ln", "ln1p", "localparam", "log", "macromodule", "max", "medium", "merged", "min", "module", "nand",
    "nature", "negedge", "nmos", "noise_table", "noise_table_log", "nor", "noshowcancelled", "not",
    "notif0", "notif1", "or", "output", "parameter", "paramset", "pmos", "posedge", "potential", "pow",
    "primitive", "pull0", "pull1", "pulldown", "pullup", "pulsestyle_ondetect", "pulsestyle_onevent",
    "rcmos", "real", "realtime", "reg", "release", "repeat", "resolveto", "return", "rnmos", "rpmos",
    "rtran", "rtranif0", "rtranif1", "scalared", "showcancelled", "signed", "sin", "sinh", "slew", "small",
    "specify", "specparam", "split", "sqrt", "string", "strong0", "strong1", "supply0", "supply1", "table",
    "tan", "tanh", "task", "time", "timer", "tran", "tranif0", "tranif1", "transition", "tri", "tri0",
    "tri1", "triand", "trior", "trireg", "units", "unsigned", "use", "uwire", "vectored", "wait", "wand",
    "weak0", "weak1", "while", "white_noise", "wire", "wor", "wreal", "xnor", "xor", "zi_nd", "zi_np",
    "zi_zd", "zi_zp",
))


def keyword_inventory():
    if hashlib.sha256(LRM_PDF.read_bytes()).hexdigest() != LRM_SHA256:
        raise ValueError("Source PDF changed: re-audit Table B.1 pages and correction")
    source = subprocess.run([
        "pdftotext", "-f", "400", "-l", "401", "-layout",
        str(LRM_PDF), "-",
    ], check=True, capture_output=True, text=True).stdout
    words = []
    for line in source.splitlines():
        if re.fullmatch(r"\s*[a-z][a-z_0-9]*(?:\s+[a-z][a-z_0-9]*){0,2}\s*", line):
            words.extend(line.split())
    # Visually confirmed source-table defect.
    if words.count("negedgenmos") != 1:
        raise ValueError("Source table changed: re-audit the negedgenmos correction")
    words.remove("negedgenmos")
    words.extend(["negedge", "nmos"])
    if len(words) != len(set(words)):
        raise ValueError("Duplicate source keyword")
    if set(words) != VAMS_KEYWORDS:
        raise ValueError(f"PDF-only: {set(words) - VAMS_KEYWORDS}; "
                         f"VAMS_KEYWORDS-only: {VAMS_KEYWORDS - set(words)}")
    return sorted(words)


def keyword_fixture(words, mode):
    entries = []
    for word in words:
        if mode == "escaped":
            entries.append(("\\" + word + " ", "escaped " + word))
        else:
            entries.extend([(word.upper(), "uppercase " + word),
                            (word[0].upper() + word[1:], "initial-uppercase " + word)])
    lines = [
        "// Generated by tools/conformance.py keywords --fixture " + mode,
        "// Source: VAMS-2023 Table B.1, physical pages 400-401;",
        "// the PDF's negedgenmos defect is split into negedge and nmos.",
        "// Annex B and 2.8.2 reserve nonescaped lowercase spellings only.",
        "// Each legal identifier is assigned its one-based inventory position.",
        "// All assignments precede all observations: name aliasing cannot hide",
        "// behind an immediate assignment/read pair. Each expected integer is",
        "// independently fixed by the generator, not read from the compiler.",
        "// This tests variable identifiers, not all identifier grammar positions.",
        "// Reads use a plain temporary so macro-argument whitespace processing",
        "// cannot hide the keyword-name test; see KEY-MACRO-001 in the audit.",
        "//! lrm B", "//! lrm 2.8.2", f"//! checks {len(entries)}", "//! print none",
        '`include "check.vh"', f"module audit_all_{mode}_keywords(p, n);",
        "    inout p, n;", "    electrical p, n;",
    ]
    lines += [f"    real {name};" for name, _ in entries]
    lines += ["    real observed;"]
    lines += ["    analog begin"]
    lines += [f"        {name} = {i}.0;" for i, (name, _) in enumerate(entries, 1)]
    for i, (name, label) in enumerate(entries, 1):
        lines += [f"        observed = {name};",
                  f'        `CHECKX("{label}", observed, {i}.0);']
    lines += ["        I(p,n) <+ 0.0;", "    end", "endmodule"]
    return "\n".join(lines) + "\n"


def keywords(argv):
    """Audit Table B.1 against the PDF; emit exhaustive spelling fixtures to stdout.

    This checks the spelling inventory, not implementation of keyword constructs
    or every grammar position. No compiler token table is used as the oracle.
    """
    parser = argparse.ArgumentParser(prog="conformance.py keywords", description=keywords.__doc__)
    parser.add_argument("--fixture", choices=["escaped", "case"])
    parser.add_argument("--check-fixtures", action="store_true")
    args = parser.parse_args(argv)
    words = keyword_inventory()
    if args.fixture:
        print(keyword_fixture(words, args.fixture), end="")
        return 0
    if args.check_fixtures:
        for mode in ["escaped", "case"]:
            path = next(FIXTURES.glob(f"*/annex_b_keywords/all_{mode}_keywords.va"))
            if path.read_text() != keyword_fixture(words, mode):
                raise SystemExit(f"Fixture drift: {path}")
    print(f"Table B.1: {len(words)} distinct corrected spellings; the PDF matches VAMS_KEYWORDS.")
    return 0


SUBCOMMANDS["keywords"] = keywords


# ---------------------------------------------------------------------------
# selftest: regression checks for the subcommands above. Tool integrity,
# not language conformance: no fixture
# earns credit here, and none of these runs the compiler.
# ---------------------------------------------------------------------------

import unittest
from unittest.mock import patch


class ReleaseVersionTests(unittest.TestCase):
    """`--changelog` sets both version literals; `--check` refuses a stale one."""

    def test_changelog_sets_both_and_check_reads_them(self):
        with tempfile.TemporaryDirectory() as d:
            zon, con = Path(d) / "build.zig.zon", Path(d) / "contract.zig"
            zon.write_text('.{\n    .version = "0.9.0",\n    .minimum_zig_version = "0.17.0",\n}\n')
            con.write_text('/// a\npub const vera_version = "0.9.0";\n')
            lits = ((zon, VERSION_LITERALS[0][1]), (con, VERSION_LITERALS[1][1]))
            with patch(__name__ + ".VERSION_LITERALS", lits), patch("sys.stderr"):
                release_version("--check", "v0.9.0")
                with self.assertRaises(SystemExit):
                    release_version("--check", "v0.10.0")
                with self.assertRaises(SystemExit):
                    release_version("--changelog", "0.10.0")
                release_version("--changelog", "v0.10.0")
                release_version("--check", "v0.10.0")
            self.assertIn('.minimum_zig_version = "0.17.0"', zon.read_text())
            self.assertIn('pub const vera_version = "0.10.0";', con.read_text())


class InstallScriptTests(unittest.TestCase):
    """tools/install.sh against a sources.json of local tarballs: it installs the
    newest version by version order (0.10.0 over 0.9.0), reuses a cached
    tarball, switches its link to a pinned version, and refuses a tarball
    whose sha256 is not sources.json's."""

    def test_install_cache_pin_and_hash(self):
        import platform, tarfile
        machine = {"amd64": "x86_64", "arm64": "aarch64"}.get(platform.machine().lower(), platform.machine().lower())
        system = f"{machine}-{ {'Linux': 'linux', 'Darwin': 'darwin'}.get(platform.system(), '')}"
        if system.endswith("-"):
            self.skipTest("install.sh supports Linux and macOS")
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            sources = {}
            for v in ("0.9.0", "0.10.0"):
                exe = d / v / "vera"
                exe.parent.mkdir()
                exe.write_text(f"#!/bin/sh\necho vera {v}\n")
                exe.chmod(0o755)
                tgz = d / f"vera-{v}.tar.gz"
                with tarfile.open(tgz, "w:gz") as t:
                    t.add(exe, arcname="vera")
                sources[v] = {system: {"url": str(tgz), "sha256": hashlib.sha256(tgz.read_bytes()).hexdigest()}, "zig": "0.0.0"}
            catalogue = d / "sources.json"
            catalogue.write_text(json.dumps(sources, indent=2, sort_keys=True))
            env = dict(os.environ, VERA_SOURCES=str(catalogue), VERA_HOME=str(d / "home"),
                       VERA_BIN=str(d / "bin"), VERA_CACHE=str(d / "cache"))
            run = lambda *a: subprocess.run(["sh", str(ROOT / "tools" / "install.sh"), *a], env=env, capture_output=True, text=True)
            vera = lambda: subprocess.run([str(d / "bin" / "vera")], capture_output=True, text=True).stdout.strip()

            first = run()
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertIn("downloading 0.10.0", first.stdout)
            self.assertEqual(vera(), "vera 0.10.0")
            again = run()
            self.assertIn("0.10.0 for " + system + " is cached", again.stdout)
            pinned = run("v0.9.0")
            self.assertEqual(pinned.returncode, 0, pinned.stderr)
            self.assertEqual(vera(), "vera 0.9.0")

            (d / "vera-0.10.0.tar.gz").write_bytes(b"not the release")
            (d / "cache" / f"vera-0.10.0-{system}.tar.gz").unlink()
            tampered = run("0.10.0")
            self.assertNotEqual(tampered.returncode, 0)
            self.assertIn("sha256", tampered.stderr)
            self.assertEqual(vera(), "vera 0.9.0")


class SuiteScoreTests(unittest.TestCase):
    """The release line: XFAIL fails, XPASS passes, a skip counts against, SPICE is not scored."""

    def test_scores_by_language(self):
        rows = [("PASS", "verilog-a/a.va"), ("XFAIL", "verilog-a/b.va"), ("XPASS", "verilog/c.v"),
                ("SKIP", "verilog/d.v"), ("PASS", "verilog-ams/e.vams"), ("PASS", "netlist/f.sp")]
        self.assertEqual(suite_scores(rows), {"verilog-a": (1, 2), "verilog": (1, 2), "verilog-ams": (1, 1), "spice": (1, 1)})
        self.assertEqual(measured(["x", "On Suite VAMS-CONFORMANCE, we score Verilog-A 1/2"]),
                         ["On Suite VAMS-CONFORMANCE, we score Verilog-A 1/2"])
class InheritedWorklistTests(unittest.TestCase):
    """ieee1364-audit's table-of-contents reader, on synthetic text (no PDF)."""

    def test_namespace_page_anchor_and_informative_distinction(self):
        text = ("Contents\n1. Overview ........ 1\n1.1 Scope ........ 1\n"
                "Annex I (informative) Bibliography ........ 2\f"
                "1. Overview\n1.1 Scope\fAnnex I\n(informative)\f")
        rows = worklist(text)
        self.assertEqual([r["id"] for r in rows],
                         ["IEEE1364-2005:1", "IEEE1364-2005:1.1", "IEEE1364-2005:I"])
        self.assertEqual(rows[0]["pdf_page"], 2)
        self.assertEqual(rows[-1]["classification"], "informative")
        self.assertTrue(all(r["heading_located"] for r in rows))
        self.assertTrue(all(r["rule_review"] == "not-assessed" for r in rows))

    def test_missing_anchor_is_not_verified(self):
        text = ("Contents\n1. Overview ........ 1\n1.2 Missing ........ 1\n"
                "Annex I (informative) Bibliography ........ 2\f"
                "1. Overview\fAnnex I\f")
        self.assertFalse(worklist(text)[1]["heading_located"])

    def test_incomplete_toc_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            worklist("Contents\n1. Overview ........ 1\f1. Overview\f")

    def test_known_contents_error_keeps_original_page(self):
        pages = [""] * 215
        pages[0] = ("Contents\n1. Overview ........ 1\n"
                    "14.2.1 Module path restrictions ........ 212\n"
                    "Annex I (informative) Bibliography ........ 214")
        pages[1] = "1. Overview"
        pages[213] = "14.2.1 Module path restrictions"
        pages[214] = "Annex I"
        row = worklist("\f".join(pages))[1]
        self.assertEqual(row["toc_printed_page"], 212)
        self.assertEqual(row["printed_page"], 213)
        self.assertEqual(row["pdf_page"], 214)
        self.assertTrue(row["heading_located"])

    def test_deprecated_is_not_silently_normative_or_closed(self):
        text = ("Contents\n1. Overview ........ 1\n21. Removed ........ 2\n"
                "Annex I (informative) Bibliography ........ 3\f"
                "1. Overview\f21. Removed\fAnnex I\f")
        self.assertEqual(worklist(text)[1]["classification"], "deprecated-removed")


class KeywordInventory(unittest.TestCase):
    """keywords: the independent inventory and its fixture generator."""

    def test_table_b1_is_whole_and_corrected(self):
        self.assertEqual(len(VAMS_KEYWORDS), 215)
        self.assertTrue({"negedge", "nmos"} <= VAMS_KEYWORDS)
        self.assertNotIn("negedgenmos", VAMS_KEYWORDS)

    def test_escaped_generation_terminates_names_and_pins_observation_count(self):
        source = keyword_fixture(['analog', 'if'], 'escaped')
        self.assertIn('//! checks 2\n', source)
        self.assertIn('real \\analog ;', source)
        self.assertIn('observed = \\if ;', source)
        self.assertLess(source.index('\\if  = 2.0;'), source.index('observed ='))
        self.assertIn('`CHECKX("escaped if", observed, 2.0);', source)
        self.assertEqual(source.count('`CHECKX('), 2)

    def test_case_variants_have_independent_values(self):
        source = keyword_fixture(['analog', 'if'], 'case')
        self.assertIn('//! checks 4\n', source)
        for name, value in [('ANALOG', 1), ('Analog', 2), ('IF', 3), ('If', 4)]:
            self.assertIn(f'{name} = {value}.0;', source)
            self.assertIn(f'observed = {name};', source)
        self.assertLess(source.index('If = 4.0;'), source.index('observed ='))
        self.assertEqual(source.count('`CHECKX('), 4)



def header_text(source):
    """A fixture's prose: its `//` comment lines (not `//!`), markers
    stripped, joined, so a quotation that wraps across lines reads whole."""
    lines = []
    for line in source.split("\n"):
        t = line.strip()
        if t.startswith("//") and not t.startswith("//!"):
            lines.append(t[2:].strip())
    return " ".join(lines)


def norm(text):
    text = text.replace("“", '"').replace("”", '"').replace("’", "'").replace("‘", "'").replace("—", "-").replace("–", "-")
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", text.lower())).strip()


def insert_after(lines, pred, new_lines):
    """`new_lines` after the last line `pred` accepts, or before the first
    directive when none does."""
    at = max((i for i, ln in enumerate(lines) if pred(ln)), default=None)
    if at is None:
        at = next((i - 1 for i, ln in enumerate(lines) if ln.strip().startswith("//!")), len(lines) - 1)
    return lines[: at + 1] + new_lines + lines[at + 1:]


def promote_reject_only(argv):
    """`promote-reject-only <probe stderr>`: every `ONLY-OK` fixture from a
    `benchmark -- --probe-reject-only` run gets its first `//! reject` turned
    into `//! reject-only`: it already refuses with the named error alone, so
    the stronger claim costs nothing: a refusal fixture should pin its error alone."""
    if not argv:
        print("promote-reject-only: give the probe run's stderr", file=sys.stderr)
        return 2
    done = 0
    for line in Path(argv[0]).read_text().split("\n"):
        if not line.startswith("ONLY-OK "):
            continue
        path = Path(line[len("ONLY-OK "):].strip())
        path = FIXTURES / str(path).split("/tests/conformance/tests/", 1)[-1]
        text = path.read_text()
        new, n = re.subn(r"(?m)^(\s*//!\s*)reject(\s)", r"\1reject-only\2", text, count=1)
        if n:
            path.write_text(new)
            done += 1
    print(f"promote-reject-only: {done} fixtures now refuse alone, by name")
    return 0


SUBCOMMANDS["promote-reject-only"] = promote_reject_only


def positive_fixture(path):
    if not path.is_file():
        return False
    t = path.read_text(errors="replace")
    return re.search(r"(?m)^\s*//!", t) is not None and re.search(r"(?m)^\s*//!\s*reject", t) is None


def link_neighbours(argv):
    """`link-neighbours [--apply]`: a refusal whose header names its legal
    twin in prose (`conductor.va runs`, `Fixture 08 is the legal form` with
    the file in the same directory) gets `//! neighbour <file>`. Only files
    that exist and are positive fixtures are linked; the rest are listed as
    the worklist."""
    apply = "--apply" in argv
    linked = missing = 0
    worklist = []
    for path in fixture_files("*.va", "*.v"):
        text = path.read_text(errors="replace")
        if not re.search(r"(?m)^\s*//!\s*reject", text) or re.search(r"(?m)^\s*//!\s*neighbour", text):
            continue
        names = set(re.findall(r"[\w./-]+\.va?\b", header_text(text)))
        found = []
        for name in sorted(names):
            for cand in (path.parent / name, FIXTURES / name, path.parent / Path(name).name):
                if cand != path and positive_fixture(cand):
                    rel = os.path.relpath(cand, path.parent)
                    if rel not in found:
                        found.append(rel)
                    break
        if not found:
            missing += 1
            worklist.append(str(path.relative_to(FIXTURES)))
            continue
        linked += 1
        if apply:
            lines = text.split("\n")
            lines = insert_after(lines, lambda ln: re.match(r"\s*//!\s*reject", ln), [f"//! neighbour {r}" for r in found])
            path.write_text("\n".join(lines))
    print(f"link-neighbours: {linked} refusals name a legal twin{' (linked)' if apply else ''}; {missing} do not")
    if "--list" in argv:
        print("\n".join(worklist))
    return 0


SUBCOMMANDS["link-neighbours"] = link_neighbours


class FixtureLinking(unittest.TestCase):
    def test_header_text_joins_wrapped_quotes(self):
        src = '// "The flow shall\n//  be zero."\n//! lrm 5.1\nmodule m; endmodule\n'
        self.assertEqual(norm(header_text(src)), "the flow shall be zero")

    def test_insert_after_last_matching_line(self):
        lines = ["//! lrm 5.1", "//! lrm 5.2", "//! reject E1", "module m;"]
        out = insert_after(lines, lambda ln: ln.startswith("//! lrm 5.1"), ["//! lrm 5.1:2"])
        self.assertEqual(out[1], "//! lrm 5.1:2")


def binaries(argv):
    """`[NAME=]PATH ...` -> [(name, absolute path)]; default zig-out/bin/vera."""
    out = []
    for a in argv or ["vera=zig-out/bin/vera"]:
        name, _, path = a.rpartition("=")
        out.append((name or os.path.basename(path), os.path.realpath(ROOT / path)))
    if len({n for n, _ in out}) != len(out):
        die("name each binary: NAME=PATH")
    return out


def bounded(cmd, cwd, timeout, as_kib=None):
    """Runs `cmd` in its own process group under `ulimit -v`; returns (exit,
    stdout, stderr, seconds). Exit is None on a timeout, which kills the group
    (`--check`'s zig child included); a signal is negative, as Popen reports it."""
    import signal
    import time
    if as_kib:
        cmd = ["sh", "-c", f'ulimit -v {as_kib}; exec "$@"', "sh", *cmd]
    t0 = time.monotonic()
    p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out, err, time.monotonic() - t0
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return None, b"", b"", time.monotonic() - t0


def determinism(argv):
    """`determinism [[NAME=]VERA ...]`: L11. `vera --emit-zig` on every .va
    fixture, per binary twice from the repo root (relative paths) and once from
    another cwd (absolute paths). Every run of every binary must give the same
    exit, the same device text byte for byte, and the same diagnostics once the
    repo's absolute path is stripped. Prints each difference; exit 1 if any."""
    import concurrent.futures
    elsewhere = tempfile.mkdtemp(prefix="vera-determinism-")
    bins = binaries(argv)
    root = str(ROOT).encode() + b"/"

    def runs(f):
        """The fixture's differences from the first run, compared here so a
        worker holds one fixture's devices at a time."""
        d = os.path.dirname(f)
        rel = ["--emit-zig", "-I", "tests/conformance/tests/include", "-I", d, f]
        abs_ = ["--emit-zig", "-I", str(INCLUDE), "-I", str(ROOT / d), str(ROOT / f)]
        ref, diffs = None, []
        for bname, vera in bins:
            for label, args, cwd in (("a", rel, ROOT), ("b", rel, ROOT), ("cwd", abs_, elsewhere)):
                rc, dev, err, _ = bounded([vera, *args], cwd, 120)
                o = (f"{bname}/{label}", rc, dev, err.replace(root, b""))
                if ref is None:
                    ref = o
                    continue
                what = [k for k, i in (("exit", 1), ("device text", 2), ("diagnostics", 3)) if o[i] != ref[i]]
                if not what:
                    continue
                k = 2 if "device text" in what else 3
                ud = difflib.unified_diff(ref[k].decode("utf-8", "replace").splitlines(), o[k].decode("utf-8", "replace").splitlines(),
                                          ref[0], o[0], n=0, lineterm="")
                diffs.append(f"{f}: {o[0]} vs {ref[0]}: {', '.join(what)} differ (exit {o[1]} vs {ref[1]})\n"
                             + "\n".join(list(ud)[:12]))
        return diffs

    fixtures = [str(p.relative_to(ROOT)) for p in fixture_files("*.va")]
    with concurrent.futures.ThreadPoolExecutor(4) as pool:  # one vera per worker
        diffs = [d for ds in pool.map(runs, fixtures) for d in ds]
    for d in diffs:
        print(d)
    runs_n = len(fixtures) * len(bins) * 3
    print(f"determinism: {len(fixtures)} fixtures x {len(bins)} binaries x 3 runs = {runs_n}; "
          f"{len(diffs)} run(s) differ from {bins[0][0]}/a", file=sys.stderr)
    return 1 if diffs else 0


SUBCOMMANDS["determinism"] = determinism


class FixtureLayoutTests(unittest.TestCase):
    """The path relationships discovery and coverage depend on."""

    def test_host_and_vpi_designs_exist(self):
        # A host's `//! device` is relative to the suite root, or to the
        # repository's for a `tests/host/...` device only VerA's host judges
        # (build.zig `hostTests`); a `.c`'s `//! design` to the `.c`'s own
        # directory.
        missing = []
        for path in sorted((ROOT / "tests/host").glob("*.zig")) + fixture_files("*.c"):
            key, base = ("design", path.parent) if path.suffix == ".c" else ("device", SUITE)
            for rel in re.findall(rf"(?m)^//! {key} (.+)$", path.read_text()):
                rel = rel.strip()
                at = ROOT if key == "device" and rel.startswith("tests/host/") else base
                if not (at / rel).is_file():
                    missing.append(f"{path.relative_to(ROOT)}: {rel}")
        self.assertEqual(missing, [])

    def test_ch12_no_numbered_hdl_fixture_claims_vpi_execution(self):
        for path in FIXTURES.glob("*/ch12_vpi_routines/[0-9]*.va"):
            with self.subTest(path=path.name):
                self.assertNotRegex(path.read_text(), r"(?m)^//! lrm 12(?:\.|$)")

    def test_legal_neighbours_exist(self):
        missing = []
        for path in fixture_files("*.va", "*.v"):
            for rel in re.findall(r"(?m)^\s*//! neighbour (.+)$", path.read_text()):
                if not (path.parent / rel).is_file():
                    missing.append(f"{path.relative_to(FIXTURES)}: {rel}")
        self.assertEqual(missing, [])

    def test_spice_models_exist_at_the_declared_relative_path(self):
        missing = []
        for path in fixture_files("*.sp", roots=AMS_ROOTS):
            for rel in re.findall(r'(?im)^\s*\.hdl\s+"([^"]+)"', path.read_text()):
                if not (path.parent / rel).is_file():
                    missing.append(f"{path.relative_to(FIXTURES)}: {rel}")
        self.assertEqual(missing, [])

    def test_spice_oracle_hashes_match_the_deck(self):
        for path in fixture_files("*.sp", roots=AMS_ROOTS):
            oracle = path.with_suffix(".expected.json")
            if not oracle.exists():
                continue
            expected = json.loads(oracle.read_text()).get("netlist_sha256")
            if expected:
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected, str(path))

    def test_digital_goldens_have_a_source(self):
        missing = []
        for path in fixture_files("*.expected.txt"):
            stem = path.name.removesuffix(".expected.txt")
            if not path.with_name(stem + ".v").is_file():
                missing.append(str(path.relative_to(FIXTURES)))
        self.assertEqual(missing, [])



def selftest(argv):
    """Run the regression checks above (`unittest` arguments pass through,
    e.g. `selftest -v` or `selftest SourceFigures`)."""
    sys.dont_write_bytecode = True
    program = unittest.main(module=sys.modules[__name__], argv=["conformance.py selftest"] + argv, exit=False)
    return 0 if program.result.wasSuccessful() else 1


SUBCOMMANDS["selftest"] = selftest


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
