#!/usr/bin/env python3
"""How conformant VerA is to the specification, measured — never typed.

    tools/conformance.py run                  # execute suites; report fresh fixture and specialized evidence
    tools/conformance.py                      # print the measures block (A, B, C)
    tools/conformance.py --changelog v0.1.0   # set the version literals, prepend it to CHANGELOG.md
    tools/conformance.py --check v0.1.0       # check them, re-measure and diff vs CHANGELOG.md
    tools/conformance.py <subcommand> [...]   # one of the signals below

`run` writes the execution report (one fresh directory under
`.zig-cache/conformance/`: suite logs, results, `report.md`, `report.json`);
the older A/B/C release measures below retain their historical meaning (B
and C inventory citations).
Every number comes from a command in this file. There is no second place a
percentage is written down, which is the point: v1.0.0 is defined
as four measures, and three of them are machine-readable today. Only the
measures block may write A, B and C; every subcommand is a separate signal and
none of them changes the block or CHANGELOG.md:

    comments        clauses the code cites or refuses vs the fixtures' tags
    tally-b         CLAUSE-AUDIT.md §7.1's §§17-18 obligation arithmetic
    lrm-audit       the LRM PDF against specification/*.html, section by section
    ieee1364-audit  the IEEE 1364-2005 heading worklist (licensed local PDF)
    keywords        Table B.1 against the PDF, and its spelling fixtures
    figures         re-crop the LRM figures in specification/figures from the PDF
    verilator       Verilator as a second engine on the same .v designs
    adversarial     L10 sizes through `vera --check` under a time and memory cap
    determinism     L11: `--emit-zig` device text across runs, cwds and binaries
    grammar         the R3 oracle: Syntax boxes to BNF (tests/fixtures/conformance/GRAMMAR.tsv), an Earley
                    recognizer, R3 coverage, and VerA's parse vs the recognizer
    selftest        regression checks: the subcommands, the LRM text, `run`'s
                    accounting and the fixture layout

ponytail: a regex over the suite's own report, not a --json flag on suite.zig.
Both lines parsed here are already machine-shaped — the `pass fail unasserted
xfail` TSV row (tests/suite.zig) and the coverage tally (its `Coverage`
namespace). If a third consumer ever wants this, add the JSON then.
"""
import argparse
import ast
from collections import Counter
import datetime
import difflib
import hashlib
import html
import importlib.util
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import time
import unicodedata
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures"


def fixture_files(*patterns):
    """Every fixture matching one of `patterns`, sorted. `canary/` holds the
    wrong-on-purpose fixtures the canary in `zig build test` judges on their own;
    they are evidence of nothing, so no walk sees them."""
    return sorted(p for pattern in patterns for p in FIXTURES.rglob(pattern)
                  if p.is_file() and "canary" not in p.relative_to(FIXTURES).parts)

# name -> function(argv) -> exit code. Each section below adds its own.
SUBCOMMANDS = {}


def execution_report(argv):
    try:
        return run_suites(argv)
    except (ValueError, OSError) as error:
        die(str(error))


SUBCOMMANDS["run"] = execution_report


# ---------------------------------------------------------------------------
# run: execution-backed coverage, one fresh report per run
# ---------------------------------------------------------------------------

STATUSES = {"pass", "fail", "skip", "xfail", "unasserted"}
SPECIAL_COLUMNS = ("id", "source", "artifact", "test", "standard", "citation", "polarity", "description")


def read_results(path):
    """Reject ambiguous data rather than letting the last duplicate win."""
    results = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        status, sep, name = line.partition("\t")
        if not sep or status not in STATUSES or not name or "\t" in name:
            raise ValueError(f"{path}:{number}: invalid result row")
        if name in results:
            raise ValueError(f"{path}:{number}: duplicate result: {name}")
        results[name] = status
    return results


def merge_results(*tables):
    result = {}
    for table in tables:
        for name, status in table.items():
            if name in result:
                raise ValueError(f"test executed by multiple fixture runners: {name}")
            result[name] = status
    return result


def require_results(results, expected, label):
    missing = sorted(set(expected) - results.keys())
    if missing:
        raise ValueError(f"{label} succeeded without recording {len(missing)} results: {', '.join(missing[:5])}")


def assertion_validation(run_dir, normal):
    """Keep perturbed verdicts separate from ordinary execution evidence."""
    path = run_dir / "ams-perturbed.tsv"
    results = read_results(path) if path.exists() else {}
    unknown = sorted(results.keys() - normal.keys())
    if unknown:
        raise ValueError(f"assertion validation has no matching normal execution: {', '.join(unknown[:5])}")
    return results


def read_specialized(root, clauses, ledger):
    rows, ids, checks = [], set(), {}
    path = root / "tests/fixtures/conformance/SPECIALIZED.tsv"
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        cells = line.split("\t")
        if len(cells) != len(SPECIAL_COLUMNS):
            raise ValueError(f"{path}:{number}: expected {len(SPECIAL_COLUMNS)} columns")
        row = dict(zip(SPECIAL_COLUMNS, cells))
        identity = (row["id"], row["standard"], row["citation"], row["polarity"])
        if identity in ids:
            raise ValueError(f"{path}:{number}: duplicate specialized citation")
        ids.add(identity)
        check = (row["source"], row["artifact"], row["test"])
        if row["id"] in checks and checks[row["id"]] != check:
            raise ValueError(f"{path}:{number}: id names different checks")
        checks[row["id"]] = check
        source = (root / row["source"]).resolve()
        if not source.is_relative_to(root.resolve()) or not source.is_file():
            raise ValueError(f"{path}:{number}: missing or invalid source")
        # Exact test name, not a file-level claim or a substring of another test.
        if source.suffix == ".sp":
            declared = (row["artifact"] == "spice" and
                        row["test"] == row["source"].removeprefix("tests/fixtures/") and
                        source.with_suffix(".expected.json").is_file())
        elif source.suffix == ".py":
            declared = any(isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == row["test"]
                           for node in ast.walk(ast.parse(source.read_text())))
        else:
            declaration = (rf"(?m)^\s*// evidence: (?:pass|xfail) {re.escape(row['test'])}$"
                           if source.suffix == ".c" else
                           rf'\btest\s+{re.escape(json.dumps(row["test"], ensure_ascii=False))}\s*\{{')
            declared = bool(re.search(declaration, source.read_text()))
        if not declared:
            raise ValueError(f"{path}:{number}: test not declared in {row['source']}: {row['test']}")
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", row["artifact"]):
            raise ValueError(f"{path}:{number}: invalid artifact")
        clause = row["citation"].partition(":")[0]
        if (row["standard"], clause) not in clauses or row["polarity"] not in ("pos", "neg"):
            raise ValueError(f"{path}:{number}: invalid clause or polarity")
        if ":" in row["citation"]:
            obligation = ledger.get(row["citation"]) if row["standard"] == "ams" else None
            if obligation is None or (row["polarity"] == "pos" and obligation["pol"] == "-") or (
                row["polarity"] == "neg" and obligation["pol"] == "+"
            ):
                raise ValueError(f"{path}:{number}: unknown or contradictory sentence citation")
        if not row["description"]:
            raise ValueError(f"{path}:{number}: describe what the assertion checks")
        rows.append(row)
    return rows


def specialized_status(row, artifacts):
    """Only the named test in the named executable can establish coverage."""
    tests = artifacts.get(row["artifact"], {})
    matches = [status for name, status in tests.items()
               if name.endswith(".test." + row["test"])]
    if len(matches) > 1:
        raise ValueError(f"ambiguous specialized test {row['id']}")
    return matches[0] if matches else "not-run"


def require_specialized_results(rows, artifacts):
    missing = sorted({row["id"] for row in rows if specialized_status(row, artifacts) == "not-run"})
    if missing:
        raise ValueError(f"unit suite succeeded without recording specialized tests: {', '.join(missing)}")


def read_dispositions(root):
    """{(standard, clause): disposition} from the GAPS.tsv review inventory.

    Only whole-clause rows are useful here. Sentence rows (`3.4.1:1`) are a
    different worklist and never make a clause not-applicable."""
    path = root / "tests/fixtures/conformance/GAPS.tsv"
    out = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        cells = line.split("\t")
        if len(cells) < 4:
            raise ValueError(f"{path}:{number}: expected standard, citation, baseline and disposition")
        standard, citation, _, disposition = cells[:4]
        if standard not in ("ams", "ieee") or ":" in citation:
            continue
        out[(standard, citation)] = disposition
    return out


def clause_results(clauses, citations, results, dispositions=None):
    dispositions = dispositions or {}
    rows = []
    for (standard, clause), info in sorted(clauses.items()):
        evidence = []
        for item in citations.get((standard, clause), []):
            evidence.append(dict(item, status=results.get(item["test"], "not-run")))
        passed = [item for item in evidence if item["status"] == "pass"]
        failed = [item for item in evidence if item["status"] in ("fail", "xfail")]
        disposition = dispositions.get((standard, clause), "")
        # A failure remains visible even if another test for the clause passes.
        if failed:
            state = "failing"
        elif info["classification"] == "not-supported":
            state = "unsupported"
        elif passed:
            state = "covered"
        elif disposition == "no-fixed-oracle":
            # A non-normative/optional heading or explicitly unspecified
            # behavior. There is no unconditional outcome for a test to assert,
            # so this is not a missing test and not a failure.
            state = "not-applicable"
        elif evidence:
            state = "not-run"
        else:
            state = "uncovered"
        rows.append(dict(standard=standard, clause=clause, **info, status=state,
                         disposition=disposition,
                         fixture=any(item["kind"] == "fixture" for item in passed),
                         specialized=any(item["kind"] == "specialized" for item in passed),
                         positive=any(item["polarity"] == "pos" for item in passed),
                         negative=any(item["polarity"] == "neg" for item in passed),
                         evidence=evidence))
    return rows


def feature_groups(path, known_tests, results):
    """Measure the explicit work breakdown, without inventing a language taxonomy."""
    rows, ids, assigned = [], set(), set()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        cells = line.split("\t")
        if len(cells) != 3 or not all(cells):
            raise ValueError(f"{path}:{number}: expected id, description and evidence")
        identity, description, names = cells
        if identity in ids:
            raise ValueError(f"{path}:{number}: duplicate behavior group: {identity}")
        ids.add(identity)
        checks = []
        for name in names.split(";"):
            if name not in known_tests:
                raise ValueError(f"{path}:{number}: unknown test: {name}")
            if name in assigned:
                raise ValueError(f"{path}:{number}: test assigned more than once: {name}")
            assigned.add(name)
            checks.append({"test": name, "status": results.get(name, "not-run")})
        states = {check["status"] for check in checks}
        state = ("failing" if states & {"fail", "xfail"} else
                 "covered" if states == {"pass"} else "not-run")
        rows.append({"id": identity, "description": description, "status": state, "evidence": checks})
    return rows


def source_digest(root):
    """Content identity includes new files and uncommitted edits, not just HEAD."""
    digest = hashlib.sha256()
    paths = [root / name for name in ("build.zig", "build.zig.zon", "flake.nix", "flake.lock")]
    for directory in ("lib", "src", "tools", "tests", "specification"):
        paths.extend(p for p in (root / directory).rglob("*")
                     if p.is_file() and "__pycache__" not in p.parts)
    for path in sorted(paths):
        digest.update(path.relative_to(root).as_posix().encode() + b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def clause_inventory():
    # Match the established AMS clause denominator: numeric chapter headings
    # organize their sections; annex headings are themselves inventoried.
    clauses = {("ams", key): {"title": value["title"], "classification": "-"}
               for key, value in html_sections(ROOT)[0].items() if not key.isdigit()}
    for line in (FIXTURES / "ieee1364/CLAUSES.tsv").read_text().splitlines():
        if line and not line.startswith("#"):
            clause, kind, title, *_ = line.split("\t")
            clauses["ieee", clause] = {"title": title, "classification": kind}
    for key, kind in clause_kinds().items():
        if key not in clauses:
            raise ValueError(f"classification names an unknown clause: {key}")
        clauses[key]["classification"] = kind
    return clauses


def collect_report(run_dir, suites):
    clauses, ledger = clause_inventory(), read_ledger()
    special = read_specialized(ROOT, clauses, ledger)
    artifacts = {p.stem: read_results(p) for p in sorted((run_dir / "tests").glob("*.tsv"))}
    ams_path = run_dir / "ams.tsv"
    ams_results = read_results(ams_path) if ams_path.exists() else {}
    perturbed = assertion_validation(run_dir, ams_results)
    digital_path = run_dir / "digital.tsv"
    fixtures = merge_results(ams_results, read_results(digital_path) if digital_path.exists() else {})
    # C markers are written only after build.zig checks the application's
    # exit, stdout and stderr. A declaration alone is never a passing result.
    c_results = merge_results(*(table for name, table in artifacts.items() if name.startswith("vpi--")))
    fixtures = merge_results(fixtures, c_results)
    for path in fixtures:
        if not (FIXTURES / path).is_file():
            raise ValueError(f"result names a missing fixture: {path}")
    citations = {}
    for (standard, citation), polarities in fixture_cites().items():
        clause = citation.partition(":")[0]
        if (standard, clause) not in clauses:
            raise ValueError(f"unknown fixture citation: {standard} {citation}")
        for polarity, paths in polarities.items():
            for path in paths:
                test = path.removeprefix("tests/fixtures/")
                item = {"test": test, "kind": "specialized" if test.endswith(".c") else "fixture",
                        "polarity": polarity}
                items = citations.setdefault((standard, clause), [])
                if item not in items:
                    items.append(item)
    results = dict(fixtures)
    special_results = {}
    tags = {str(p.relative_to(FIXTURES)): fixture_tags(p) for p in fixture_files("*.va", "*.v", "*.c")}
    for row in special:
        key = "specialized:" + row["id"]
        state = specialized_status(row, artifacts)
        if key in special_results and special_results[key] != state:
            raise ValueError(f"inconsistent specialized id {row['id']}")
        special_results[key] = results[key] = state
        clause = row["citation"].partition(":")[0]
        citations.setdefault((row["standard"], clause), []).append(
            {"test": key, "kind": "specialized", "polarity": row["polarity"],
             "source": row["source"], "assertion": row["test"], "description": row["description"]})
        if row["standard"] == "ams":
            tag = tags.setdefault(key, {"cites": [], "c": False, "only": False,
                                        "neighbours": [], "golden": False, "specialized": True})
            tag["cites"].append((row["citation"], row["polarity"]))
    # E2 is measured execution, not proof that every requirement is tested.
    # Specialized assertions count as E3 only with an explicit sentence cite.
    rows, unattributed = levels(ledger, tags, results, perturbed, set(), {})
    mandatory = {rid: level for rid, level in rows.items() if ledger[rid]["kind"] in MANDATORY_KINDS}
    return {
        "schema": 1,
        "suites": suites,
        "fixture_results": fixtures,
        "fixture_counts": dict(Counter(fixtures.values())),
        "assertion_validation_results": perturbed,
        "assertion_validation_counts": dict(Counter(perturbed.values())),
        "specialized_results": special_results,
        "specialized_counts": dict(Counter(special_results.values())),
        "specialized_checks": {row["id"]: dict(row, status=special_results["specialized:" + row["id"]])
                               for row in special},
        "spice_counts": dict(Counter(artifacts.get("spice", {}).values())),
        "unit_execution_counts": dict(Counter(v for k, table in artifacts.items()
                                               if not k.startswith("vpi--") and k != "spice"
                                               for v in table.values())),
        "feature_groups": feature_groups(ROOT / "tests/fixtures/conformance/FEATURE_GAPS.tsv",
                                         tags.keys() | special_results.keys(), results),
        "clauses": clause_results(clauses, citations, results, read_dispositions(ROOT)),
        "ams_obligations": {"total": len(ledger), "mandatory": len(mandatory),
                            "levels": dict(Counter(mandatory.values())),
                            "rows": rows, "unattributed_failures": unattributed},
    }


def markdown(report):
    lines = ["# Conformance results", "",
             f"Measured {report['measured_at']} at `{report['commit']}`.",
             f"Source SHA-256: `{report['source_sha256']}`.", "",
             "Coverage means a passing test exercises a cited clause. It does not mean every",
             "rule or possible program in that clause conforms. Failure takes precedence",
             "when passing and failing tests cite the same clause.", "",
             "| Execution | Pass | Fail | XFAIL | Skip | Unasserted | Not run |",
             "|---|---:|---:|---:|---:|---:|---:|"]
    for label, key in (("Fixtures and VPI applications", "fixture_counts"),
                       ("AMS assertion perturbations", "assertion_validation_counts"),
                       ("SPICE decks", "spice_counts"),
                       ("Specialized checks", "specialized_counts"),
                       ("Named test executions", "unit_execution_counts")):
        counts = report[key]
        lines.append(f"| {label} | " + " | ".join(str(counts.get(s, 0)) for s in
                     ("pass", "fail", "xfail", "skip", "unasserted", "not-run")) + " |")
    lines += ["", "Specialized checks are also present in the execution totals; do not add these rows.",
              "Perturbation passes mean changed expected values were rejected. They never replace",
              "normal execution; only matching passing normal assertions can gain evidence.", "",
              "| Standard | All clauses | Covered | Failing | Unsupported | Not run | Uncovered | No fixed oracle | With fixture evidence | With specialized evidence |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    classifications = []
    no_fixed = []
    for standard, label in (("ams", "Verilog-AMS 2023"), ("ieee", "IEEE 1364-2005")):
        rows = [r for r in report["clauses"] if r["standard"] == standard]
        states = Counter(r["status"] for r in rows)
        lines.append(f"| {label} | {len(rows)} | " + " | ".join(str(states[s]) for s in
                     ("covered", "failing", "unsupported", "not-run", "uncovered", "not-applicable")) +
                     f" | {sum(r['fixture'] for r in rows)} | {sum(r['specialized'] for r in rows)} |")
        classes = Counter(r["classification"] for r in rows)
        classifications.append(f"{label} classifications (included in the denominator): " +
                               ", ".join(f"{kind}: {count}" for kind, count in sorted(classes.items())) + ".")
        if states["not-applicable"]:
            no_fixed.append(f"{label}: {states['not-applicable']}")
    lines += ["", "**Uncovered** counts only clauses with a testable requirement. **No fixed oracle**",
              "counts the clauses GAPS.tsv dispositions as non-normative, optional or explicitly",
              "unspecified; no unconditional executable outcome exists for them, so they are not",
              "missing tests and not conformance failures. Their rows remain in the denominator."]
    if no_fixed:
        lines.append("No fixed oracle clauses (per GAPS.tsv): " + "; ".join(no_fixed) + ".")
    lines += ["", "Unsupported clauses retain their classification even when a rejection test passes.",
              "Evidence columns overlap and include passing checks on failing or unsupported clauses.", "",
              *classifications]
    groups = report["feature_groups"]
    states = Counter(row["status"] for row in groups)
    lines += ["", f"Tracked behavior groups: {states['failing']} failing, {states['covered']} covered, "
              f"{states['not-run']} not run.",
              "These groups are defined in tests/fixtures/conformance/FEATURE_GAPS.tsv, not an exhaustive",
              "language feature count. A group is covered only when every registered check passes.",
              "Pending host profiles and unmeasured requirements remain in GAPS.tsv.", "",
              "| Behavior group | Status | Checks |", "|---|---|---:|"]
    lines += [f"| {row['description']} | {row['status']} | {len(row['evidence'])} |" for row in groups]
    failures = [row for row in report["specialized_checks"].values() if row["status"] in ("fail", "xfail")]
    if failures:
        lines += ["", "| Specialized failure | Status | Assertion |", "|---|---|---|"]
        lines += [f"| {row['id']} | {row['status']} | {row['description']} |" for row in failures]
    obligations = report["ams_obligations"]
    lines += ["", f"AMS sentence ledger: {obligations['mandatory']} mandatory of {obligations['total']} rows.",
              "Evidence levels: " + ", ".join(f"{k}={obligations['levels'].get(k, 0)}"
                                             for k in ("E0", "E1", "E2", "E3", "E4", "E5", "F")) + ".",
              "E0: no citation; E1: cited; E2: executed; E3: required polarities have discriminating checks.",
              "E4 adds a reviewed independent oracle; E5 additionally requires mutation evidence.",
              "Historical execution and mutation results are not imported by this run.", "",
              f"Failures cited to a clause without an exact sentence: {len(obligations['unattributed_failures'])}.", "",
              *[f"- {clause}: {', '.join(paths)}" for clause, paths in obligations["unattributed_failures"].items()],
              "", "IEEE coverage uses clauses: no sentence ledger exists for that standard.", "",
              "Exit status preserves each suite's gate. The strict AMS suite exits nonzero",
              "on expected failures; other suites retain declared XFAILs without failing",
              "their development gate. Unexpected failures and missing evidence fail the run.", "",
              "| Suite | Exit | Log |", "|---|---:|---|"]
    lines += [f"| {s['name']} | {s['exit']} | [{s['name']}.log]({s['name']}.log) |" for s in report["suites"]]
    lines += ["", "Full test-to-clause evidence, classifications, and sentence levels: [report.json](report.json).", ""]
    return "\n".join(lines)


def run_suites(argv):
    """`run`: execute the principal suites into a fresh directory under
    `--output` and write the execution-backed report (`report.md`,
    `report.json`). The sentence ledger and the fixture directives remain
    the source of requirements; every result, specialized tests included,
    comes from this run."""
    parser = argparse.ArgumentParser(prog="conformance.py run", description=run_suites.__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".zig-cache/conformance")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args(argv)
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-"),
                                  dir=args.output)).resolve()
    (run_dir / "tests").mkdir()
    before = source_digest(ROOT)
    clauses = clause_inventory()
    special = read_specialized(ROOT, clauses, read_ledger())
    build = ([] if os.environ.get("IN_NIX_SHELL") else ["nix", "develop", "-c"]) + ["zig", "build"]
    commands = [
        ("infrastructure", [sys.executable, "tests/host.py", "selftest"]),
        ("accounting", [sys.executable, "tools/conformance.py", "selftest",
                        "EvidenceTests", "GapInventoryTests", "FixtureLayoutTests"]),
        ("unit", build + ["test", f"-j{args.jobs}", f"-Dtest-results={run_dir / 'tests'}", "--summary", "all"]),
        ("ams", build + ["suite", f"-j{args.jobs}", "--", "ams", f"--jobs={args.jobs}", f"--verdicts={run_dir / 'ams.tsv'}"]),
        ("ams-perturbed", build + ["suite", f"-j{args.jobs}", "--", "ams", f"--jobs={args.jobs}", "--perturb",
                                  f"--verdicts={run_dir / 'ams-perturbed.tsv'}"]),
        ("digital", build + ["suite", f"-j{args.jobs}", "--", "devices", f"--verdicts={run_dir / 'digital.tsv'}"]),
        ("vpi-abi", build + ["suite", f"-j{args.jobs}", "--", "vpi"]),
        # The decks run on ESPice built against the tree under test.
        ("spice", build + ["test-spice", "--fork", ".", f"-j{args.jobs}", "--",
                          f"--results={run_dir / 'tests/spice.tsv'}"]),
    ]
    suites = []
    for name, command in commands:
        print(f"conformance: {name} → {run_dir / (name + '.log')}", flush=True)
        start = time.monotonic()
        # Zig subprocesses can write stderr at explicit offsets. O_APPEND
        # keeps their diagnostics from overwriting another process's log.
        with (run_dir / f"{name}.log").open("a") as log:
            completed = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        suites.append({"name": name, "command": command, "exit": completed.returncode,
                       "seconds": round(time.monotonic() - start, 3)})
        print(f"conformance: {name} exit {completed.returncode}", flush=True)
        if name in ("ams", "ams-perturbed", "digital") and completed.returncode == 0:
            verdicts = run_dir / f"{name}.tsv"
            if not verdicts.exists() or not read_results(verdicts):
                raise ValueError(f"{name} reported success without any verdicts; see {run_dir}")
            if name == "ams-perturbed":
                normal_path = run_dir / "ams.tsv"
                normal = read_results(normal_path) if normal_path.exists() else {}
                validation = assertion_validation(run_dir, normal)
                require_results(validation, normal, "AMS assertion validation")
        if name == "unit" and completed.returncode == 0:
            vpi = merge_results(*(read_results(p) for p in (run_dir / "tests").glob("vpi--*.tsv")))
            require_results(vpi, vpi_runs(), "VPI applications")
            require_specialized_results([row for row in special if row["artifact"] not in ("spice", "diagnostic_observations")],
                                        {p.stem: read_results(p) for p in (run_dir / "tests").glob("*.tsv")})
        if name == "spice" and completed.returncode == 0:
            path = run_dir / "tests/spice.tsv"
            expected = {"spice.test." + p.relative_to(FIXTURES).as_posix()
                        for p in FIXTURES.rglob("*.sp")
                        if not p.is_relative_to(FIXTURES / "external")}
            require_results(read_results(path) if path.exists() else {}, expected, "SPICE decks")
        # `test` runs the diagnostic observations too, into the same results directory.
        if name == "unit" and completed.returncode == 0:
            path = run_dir / "tests/diagnostic_observations.tsv"
            require_specialized_results(
                [row for row in special if row["artifact"] == "diagnostic_observations"],
                {"diagnostic_observations": read_results(path) if path.exists() else {}},
            )
    if source_digest(ROOT) != before:
        raise ValueError(f"source changed during the run; logs retained at {run_dir}, no mixed-version report written")
    report = collect_report(run_dir, suites)
    report.update(measured_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                  source_sha256=before)
    (run_dir / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    (run_dir / "report.md").write_text(markdown(report))
    print(markdown(report))
    print(f"conformance: report {run_dir / 'report.md'}", flush=True)
    bad = ("fail", "unasserted")
    return int(any(s["exit"] for s in suites) or
               any(report["fixture_counts"].get(status, 0) or report["specialized_counts"].get(status, 0)
                   for status in bad))


def die(msg):
    print(f"conformance.py: {msg}", file=sys.stderr)
    sys.exit(2)


def run(*argv):
    """`$(argv 2>&1)` and its exit status."""
    p = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.stdout.decode("utf-8", "replace").rstrip("\n"), p.returncode


def quiet(*argv):
    """`argv >/dev/null 2>&1 && echo pass || echo FAIL`."""
    rc = subprocess.run(argv, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    return "pass" if rc == 0 else "FAIL"


def is_num(s):
    return re.fullmatch(r"[0-9]+", s or "") is not None


def polarity(text):
    """The four polarity counts, in report order. A fifth number joins the
    fourth field, as `read -r a b c d` would, and so fails `is_num`."""
    found = re.findall(r"\d+(?= (?:cited both ways|positive citations only|rejection citations only|uncited))", text)
    return (found + ["", "", "", ""])[:3] + [" ".join(found[3:])]


def first(pattern, text):
    m = re.search(pattern, text, re.M)
    return m.group(1) if m else ""


def pct(n, d):
    return "n/a" if d == 0 else "%.1f%%" % (100 * n / d)


SUITE = ROOT / "tests" / "conformance"
SCORED = (("verilog-a", "Verilog-A"), ("verilog", "Verilog"), ("verilog-ams", "Verilog-AMS"))


def suite_scores(rows):
    """`zig-out/conformance.tsv` rows (status, test name, ...) -> {category:
    (passed, total)}, by the suite's own categories (its tools/report.py): a
    test's language is its directory under tests/ or its manifest row's first
    column. XFAIL counts as a fail and XPASS as a pass; a skip counts against."""
    sys.path.insert(0, str(SUITE / "tools"))
    import report as suite_report
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
# tally-b: CLAUSE-AUDIT.md §7.1's inherited §§17-18 obligation table
# ---------------------------------------------------------------------------

def tally_b(argv):
    """Re-add CLAUSE-AUDIT.md §7.1's table and fail if the per-section rows stop
    summing to the total, or closed + open stops summing to the row count.

    B is the one measure with no suite behind its §§17-18 detail: those
    obligations are outside `--coverage`'s denominator by construction
    (CLAUSE-AUDIT.md §1.1 c), so the rows are hand-read. What CAN be checked is
    the arithmetic, and that is this check's whole job. It answers "is the
    hand-read tally self-consistent?", not "is it right?": re-deriving the rows
    is reading. Never report it as a measurement.

    ponytail: a split on `|` over the one table, not a markdown parser. The
    table is pinned by its header row, so a reshuffle of §7 cannot silently
    match the wrong one.
    """
    doc = ROOT / "specification/CLAUSE-AUDIT.md"
    if not os.access(doc, os.R_OK):
        print(f"tally-b: {doc} is missing (it was deleted once: 2cc1c08)", file=sys.stderr)
        return 2

    def cells(fields):
        """Columns Rows..unspecified as numbers: digits only, a dash is 0."""
        out = []
        for i in range(2, 9):
            digits = re.sub(r"[^0-9]", "", fields[i]) if i < len(fields) else ""
            out.append(int(digits) if digits else 0)
        return out

    intable, rows, verdicts, trows, tsum, closed, opened = False, 0, 0, 0, 0, 0, 0
    per, bad = [], []
    for line in doc.read_text().split("\n"):
        fields = line.split("|")
        if re.match(r"^\| Section \| Rows \| missing \|", line):
            intable = True
            continue
        if intable and line.startswith("| **Total**"):
            v = cells(fields)
            trows, tsum, intable = v[0], sum(v[1:]), False
            continue
        if intable and line.startswith("| §4"):
            v = cells(fields)
            rows += v[0]
            verdicts += sum(v[1:])
            per.append(f"{fields[1]}  rows={v[0]}  verdicts={sum(v[1:])}")
            if v[0] != sum(v[1:]):
                bad.append(per[-1])
        if line.startswith("| **closed** |"):
            closed = cells(fields)[0]
        if line.startswith("| **open** |"):
            opened = cells(fields)[0]

    rc = 0
    for p in per:
        print("  " + p)
    print(f"\n  section rows       {rows}\n  section verdicts   {verdicts}\n  stated total       {trows} / {tsum}")
    print(f"  closed + open      {closed} + {opened} = {closed + opened}\n")
    for b in bad:
        print(f"FAIL: section does not sum: {b}")
        rc = 1
    if rows != verdicts:
        print(f"FAIL: rows {rows} != verdicts {verdicts}")
        rc = 1
    if trows != rows:
        print(f"FAIL: stated total {trows} != summed rows {rows}")
        rc = 1
    if tsum != verdicts:
        print(f"FAIL: stated verdict total {tsum} != summed {verdicts}")
        rc = 1
    if closed + opened != rows:
        print(f"FAIL: closed+open {closed + opened} != rows {rows}")
        rc = 1
    if rc == 0:
        print(f"measure B: {closed} / {rows} closed, {opened} open — tally is self-consistent")
    return rc


SUBCOMMANDS["tally-b"] = tally_b


# ---------------------------------------------------------------------------
# lrm-audit: the LRM PDF against specification/*.html, section by section
# ---------------------------------------------------------------------------

LRM_PDF = ROOT / "specification/VAMS-LRM-2023.pdf"
LRM_SHA256 = "e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134"
SECTION = re.compile(r"^((?:[1-9][0-9]?|[A-H])(?:\.[0-9]+)+)\s+(.+)$")
CHAPTER = re.compile(r"^([1-9][0-9]?)\.\s+([A-Z].+)$")
ANNEX = re.compile(r"^Annex ([A-H])(?:\s|$)")


def heading(text):
    match = SECTION.match(text) or CHAPTER.match(text) or ANNEX.match(text)
    return match.group(1) if match else None


def tokens(text):
    # Do not guess which hyphens are line-wrap artifacts: Verilog-\nAMS and
    # arithmetic a-\nb retain meaningful '-'. Compatibility normalization
    # would also erase distinctions such as superscript ² versus ordinary 2.
    # Canonical Unicode equivalence is safe for this text-token worklist;
    # ligatures, soft hyphens and typography still require explicit review.
    text = unicodedata.normalize("NFC", text)
    return re.findall(r"\w+|[^\w\s]", text)


class ChapterHTML(HTMLParser):
    """Collect headings and body text, excluding navigation/style metadata."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.sections = {}
        self.current = None
        self.skip = 0
        self.in_heading = False
        self.heading_text = []
        self.heading_line = 0
        self.duplicates = []

    def handle_starttag(self, tag, attrs):
        if tag in ("head", "nav", "script", "style"):
            self.skip += 1
        if self.skip:
            return
        if re.fullmatch(r"h[1-6]", tag):
            self.in_heading = True
            self.heading_text = []
            self.heading_line = self.getpos()[0]
        elif tag in ("p", "div", "pre", "tr", "li", "br", "figure"):
            self.append("\n")
        elif tag in ("td", "th"):
            self.append(" ")

    def handle_endtag(self, tag):
        if tag in ("head", "nav", "script", "style"):
            self.skip -= 1
            return
        if self.skip:
            return
        if re.fullmatch(r"h[1-6]", tag) and self.in_heading:
            title = "".join(self.heading_text).strip()
            section = heading(title)
            if section:
                if section in self.sections:
                    self.duplicates.append(section)
                self.current = section
                self.sections[section] = {
                    "title": title, "line": self.heading_line, "text": ""
                }
            else:
                self.append("\n" + title + "\n")
            self.in_heading = False
        elif tag in ("p", "div", "pre", "tr", "li", "figure"):
            self.append("\n")

    def append(self, text):
        if self.current:
            self.sections[self.current]["text"] += text

    def handle_data(self, text):
        if self.skip:
            return
        if self.in_heading:
            self.heading_text.append(text)
        else:
            self.append(text)


def pdf_sections(pdf):
    proc = subprocess.run(
        ["pdftotext", "-layout", str(pdf), "-"],
        capture_output=True, text=True, check=True,
    )
    sections = {}
    current = None
    chapter = None
    started = False
    duplicates = []
    for page, text in enumerate(proc.stdout.split("\f"), 1):
        lines = text.splitlines()
        # Exclude front matter/TOC using the first body heading, without dotted
        # leaders. PDF physical page indices remain attached to every section.
        if not started:
            if "1. Verilog-AMS introduction" not in lines:
                continue
            started = True
        for index, line in enumerate(lines):
            stripped = line.strip()
            if (not stripped or "Accellera Std VAMS-2023" in line
                    or "Accellera Standard for VERILOG-AMS" in line
                    or "Copyright © 2024 Accellera" in line
                    or (re.fullmatch(r"\d+", stripped) and
                        next((tail.strip() for tail in lines[index + 1:]
                              if tail.strip()), "").startswith(
                                  "Copyright © 2024 Accellera"))):
                continue
            # Body headings have varying indentation. Restrict candidates
            # to the current chapter so references cannot create foreign rows.
            top = CHAPTER.match(stripped) or re.fullmatch(r"Annex ([A-H])", stripped)
            sec = SECTION.match(stripped)
            new_id = None
            if top:
                proposed = top.group(1)
                # §1.5 repeats chapter titles as a contents description.
                # A new chapter follows its predecessor, never inside §1.5.
                order = [str(n) for n in range(1, 13)] + list("ABCDEFGH")
                expected = order[0] if chapter is None else (
                    order[order.index(chapter) + 1] if chapter != "H" else None
                )
                if proposed == expected and (current != "1.5" or page >= 24):
                    chapter = proposed
                    new_id = proposed
            elif sec and sec.group(1).split(".")[0] == chapter:
                # Cross references have prose continuations and sometimes
                # start at column zero. Repeated ids are retained as body text.
                if sec.group(1) not in sections:
                    new_id = sec.group(1)
            if new_id and new_id not in sections:
                current = new_id
                sections[current] = {"title": stripped, "page": page, "text": ""}
            elif current:
                sections[current]["text"] += line.rstrip() + "\n"
    return sections, duplicates


def sort_key(section):
    return tuple((0, int(p)) if p.isdigit() else (1, p) for p in section.split("."))


def html_sections(root):
    """Every numbered heading of specification/*.html: {section: {title, line, text, file}},
    and the headings declared twice."""
    html, duplicates = {}, []
    for path in sorted((root / "specification").glob("*.html")):
        if path.name == "index.html":
            continue
        parsed = ChapterHTML()
        parsed.feed(path.read_text())
        duplicates.extend(f"{path.name}:{s}" for s in parsed.duplicates)
        for section, item in parsed.sections.items():
            if section in html:
                duplicates.append(section)
            html[section] = dict(item, file=str(path.relative_to(root)))
    return html, duplicates


def inventory(root):
    pdf = root / "specification/VAMS-LRM-2023.pdf"
    source, pdf_duplicates = pdf_sections(pdf)
    html, duplicates = html_sections(root)
    duplicates = list(pdf_duplicates) + duplicates
    rows = []
    for section in sorted(source.keys() | html.keys(), key=sort_key):
        p, h = source.get(section), html.get(section)
        row = {"section": section, "pdf": p, "html": h}
        if p is None:
            row["comparison"] = "html-only-heading"
        elif h is None:
            row["comparison"] = "pdf-only-heading"
        else:
            row["comparison"] = (
                "same-text-tokens" if tokens(p["text"]) == tokens(h["text"])
                else "review-difference"
            )
        rows.append(row)
    return {
        "pdf_sha256": hashlib.sha256(pdf.read_bytes()).hexdigest(),
        "warning": "Mechanical worklist only; no claim of semantic fidelity or conformance.",
        "duplicate_html_headings": duplicates,
        "sections": rows,
    }


def lrm_audit(argv):
    """Source-fidelity worklist, NOT a conformance score.

    Read the checked-in PDF with Poppler and compare each numbered section with
    the HTML. Keep differences visible: equations, diagrams, tables, grammar and
    normative scope still require human review. No fixture earns credit here.
    """
    parser = argparse.ArgumentParser(prog="conformance.py lrm-audit", description=lrm_audit.__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--section", help="Show a section and its descendants")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--diff", action="store_true", help="Print token differences")
    args = parser.parse_args(argv)
    report = inventory(args.root)
    if args.section:
        report["sections"] = [r for r in report["sections"] if
                              r["section"] == args.section or
                              r["section"].startswith(args.section + ".")]
        if not report["sections"]:
            parser.error("section not found")
    if args.json:
        json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return 0
    print(report["warning"])
    print("PDF SHA256:", report["pdf_sha256"])
    for row in report["sections"]:
        p, h = row["pdf"], row["html"]
        loc = f'{h["file"]}:{h["line"]}' if h else "MISSING HTML"
        page = p["page"] if p else "MISSING PDF HEADING"
        print(f'{row["section"]}\tPDF page {page}\t{loc}\t{row["comparison"]}')
        if args.diff and p and h:
            a, b = tokens(p["text"]), tokens(h["text"])
            matcher = difflib.SequenceMatcher(None, a, b, autojunk=False)
            for tag, i, j, k, l in matcher.get_opcodes():
                if tag != "equal":
                    print("  PDF:", " ".join(a[max(0, i-5):j+5]))
                    print("  HTML:", " ".join(b[max(0, k-5):l+5]))
    for duplicate in report["duplicate_html_headings"]:
        print("DUPLICATE:", duplicate)
    return 0


SUBCOMMANDS["lrm-audit"] = lrm_audit


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
    atomic rules. `tests/fixtures/ieee1364/CLAUSES.tsv` was cut from this
    output and is reviewed, never regenerated.
    """
    parser = argparse.ArgumentParser(prog="conformance.py ieee1364-audit", description=ieee1364_audit.__doc__)
    parser.add_argument("--pdf", type=Path, default=ROOT / "specification/1364-2005.pdf")
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

class KeywordTable(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_table = False
        self.in_code = False
        self.words = []

    def handle_starttag(self, tag, attrs):
        if tag == "table":
            self.in_table = True
        if tag == "code":
            self.in_code = True

    def handle_endtag(self, tag):
        if tag == "table":
            self.in_table = False
        if tag == "code":
            self.in_code = False

    def handle_data(self, data):
        if self.in_table and self.in_code:
            self.words.extend(data.split())


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
    # Visually confirmed source-table defect, also labeled in the HTML.
    if words.count("negedgenmos") != 1:
        raise ValueError("Source table changed: re-audit the negedgenmos correction")
    words.remove("negedgenmos")
    words.extend(["negedge", "nmos"])
    if len(words) != len(set(words)):
        raise ValueError("Duplicate source keyword")
    html = KeywordTable()
    html.feed((ROOT / "specification/annex-b-keywords.html").read_text())
    if len(html.words) != len(set(html.words)):
        raise ValueError("Duplicate HTML keyword")
    if set(words) != set(html.words):
        raise ValueError(f"PDF-only: {set(words) - set(html.words)}; "
                         f"HTML-only: {set(html.words) - set(words)}")
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
            path = ROOT / f"tests/fixtures/annex_b_keywords/audit_all_{mode}_keywords.va"
            if path.read_text() != keyword_fixture(words, mode):
                raise SystemExit(f"Fixture drift: {path}")
    print(f"Table B.1: {len(words)} distinct corrected spellings; PDF and HTML sets match.")
    return 0


SUBCOMMANDS["keywords"] = keywords


# ---------------------------------------------------------------------------
# figures: the LRM's figures in specification/figures, cropped from the pinned PDF
# ---------------------------------------------------------------------------

# Requires Poppler's pdftoppm. Coordinates are PDF points measured from the
# top-left of a physical page: (physical page, left, top, width, height).
# Crops include the original caption. Adding an entry requires visual
# comparison against the source page. Direct PDF rasterization preserves
# patterned guide lines that were lost in a pdftocairo-SVG/librsvg round trip
# during visual validation.
FIG_SCALE = 3  # 216 dpi; lossless PNG, no resampling or generative processing.

# Chapters 1-9 (`lrm-figure-<n>.png`).
LRM_FIGURES = {
    "1-1": (15, 152, 349, 310, 150),
    "1-2": (16, 163, 403, 285, 104),
    "1-3": (17, 88, 312, 436, 262),
    "3-1": (62, 180, 78, 252, 154),
    "3-2": (62, 184, 293, 244, 150),
    "4-3": (81, 135, 78, 345, 290),
    "4-4": (85, 88, 175, 437, 220),
    "4-5": (85, 127, 565, 359, 137),
    "4-6": (86, 136, 103, 340, 130),
    "4-7": (87, 150, 439, 310, 154),
    "4-8": (88, 150, 140, 310, 154),
    "4-9": (88, 150, 332, 310, 153),
    "4-10": (89, 150, 90, 310, 152),
    "4-11": (89, 150, 280, 310, 150),
    "4-12": (90, 150, 90, 310, 152),
    "4-13": (91, 148, 590, 316, 114),
    "4-14": (104, 125, 202, 360, 352),
    "5-1": (113, 130, 404, 352, 131),
    "5-2": (114, 130, 79, 352, 210),
    "5-3": (124, 105, 551, 402, 143),
    "5-4": (125, 119, 127, 374, 146),
    "5-5": (126, 128, 79, 355, 225),
    "5-6": (140, 88, 93, 436, 144),
    "7-1": (178, 105, 390, 402, 206),
    "7-2": (187, 111, 294, 390, 242),
    "7-3": (188, 87, 463, 500, 258),
    "7-4": (189, 87, 258, 500, 258),
    "7-5": (190, 87, 162, 500, 260),
    "7-6": (197, 87, 150, 500, 262),
    "7-7": (199, 152, 78, 308, 600),
    # One source drawing has an empty 7-8 caption above and the 7-9 caption
    # below. Keep both captions in this single crop, not duplicate drawings.
    "7-9": (201, 119, 67, 374, 465),
    "7-10": (202, 117, 210, 378, 458),
    "7-11": (212, 87, 78, 438, 380),
    "8-1": (214, 158, 78, 296, 469),
    "8-2": (216, 158, 78, 296, 516),
    "8-3": (220, 130, 78, 352, 202),
    "8-4": (221, 90, 238, 470, 310),
    "8-5": (222, 90, 90, 471, 309),
    "8-6": (224, 90, 90, 470, 292),
    "8-7": (225, 88, 98, 474, 280),
    "9-1": (268, 160, 86, 305, 214),
    "9-2": (268, 137, 463, 370, 222),
    "9-3": (276, 64, 403, 484, 141),
    "9-4": (277, 150, 417, 312, 216),
}

# Chapter 6 (`lrm-figure-6-<n>.png`).
CH6_FIGURES = {
    "6-1": (151, 190, 247, 232, 132),
    "6-2": (174, 103, 300, 423, 110),
}

# Chapter 11 source graphs (`ch11-<name>.png`). All source pages were visually
# checked on 2026-09-23. Broad model-page crops retain the original notes as
# well as edges; HTML also transcribes those notes.
CH11_CROPS = {"figure-11-1": (288, 110, 493, 390, 158),
              "legend-11-5-1-2": (293, 85, 68, 475, 660),
              "legend-11-5-3": (294, 85, 68, 475, 660)}
CH11_CROPS.update({f"model-page-{p}": (p, 60, 60, 500, 668)
                   for p in range(296, 322)})

# Annex E figure and table crops (`annex-e-<name>.png`).
ANNEX_E_CROPS = {
    "figure-e-1": (415, 220, 584, 175, 120),
    "table-e-1-a": (417, 78, 242, 455, 400),
    "table-e-1-b": (418, 78, 68, 455, 555),
    "table-e-1-c": (419, 78, 68, 455, 590),
}

# set: (crops, output prefix, message when the PDF changed, report line)
FIGURE_SETS = {
    "lrm": (LRM_FIGURES, "lrm-figure-", "Source PDF changed: re-audit page and crop coordinates first",
            "Figure {name}: PDF page {page}, box {left} {top} {width} {height}"),
    "ch6": (CH6_FIGURES, "lrm-figure-", "Source PDF changed: re-audit crop coordinates first",
            "Figure {name}: PDF page {page}, box {left} {top} {width} {height}"),
    "ch11": (CH11_CROPS, "ch11-", "Source PDF changed: re-audit every crop first",
             "{name}: physical {page}; rectangle {left} {top} {width} {height}"),
    "annex-e": (ANNEX_E_CROPS, "annex-e-", "Source changed: visually re-audit rectangles",
                "{name}: physical {page}; rectangle {left} {top} {width} {height}"),
}


def figures(argv):
    """Re-crop the LRM figures in specification/figures from specification/VAMS-LRM-2023.pdf.

        tools/conformance.py figures [lrm|ch6|ch11|annex-e ...]   # default: all
    """
    names = argv or list(FIGURE_SETS)
    for name in names:
        if name not in FIGURE_SETS:
            print(f"usage: conformance.py figures [{'|'.join(FIGURE_SETS)} ...]", file=sys.stderr)
            return 2
    destination = ROOT / "specification/figures"
    for name in names:
        crops, prefix, changed, report = FIGURE_SETS[name]
        if hashlib.sha256(LRM_PDF.read_bytes()).hexdigest() != LRM_SHA256:
            raise SystemExit(changed)
        destination.mkdir(exist_ok=True)
        for crop, (page, left, top, width, height) in crops.items():
            subprocess.run([
                "pdftoppm", "-f", str(page), "-l", str(page), "-singlefile",
                "-r", str(72 * FIG_SCALE), "-x", str(left * FIG_SCALE),
                "-y", str(top * FIG_SCALE), "-W", str(width * FIG_SCALE),
                "-H", str(height * FIG_SCALE), "-png", str(LRM_PDF), str(destination / f"{prefix}{crop}"),
            ], check=True)
            print(report.format(name=crop, page=page, left=left, top=top, width=width, height=height))
    return 0


SUBCOMMANDS["figures"] = figures


# ---------------------------------------------------------------------------
# comments: the clauses the code says it implements or refuses, against the
# clauses the fixtures cite. A pointer for a reader, NOT a measure.
# ---------------------------------------------------------------------------

# A standard named in a comment, optionally followed by a clause number:
# `IEEE 1364-2005 §9.2.2`, `IEEE 12.8.2`, `1364 §17`, `AMS 9.7.3`, `LRM §4.3`.
# A bare `§9.7.3` takes the standard the line last named, the LRM by default
# (VerA's comments write a bare § for this LRM and name IEEE 1364 when they
# mean it). Only the first number of a range or list after a standard word is
# read (`§§17-18` reads 17).
CITE = re.compile(
    r"(?P<std>\bIEEE(?:\s+Std)?(?:\s+1364(?:-2005)?)?|\b1364(?:-2005)?\b|\bVAMS(?:-2023)?\b|\bAMS\b|\bLRM\b)"
    r"(?:\s*§*\s*(?P<n1>[0-9]+(?:\.[0-9]+)*|[A-I](?:\.[0-9]+)+)\b)?"
    r"|§+\s*(?P<n2>[0-9]+(?:\.[0-9]+)*|[A-I](?:\.[0-9]+)*)\b")


def comment_cites(text):
    """(standard, clause, line number, named) for every clause a `//` comment
    cites; `named` is false for a bare § on a line that names no standard.
    A `\\\\` line is device text the compiler emits, not a comment."""
    out = []
    for no, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith("\\\\") or "//" not in line:
            continue
        std, named = "ams", False
        for m in CITE.finditer(line[line.index("//"):]):
            if m.group("std"):
                std = "ieee" if m.group("std").startswith(("IEEE", "1364")) else "ams"
                named = True
                if m.group("n1"):
                    out.append((std, m.group("n1"), no, True))
            else:
                out.append((std, m.group("n2"), no, named))
    return out


def under(child, parent):
    """Is clause `child` the clause `parent` or one of its subclauses?"""
    return child == parent or child.startswith(parent + ".")


def fixture_cites():
    """{(standard, clause): {"pos": [paths], "neg": [paths]}} from the
    fixtures' tags, the polarity rules `--coverage` and `suite -- ieee1364 --coverage`
    use: a file with a `//! reject` (or `// digital-runner: reject`) cites
    negatively; a `.c` application counts only if `build.zig` runs it (its
    `//! design` line), and polarity is per line (`lrm-reject`, `inherited-reject`)."""
    runs = {f"tests/fixtures/{c}" for c in vpi_runs()}
    cites = {}

    def add(std, clause, side, path):
        cites.setdefault((std, clause), {"pos": [], "neg": []})[side].append(path)

    for path in fixture_files("*.va", "*.v", "*.c"):
        rel = str(path.relative_to(ROOT))
        if path.suffix == ".c" and rel not in runs:
            continue
        source = path.read_text(errors="replace")
        neg = path.suffix != ".c" and re.search(r"(?m)^\s*(//! reject|// digital-runner: reject)", source) is not None
        for raw in source.split("\n"):
            line = raw.strip()
            if not line.startswith("//!"):
                continue
            words = line[3:].strip()
            m = re.match(r"(lrm|lrm-reject)\s+(?:annex\s+)?(\S+)", words)
            if m:
                side = "neg" if neg or m.group(1) == "lrm-reject" else "pos"
                add("ams", m.group(2), side, rel)
                continue
            m = re.match(r"(inherited|inherited-reject) IEEE 1364-2005 (.*)", words)
            if m:
                side = "neg" if neg or m.group(1) == "inherited-reject" else "pos"
                for clause in re.split(r"[ ,]+", m.group(2).split("(")[0].strip()):
                    if clause:
                        add("ieee", clause, side, rel)
    return cites


def refusals():
    """{(standard, clause): [codes]} for every error code in lib/diag/code.zig
    whose catalogue row cites a clause: the code's refusal is the code's claim
    about that clause."""
    out, codes = {}, []
    for line in (ROOT / "lib/diag/code.zig").read_text().split("\n"):
        m = re.match(r"\s*(\.[EW]\d{4}(?:\s*,\s*\.[EW]\d{4})*)\s*=>", line)
        if m:
            codes = re.findall(r"[EW]\d{4}", m.group(1))
            continue
        m = re.match(r'\s*\.lrm = "([^"]*)"', line)
        if not m:
            continue
        for part in m.group(1).split(" / "):
            part = part.strip()
            std = "ieee" if part.startswith("IEEE 1364-2005 ") else "ams"
            clause = part.removeprefix("IEEE 1364-2005 ")
            for code in codes:
                if clause and code.startswith("E"):
                    out.setdefault((std, clause), []).append(code)
        codes = []
    return out


def clause_kinds():
    """{(standard, clause): kind} from every CLAUSES.tsv: the CLAUSE-AUDIT.md
    §5 classifications (`-` is an ordinary clause in the IEEE list)."""
    out = {}
    for path in sorted((ROOT / "tests/fixtures").rglob("CLAUSES.tsv")):
        std = "ieee" if "ieee1364" in path.parts else "ams"
        for line in path.read_text().split("\n"):
            if not line.strip() or line.startswith("#"):
                continue
            cells = line.split("\t")
            if len(cells) > 1 and cells[1] != "-":
                out[(std, cells[0].strip())] = cells[1].strip()
    return out


def comments(argv):
    """Code-comment clause signal: which clauses the code's comments cite and
    which its error codes refuse, cross-checked against the fixtures' tags and
    the CLAUSE-AUDIT.md §5 classifications (CLAUSES.tsv).

        tools/conformance.py comments          # counts, then every row
        tools/conformance.py comments --counts # counts only

    NOT a measure. It moves none of A, B or C and reports counts per category,
    never a percentage: it is pattern matching over prose, so a row is a place
    to look, not a finding.
    """
    counts_only = "--counts" in argv
    ams_known = set(html_sections(ROOT)[0])
    ieee_known = set()
    for line in (ROOT / "tests/fixtures/ieee1364/CLAUSES.tsv").read_text().split("\n"):
        if line.strip() and not line.startswith("#"):
            ieee_known.add(line.split("\t")[0].strip())
    known = {"ams": ams_known, "ieee": ieee_known}
    audit_text = (ROOT / "specification/CLAUSE-AUDIT.md").read_text()

    # The code's claims: comment cites in lib/ and src/.
    sites, unresolved, nfiles = {}, {"ams": 0, "ieee": 0}, 0
    for path in sorted(list((ROOT / "lib").rglob("*.zig")) + list((ROOT / "src").rglob("*.zig"))):
        rel = str(path.relative_to(ROOT))
        found = comment_cites(path.read_text())
        nfiles += bool(found)
        for std, clause, no, named in found:
            # A bare § the LRM has no heading for, on a line naming no
            # standard, is read as IEEE 1364 when that has the heading: the
            # digital engine's comments continue an `IEEE 1364-2005` list
            # onto the next line.
            if not named and clause not in known["ams"] and clause in known["ieee"]:
                std = "ieee"
            if clause not in known[std]:
                unresolved[std] += 1
                continue
            sites.setdefault((std, clause), []).append(f"{rel}:{no}")
    refused = {k: v for k, v in refusals().items() if k[1] in known[k[0]]}
    fixtures = fixture_cites()
    kinds = clause_kinds()

    def evidence(key, side):
        std, clause = key
        return [p for (s, c), sides in fixtures.items() if s == std and under(c, clause) for p in sides[side]]

    def mentioned(key):
        std, clause = key
        return any(s == std and under(c, clause) for (s, c) in list(sites) + list(refused))

    def in_audit(key):
        std, clause = key
        return re.search(r"§" + re.escape(clause) + r"(?![\d.]*\d)", audit_text) is not None

    order = lambda k: (k[0], sort_key(k[1]))
    implemented = sorted((k for k in sites if not evidence(k, "pos")), key=order)
    unpinned = sorted((k for k in refused if not evidence(k, "neg")), key=order)
    orphan = sorted((k for k in fixtures if k[1] in known[k[0]] and not mentioned(k)), key=order)
    std_name = {"ams": "LRM", "ieee": "IEEE 1364-2005"}

    def split(keys):
        return " · ".join(f"{std_name[s]} {sum(1 for k in keys if k[0] == s)}" for s in ("ams", "ieee"))

    print("Code-comment clause signal — NOT a measure: it moves none of A, B or C.")
    print("Pattern matching over comments; every row is a place to look, not a finding.")
    print("A bare § is this LRM unless its line names IEEE 1364, or only IEEE 1364 has the")
    print("heading. A clause matches its own cites and its subclauses' (code §4.5 is met by")
    print("a fixture citing 4.5.4). A cite naming no heading (an internal document's §, a")
    print("typo) is counted, never listed.")
    print()
    print(f"read: {sum(len(v) for v in sites.values())} comment cites of {len(sites)} clauses in {nfiles} files "
          f"under lib/ and src/ ({unresolved['ams']} LRM and {unresolved['ieee']} IEEE cites name no heading); "
          f"{sum(len(v) for v in refused.values())} error codes citing {len(refused)} clauses (lib/diag/code.zig); "
          f"{len(fixtures)} clauses cited by fixtures")
    print()
    print(f"1. cited in code, no positive fixture under it:   {len(implemented):4}  ({split(implemented)})")
    print(f"2. refused by an error code, no reject fixture:   {len(unpinned):4}  ({split(unpinned)})")
    print(f"3. cited by fixtures, no code comment or code:    {len(orphan):4}  ({split(orphan)})")
    if counts_only:
        return 0

    def tags(key):
        kind = kinds.get(key)
        return (f"  [CLAUSES.tsv: {kind}]" if kind else "") + ("  [in CLAUSE-AUDIT.md]" if in_audit(key) else "")

    def where(paths):
        return ", ".join(paths[:3]) + (f" (+{len(paths) - 3})" if len(paths) > 3 else "")

    print("\n## 1. Cited in code, no positive fixture cites the clause or a subclause")
    for k in implemented:
        neg = evidence(k, "neg")
        print(f"{std_name[k[0]]} §{k[1]}\t{where(sites[k])}" + (f"\treject fixtures only: {len(neg)}" if neg else "") + tags(k))
    print("\n## 2. Refused by an error code, no reject fixture cites the clause or a subclause")
    for k in unpinned:
        print(f"{std_name[k[0]]} §{k[1]}\t{' '.join(refused[k])}" + tags(k))
    print("\n## 3. Cited by fixtures, no comment or error code in lib/ or src/ cites the clause or a subclause")
    for k in orphan:
        f = fixtures[k]
        print(f"{std_name[k[0]]} §{k[1]}\t{where(f['pos'] + f['neg'])}" + tags(k))
    return 0


SUBCOMMANDS["comments"] = comments


# ---------------------------------------------------------------------------
# verilator: a second engine on the same .v designs
# ---------------------------------------------------------------------------

# N 32-bit Fibonacci LFSRs in a chain, scaled by substituting N and CYCLES.
LFSR_CHAIN = """\
// N 32-bit Fibonacci LFSRs in a chain, each stage XORing in its predecessor's
// previous value, clocked for CYCLES rising edges. One checksum line.
module lfsr_chain;
  parameter N = 64;
  parameter CYCLES = 1000;
  reg clk;
  reg [31:0] r [0:N-1];
  reg [31:0] prev, t, sum;
  integer i;
  always @(posedge clk) begin
    prev = 32'hACE1;
    for (i = 0; i < N; i = i + 1) begin
      t = r[i];
      r[i] <= {t[30:0], t[31] ^ t[21] ^ t[1] ^ t[0]} ^ prev;
      prev = t;
    end
  end
  initial begin
    for (i = 0; i < N; i = i + 1) r[i] = i + 1;
    clk = 0;
    repeat (2 * CYCLES) #1 clk = ~clk;
    #1 sum = 0;
    for (i = 0; i < N; i = i + 1) sum = sum ^ r[i];
    $display("lfsr_chain N=%0d CYCLES=%0d checksum=%h", N, CYCLES, sum);
    $finish(0);
  end
endmodule
"""


def ripple_adder(width, vectors, gates=False):
    """A `width`-bit ripple-carry adder of full-adder instances on scalar nets,
    so each vector ripples through `width` carry events, fed `vectors` LFSR
    operand pairs. One checksum line. Generated because VerA's digital path
    assigns whole nets only. `gates`: each full adder is five §7 gate
    primitives instead of two assigns, with the same checksum."""
    out = ["module fa(a, b, ci, s, co);\n  input a, b, ci;\n  output s, co;"]
    if gates:
        out.append("  wire p, g, t;\n  xor x1(p, a, b), x2(s, p, ci);\n  and a1(g, a, b), a2(t, ci, p);\n  or o1(co, g, t);\nendmodule\n")
    else:
        out.append("  assign s = a ^ b ^ ci;\n  assign co = (a & b) | (ci & (a ^ b));\nendmodule\n")
    out.append(f"module ripple_adder;\n  reg [{width - 1}:0] a, b;\n  reg [31:0] x, sum;\n  integer i, k;\n  wire c0 = 1'b0;")
    text = "\n".join(out) + "\n"
    for g in range(width):
        text += f"  wire s{g}, c{g + 1};\n  fa f{g}(a[{g}], b[{g}], c{g}, s{g}, c{g + 1});\n"
    text += "  wire [31:0] lo = {" + ", ".join(f"s{g % width}" for g in range(31, -1, -1)) + "};\n"
    text += "\n".join([
        f"  initial begin\n    x = 32'hACE1;\n    sum = 0;\n    for (i = 0; i < {vectors}; i = i + 1) begin",
        f"      for (k = 0; k < {width}; k = k + 1) begin\n        x = {{x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]}};\n        a[k] = x[0];\n        b[k] = x[7];\n      end",
        f"      #1 sum = {{sum[30:0], sum[31]}} ^ lo ^ c{width};\n    end",
        f"    $display(\"ripple_adder W={width} VECTORS={vectors} checksum=%h\", sum);\n    $finish(0);\n  end\nendmodule",
    ]) + "\n"
    return text


def without_report(data):
    """`grep -v '^- '`: Verilator's report lines dropped, every line ended."""
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    return b"".join(l + b"\n" for l in lines if not l.startswith(b"- "))


def verilator_oracle(work):
    """Verilator over every tests/fixtures/ieee1364 .v, one row each, into
    tests/fixtures/ieee1364/VERILATOR.tsv. VerA is not run; its answer is the
    committed transcript `zig build suite -- ieee1364` already holds it to. A row that
    disagrees is data for a reader, never a reason to edit the fixture."""
    import concurrent.futures
    import shutil

    def oracle(f):
        n = f.removeprefix("tests/fixtures/ieee1364/")
        d = work / f.replace("/", "_")
        expected = ROOT / (f[:-2] + ".expected.txt")
        shutil.copytree(ROOT / os.path.dirname(f), d, dirs_exist_ok=True)  # `$readmem`/`$fopen` paths are relative
        source = (ROOT / f).read_text(errors="replace")
        if re.search(r"(?m)^\s*(// digital-runner: reject|//! reject)", source):
            expect = "reject"
        elif expected.is_file():
            expect = "transcript"
        else:
            expect = "other"
        acc, rc, agrees, note = "refuses", "-", "-", ""
        # Bounded as `icarus` is (4 at a time, each C++ build under 4 GiB of
        # address space and 10 CPU minutes): an unbounded oracle run is how a
        # session got OOM-killed on 2026-10-07.
        build = subprocess.run(["sh", "-c", 'ulimit -v 4194304; ulimit -t 600; exec "$@"', "sh",
                                "verilator", "--binary", "--timing", "-j", "2", "-Wno-fatal", "-Wno-lint", "-Wno-style",
                                "--Mdir", str(d / "obj"), "-o", "sim", f], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (d / "build.log").write_bytes(build.stdout)
        if build.returncode == 0:
            acc = "accepts"
            with open(d / "out.txt", "wb") as out, open(d / "err.txt", "wb") as err:
                try:
                    code = subprocess.run(["./obj/sim"], cwd=d, stdout=out, stderr=err, timeout=60).returncode
                    rc = str(code if code >= 0 else 128 - code)
                except subprocess.TimeoutExpired:
                    rc = "124"
        else:
            first_error = next((l for l in build.stdout.split(b"\n") if b"%Error" in l), b"")
            first_error = first_error.replace(str(ROOT).encode() + b"/", b"", 1).replace(b"\t", b" ")
            note = first_error[:160].decode(errors="replace")
        if expect == "reject":
            if acc == "refuses" or rc != "0":
                agrees = "yes"
            else:
                agrees, note = "no", "accepts and exits 0"
        elif expect == "transcript":
            if acc == "accepts" and rc == "0" and without_report((d / "out.txt").read_bytes()) == expected.read_bytes():
                agrees = "yes"
            else:
                agrees = "no"
                if acc == "accepts":
                    note = "timeout" if rc == "124" else f"exit {rc}"
                    if rc == "0":
                        note = "stdout differs"
                    if re.search(rb"(?m)(^|[^A-Za-z0-9_])[01_]*[xXzZ][01xXzZ_]*($|[^A-Za-z0-9_])", expected.read_bytes()):
                        note += "; golden shows x/z"
        return f"{n}\t{expect}\t{acc}\t{rc}\t{agrees}\t{note}\n"

    fixtures = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "tests/fixtures/ieee1364").rglob("*.v"))
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        rows = list(pool.map(oracle, fixtures))
    # `sort`, not `sorted`: the committed file is in the locale's collation.
    rows = subprocess.run(["sort"], input="".join(rows), capture_output=True, text=True).stdout
    version = subprocess.run(["verilator", "--version"], capture_output=True, text=True).stdout.rstrip("\n")
    out = ROOT / "tests/fixtures/ieee1364/VERILATOR.tsv"
    out.write_text(
        f"# {version} — `verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style`,\n"
        "# written by `tools/conformance.py verilator --oracle`. agrees: a transcript fixture's stdout\n"
        "# (Verilator's `- ` report lines dropped) equals its .expected.txt, a reject fixture is\n"
        "# refused at build or exits nonzero. Verilator is 2-state by default, so a golden\n"
        "# showing x/z is expected to differ. Disagreements are listed, never resolved.\n"
        "fixture\texpect\tverilator\texit\tagrees\tnote\n" + rows)
    agree = sum(1 for r in rows.splitlines() if r.split("\t")[4] == "yes")
    judged = sum(1 for r in rows.splitlines() if r.split("\t")[4] in ("yes", "no"))
    print("verilator: %d / %d fixtures agree (%.1f%%) -> %s" % (agree, judged, 100 * agree / judged, out.relative_to(ROOT)),
          file=sys.stderr)
    return 0


def icarus(argv):
    """`icarus [--work=DIR]`: Icarus Verilog (4-state, event-driven) over every
    .v with a committed transcript or a refusal under tests/fixtures/ieee1364
    and tests/fixtures/digital -> tests/fixtures/conformance/ICARUS.tsv, one row each, in
    VERILATOR.tsv's columns. The second engine:
    Verilator is 2-state, so its x/z disagreements are expected; Icarus's are
    not. A disagreement is data for a reader (VerA bug, Icarus bug, or a
    reading of the standard), never a reason to edit the fixture. Needs
    `iverilog` and `vvp` on PATH (`nix shell nixpkgs#iverilog`)."""
    import concurrent.futures
    import shutil
    import tempfile

    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    work = Path(opts.get("work") or tempfile.mkdtemp(prefix="vera-icarus-"))
    # Every child is bounded: 2026-10-07, one deliberately oversized design
    # (ieee1364/12_hierarchy/instance_array_width_product_rejected.v)
    # drove `ivl` to 20 GB and a 4.3 GB `sim.vvp`, and the OOM killer took
    # the session. Address space, output size and CPU are capped per process,
    # and at most `JOBS` run at once, so the worst case is JOBS * AS_KIB.
    AS_KIB, FSIZE_KIB, CPU_S, JOBS = 2 * 1024 * 1024, 256 * 1024, 120, 4

    def bounded(*cmd):
        return ["sh", "-c", f'ulimit -v {AS_KIB}; ulimit -f {FSIZE_KIB}; ulimit -t {CPU_S}; exec "$@"', "sh", *cmd]

    def limited(rc, text):
        # A child stopped by its bounds proves nothing about the design.
        return rc < 0 or rc in (134, 137, 139, 152, 153) or re.search(rb"bad_alloc|[Oo]ut of memory|File size limit", text)
    noise = re.compile(rb"^(VCD info:|VCD warning:|WARNING: .*: \$readmem|.*: \$finish called at |.*: \$stop called at ).*\n?", re.M)

    def oracle(f):
        rel = f.removeprefix("tests/fixtures/")
        d = work / rel.replace("/", "_")
        expected = ROOT / (f[:-2] + ".expected.txt")
        shutil.copytree(ROOT / os.path.dirname(f), d, dirs_exist_ok=True)  # `$readmem`/`$fopen` paths are relative
        source = (ROOT / f).read_text(errors="replace")
        if re.search(r"(?m)^\s*(// digital-runner: reject|//! reject)", source):
            expect = "reject"
        elif expected.is_file():
            expect = "transcript"
        else:
            return None
        acc, rc, agrees, note = "refuses", "-", "-", ""
        build = subprocess.run(bounded("iverilog", "-g2005", "-o", str(d / "sim.vvp"), "-I", str(ROOT / os.path.dirname(f)), str(ROOT / f)),
                               cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if limited(build.returncode, build.stdout):
            shutil.rmtree(d, ignore_errors=True)
            return f"{rel}\t{expect}\tlimit\t-\t-\tiverilog stopped by its resource bounds\n"
        if build.returncode == 0:
            acc = "accepts"
            try:
                r = subprocess.run(bounded("vvp", "-n", "sim.vvp"), cwd=d, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
                if limited(r.returncode, r.stderr):
                    shutil.rmtree(d, ignore_errors=True)
                    return f"{rel}\t{expect}\tlimit\t-\t-\tvvp stopped by its resource bounds\n"
                rc = str(r.returncode)
                out = noise.sub(b"", r.stdout)
            except subprocess.TimeoutExpired:
                rc, out = "124", b""
        else:
            note = build.stdout.split(b"\n")[0].replace(str(ROOT).encode() + b"/", b"", 1)[:160].decode(errors="replace").replace("\t", " ")
        if expect == "reject":
            agrees, note = ("yes", note) if acc == "refuses" or rc != "0" else ("no", "accepts and exits 0")
        elif acc == "accepts" and rc == "0" and out == expected.read_bytes():
            agrees = "yes"
        else:
            agrees = "no"
            if acc == "accepts":
                note = "timeout" if rc == "124" else ("stdout differs" if rc == "0" else f"exit {rc}")
        shutil.rmtree(d, ignore_errors=True)  # the row is the result; the work dir is not kept
        return f"{rel}\t{expect}\t{acc}\t{rc}\t{agrees}\t{note}\n"

    fixtures = sorted(str(p.relative_to(ROOT)) for d in ("ieee1364", "digital") for p in (ROOT / "tests/fixtures" / d).rglob("*.v"))
    with concurrent.futures.ThreadPoolExecutor(JOBS) as pool:
        rows = [r for r in pool.map(oracle, fixtures) if r]
    rows = "".join(sorted(rows))
    version = subprocess.run(["iverilog", "-V"], capture_output=True, text=True).stdout.split("\n")[0]
    out = ROOT / "tests/fixtures/conformance/ICARUS.tsv"
    out.write_text(
        f"# {version} — `iverilog -g2005`, `vvp -n`; written by `tools/conformance.py icarus`.\n"
        "# agrees: a transcript fixture's stdout (vvp's own VCD/$finish notices dropped) equals its\n"
        "# .expected.txt; a reject fixture is refused at build or exits nonzero. Disagreements are\n"
        "# listed, never resolved. Read by `metric` as an independent oracle.\n"
        "fixture\texpect\ticarus\texit\tagrees\tnote\n" + rows)
    agree = sum(1 for r in rows.splitlines() if r.split("\t")[4] == "yes")
    print(f"icarus: {agree} / {len(rows.splitlines())} fixtures agree -> {out.relative_to(ROOT)}", file=sys.stderr)
    return 0


SUBCOMMANDS["icarus"] = icarus


def verilator_table(work, vera):
    """VerA against Verilator on six self-contained digital fixtures plus the
    scalable LFSR chain and ripple adder (twice: assigns, then gate primitives).
    Three engines per design, one Markdown row:
      interp     `vera --run`: parse + elaborate + interpret, one process
      native     `vera --emit-exe --optimize=ReleaseFast --zig-backend=llvm`
                 (the default --schedule=static; SCHEDULE=fifo for the other;
                 the default --state=auto), built in a cold cache, then the
                 executable run. A design the emitter refuses embeds the
                 interpreter; its row says `(interp)`. `state` is what auto
                 ran: `2 @t` (2-state from tick t), `rerun` (then 4-state
                 again), `4` (never left 4-state), `4: <why>` (built 4-state)
      verilator  `verilator --binary -j 0`, then obj/sim
    Wall time and peak RSS of each build and run (GNU time), executable bytes
    as built (not stripped), and whether all three stdouts agree (Verilator's
    `- ` report lines dropped). The column a reader wants for conformance is
    the last one; the times mean nothing unless vera is -Doptimize=ReleaseFast."""
    designs = [f"tests/fixtures/ieee1364/{f}.v" for f in (
        "05_expressions/audit_expr_signed_boundaries", "10_tasks_functions/audit_function_return_variable",
        "17_system_tasks/audit_ieee_math_clog2_unsigned", "04_data_types/audit_type_multidimensional_array",
        "10_tasks_functions/d04_09_task_argument_passing", "17_system_tasks/d09_01_display_radix")]
    for n, c in ((64, 1000), (1024, 10000)):
        f = work / f"lfsr_chain_{n}x{c}.v"
        f.write_text(LFSR_CHAIN.replace("N = 64;", f"N = {n};", 1).replace("CYCLES = 1000;", f"CYCLES = {c};", 1))
        designs.append(str(f))
    for wd, v in ((64, 1000), (512, 10000)):
        f = work / f"ripple_adder_{wd}x{v}.v"
        f.write_text(ripple_adder(wd, v))
        designs.append(str(f))
        f = work / f"gate_adder_{wd}x{v}.v"
        f.write_text(ripple_adder(wd, v, gates=True))
        designs.append(str(f))

    import shutil
    # GNU time, not the shell keyword; NixOS has no /usr/bin/time.
    gnu_time = "/usr/bin/time" if os.path.exists("/usr/bin/time") else shutil.which("time") or "/usr/bin/time"

    def timed(out, argv, cwd=ROOT):
        """argv with stdout to `out`, stderr to work/err: (ok, seconds, MB) by GNU time."""
        with open(out, "wb") as o, open(work / "err", "wb") as e:
            rc = subprocess.run([gnu_time, "-f", "%e %M", "-o", str(work / "t")] + argv, stdout=o, stderr=e, cwd=cwd).returncode
        secs, kb = (work / "t").read_text().strip().split("\n")[-1].split()
        return rc == 0, secs, "%.1f" % (int(kb) / 1024)

    def kb(path):
        return str((os.path.getsize(path) + 1023) // 1024)

    print("| design | interp run s | interp MB | native build s | native run s | native MB | native KB | state | verilator build s | verilator run s | verilator MB | verilator KB | outputs agree |")
    print("|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---|")
    for d in designs:
        n = os.path.basename(d)[:-2]
        ok, vs, vm = timed(work / "vera.out", [vera, "--std=1364-2005", "--run", d])
        if not ok:
            vs, vm = "error", "-"
        # Native: a cold cache per design, so the build column is a whole build.
        vn = work / f"vn_{n}"
        vn.mkdir(parents=True, exist_ok=True)
        ok, nb, _ = timed(work / "vn.path", [vera, "--std=1364-2005", "--emit-exe", f"--schedule={os.environ.get('SCHEDULE') or 'static'}",
                                             "--optimize=ReleaseFast", "--zig-backend=llvm", "--work-dir", ".", os.path.realpath(ROOT / d)], cwd=vn)
        if ok:
            err = (work / "err").read_text(errors="replace")
            nexe = vn / (work / "vn.path").read_text().split("\n")[0]
            if "not native (" in err:
                nb += " (interp)"
            four = next((l[l.index("4-state: "):] for l in err.split("\n") if "4-state: " in l), "")
            four = ("4" + four[len("4-state"):]).replace("|", "\\|") if four else ""
            ok, nr, nm = timed(work / "vn.out", [str(nexe)])
            nk = kb(nexe) if ok else "-"
            if not ok:
                nr, nm = "error", "-"
            # The state line costs nothing extra: the run above is the timed one.
            st_err = subprocess.run([str(nexe), "--vera-state"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True).stderr
            st = next((l[len("vera-state: "):] for l in st_err.split("\n") if l.startswith("vera-state: ")), "")
            if "rerun" in st:
                st = "rerun"
            elif st.startswith("2-state from tick "):
                st = "2 @" + st[len("2-state from tick "):]
            elif st == "4-state":
                st = "4"
            else:
                st = four or "4"
        else:
            nb, nr, nm, nk, st = "error", "-", "-", "-", "-"
            (work / "vn.out").write_bytes(b"")
        ok, bs, _ = timed(os.devnull, ["verilator", "--binary", "-j", "0", "-Wno-fatal", "--Mdir", str(work / f"obj_{n}"), "-o", "sim", d])
        if ok:
            ok, rs, rm = timed(work / "vl.out", [str(work / f"obj_{n}/sim")])
            rk = kb(work / f"obj_{n}/sim") if ok else "-"
            if not ok:
                rs, rm = "error", "-"
        else:
            bs, rs, rm, rk = "error", "-", "-", "-"
            (work / "vl.out").write_bytes(b"")
        vera_out = (work / "vera.out").read_bytes()
        vl = without_report((work / "vl.out").read_bytes())
        agree = (vs != "error" and nr not in ("error", "-") and rs not in ("error", "-")
                 and vera_out == (work / "vn.out").read_bytes() and vera_out == vl)
        print(f"| {n} | {vs} | {vm} | {nb} | {nr} | {nm} | {nk} | {st} | {bs} | {rs} | {rm} | {rk} | {'yes' if agree else 'NO'} |")
    return 0


def verilator(argv):
    """VerA against Verilator 5 (`--binary`) on the same .v designs.

        tools/conformance.py verilator [VERA]    # the three-engine table; VERA
                                                 # defaults to zig-out/bin/vera
        tools/conformance.py verilator --oracle  # tests/fixtures/ieee1364/VERILATOR.tsv
    """
    import tempfile
    # Resolved once: `nix shell` per call would add its start-up to every build.
    bins = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", "nixpkgs#verilator", "nixpkgs#gcc"],
                          capture_output=True, text=True)
    if bins.returncode:
        print("verilator: skipped — Verilator is not reachable through nix", file=sys.stderr)
        return 0
    os.environ["PATH"] = "".join(p + "/bin:" for p in bins.stdout.split()) + os.environ.get("PATH", "")
    with tempfile.TemporaryDirectory() as work:
        if argv[:1] == ["--oracle"]:
            return verilator_oracle(Path(work))
        return verilator_table(Path(work), os.path.realpath(ROOT / (argv[0] if argv else "zig-out/bin/vera")))


SUBCOMMANDS["verilator"] = verilator


# ---------------------------------------------------------------------------
# selftest: regression checks for the subcommands above and for the LRM text
# they read. Documentation integrity, not language conformance: no fixture
# earns credit here, and none of these runs the compiler.
# ---------------------------------------------------------------------------

import unittest
from unittest.mock import patch
from types import SimpleNamespace


class ReleaseVersionTests(unittest.TestCase):
    """`--changelog` sets both version literals; `--check` refuses a stale one."""

    def test_changelog_sets_both_and_check_reads_them(self):
        import tempfile
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


class SuiteScoreTests(unittest.TestCase):
    """The release line: XFAIL fails, XPASS passes, a skip counts against, SPICE is not scored."""

    def test_scores_by_language(self):
        rows = [("PASS", "verilog-a/a.va"), ("XFAIL", "verilog-a/b.va"), ("XPASS", "verilog/c.v"),
                ("SKIP", "verilog/d.v"), ("PASS", "verilog-ams/e.vams"), ("PASS", "netlist/f.sp")]
        self.assertEqual(suite_scores(rows), {"verilog-a": (1, 2), "verilog": (1, 2), "verilog-ams": (1, 1), "spice": (1, 1)})
        self.assertEqual(measured(["x", "On Suite VAMS-CONFORMANCE, we score Verilog-A 1/2"]),
                         ["On Suite VAMS-CONFORMANCE, we score Verilog-A 1/2"])


class WorklistTests(unittest.TestCase):
    """lrm-audit's heading, token and HTML rules."""

    def test_heading_forms(self):
        for title, expected in (("2. Lexical conventions", "2"),
                                ("2.6.1 Integer constants", "2.6.1"),
                                ("Annex C (normative)", "C"),
                                ("C.3 Lexical conventions", "C.3"),
                                ("Table 2-2: Escapes", None)):
            self.assertEqual(heading(title), expected)

    def test_tokens_preserve_semantically_significant_symbols(self):
        self.assertEqual(tokens("first\n word"), tokens("first word"))
        self.assertNotEqual(tokens("a <= b"), tokens("a < b"))
        self.assertNotEqual(tokens("1M"), tokens("1m"))
        self.assertNotEqual(tokens("x ** 2"), tokens("x * 2"))

    def test_no_lossy_hyphen_or_compatibility_folding(self):
        self.assertEqual(tokens("Verilog-\nAMS"), tokens("Verilog-AMS"))
        self.assertNotEqual(tokens("Verilog-\nAMS"), tokens("VerilogAMS"))
        self.assertNotEqual(tokens("a-\nb"), tokens("ab"))
        self.assertNotEqual(tokens("x²"), tokens("x2"))
        self.assertNotEqual(tokens("ﬁ"), tokens("fi"))
        self.assertNotEqual(tokens("a­b"), tokens("ab"))

    def test_html_excludes_navigation_but_keeps_tables_and_subheadings(self):
        parser = ChapterHTML()
        parser.feed('<head><title>ignored</title></head><nav>ignored</nav>'
                    '<h1>2. Lexical conventions</h1><h2>2.7 Strings</h2>'
                    '<p>A &lt; B</p><h3>Table 2-2</h3>'
                    '<table><tr><td>escape</td><td>value</td></tr></table>')
        text = parser.sections['2.7']['text']
        self.assertIn('A < B', text)
        self.assertIn('Table 2-2', text)
        self.assertIn('escape value', text)
        self.assertNotIn('ignored', text)

    def test_duplicate_html_heading_is_visible(self):
        parser = ChapterHTML()
        parser.feed('<h2>2.7 Strings</h2><p>first</p>'
                    '<h2>2.7 Strings again</h2>')
        self.assertEqual(parser.duplicates, ['2.7'])

    @patch.object(subprocess, "run")
    def test_pdf_front_matter_footer_and_numeric_table_cells(self, run):
        run.return_value = SimpleNamespace(stdout=(
            'Contents\n2. Lexical conventions .... 11\f'
            '1. Verilog-AMS introduction\n1.1 Scope\nsource text\n'
            '2. Lexical conventions\n2.7 Strings\n377\nbyte boundary\n'
            '12\nCopyright © 2024 Accellera\f'))
        sections, _ = pdf_sections('source.pdf')
        self.assertEqual(list(sections), ['1', '1.1', '2', '2.7'])
        self.assertIn('377', sections['2.7']['text'])
        self.assertNotIn('12\n', sections['2.7']['text'])
        self.assertEqual(sections['2.7']['page'], 2)


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

    def test_editorial_notes_do_not_add_keywords(self):
        parser = KeywordTable()
        parser.feed('<table><tr><td><code>if</code></td>'
                    '<td><code>module</code></td></tr></table>'
                    '<p>Not a keyword: <code>negedgenmos</code></p>')
        self.assertEqual(parser.words, ['if', 'module'])

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


class FigureImages(HTMLParser):
    """Every <img>'s attributes, every id, and how many inline <svg>s."""

    def __init__(self):
        super().__init__()
        self.images = []
        self.ids = []
        self.figures = set()
        self.svg_count = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "img":
            self.images.append(attrs)
        if tag == "svg":
            self.svg_count += 1
        if tag == "figure":
            self.figures.add(attrs.get("id"))
        if "id" in attrs:
            self.ids.append(attrs["id"])


def png_size(data):
    return struct.unpack(">II", data[16:24])


class SourceFigures(unittest.TestCase):
    """figures: structural guards for the PDF figure assets; visual fidelity is
    reviewed separately. The figures are not committed (they are 8 MB and the
    `figures` subcommand re-crops them from the pinned PDF), so every check but
    the PDF's own revision skips until they are generated."""

    def setUp(self):
        if self._testMethodName != "test_source_revision" and not (ROOT / "specification/figures").is_dir():
            self.skipTest("specification/figures not generated: run tools/conformance.py figures")

    def test_source_revision(self):
        self.assertEqual(hashlib.sha256(LRM_PDF.read_bytes()).hexdigest(), LRM_SHA256)

    def test_chapter_one_figures_and_convention_colors(self):
        expected = {"1-1", "1-2", "1-3"}
        self.assertEqual({key for key in LRM_FIGURES if key.startswith("1-")}, expected)
        html = (ROOT / "specification/ch1-intro.html").read_text()
        self.assertIn('.syntax b { color: #c00000; }', html)
        self.assertIn('.syntax.extension { color: #2020b0; }', html)
        self.assertIn('<div class="syntax extension">connectrules_declaration', html)

    def test_chapter_five_uses_all_source_figures(self):
        # These redraws previously changed open probe paths into wires and
        # moved the timing-event dot. Guard against silently reintroducing
        # inline substitutes; visual comparison remains a separate review.
        expected = {f"5-{n}" for n in range(1, 7)}
        self.assertEqual({key for key in LRM_FIGURES if key.startswith("5-")}, expected)
        parser = FigureImages()
        parser.feed((ROOT / "specification/ch5-analog.html").read_text())
        self.assertEqual(parser.svg_count, 0)
        for key in expected:
            self.assertEqual(parser.ids.count(f"figure-{key}"), 1)

    def test_chapter_six_crop_bounds_png_and_accessible_html(self):
        self.assertEqual(set(CH6_FIGURES), {"6-1", "6-2"})
        parser = FigureImages()
        parser.feed((ROOT / "specification/ch6-hierarchy.html").read_text())
        images = {i.get("src"): i for i in parser.images}
        for figure, (page, left, top, width, height) in CH6_FIGURES.items():
            self.assertIn(page, (151, 174))
            self.assertGreaterEqual(min(left, top), 0)
            self.assertGreater(min(width, height), 0)
            self.assertLessEqual(left + width, 612)
            self.assertLessEqual(top + height, 792)
            path = f"figures/lrm-figure-{figure}.png"
            data = (ROOT / "specification" / path).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(png_size(data), (width * FIG_SCALE, height * FIG_SCALE))
            self.assertIn(f"figure-{figure}", parser.figures)
            attrs = images[path]
            self.assertIn(f"Source Figure {figure}", attrs["alt"])
            self.assertEqual(int(attrs["width"]), width * FIG_SCALE)
            self.assertEqual(int(attrs["height"]), height * FIG_SCALE)

    def test_chapter_seven_preserves_shared_figure_captions(self):
        expected = {f"7-{n}" for n in range(1, 12)} - {"7-8"}
        self.assertEqual({key for key in LRM_FIGURES if key.startswith("7-")}, expected)
        parser = FigureImages()
        parser.feed((ROOT / "specification/ch7-mixed-signal.html").read_text())
        self.assertEqual(parser.svg_count, 0)
        # 7-8 is a source caption above the same drawing captioned 7-9 below.
        # Both remain addressable, without fabricating a separate image.
        for n in range(1, 12):
            self.assertEqual(parser.ids.count(f"figure-7-{n}"), 1)
        matches = [i for i in parser.images if i.get("src") == "figures/lrm-figure-7-9.png"]
        self.assertEqual(len(matches), 1)

    def test_chapter_nine_source_figures(self):
        expected = {f"9-{n}" for n in range(1, 5)}
        self.assertEqual({key for key in LRM_FIGURES if key.startswith("9-")}, expected)
        parser = FigureImages()
        parser.feed((ROOT / "specification/ch9-system.html").read_text())
        for key in expected:
            self.assertEqual(parser.ids.count(f"figure-{key}"), 1)
            filename = f"figures/lrm-figure-{key}.png"
            matches = [item for item in parser.images if item.get("src") == filename]
            self.assertEqual(len(matches), 1)
            self.assertTrue(matches[0].get("alt"))
            data = (ROOT / "specification" / filename).read_bytes()
            _, _, _, width, height = LRM_FIGURES[key]
            self.assertEqual(png_size(data), (width * 3, height * 3))

    def test_crops_are_inside_source_pages(self):
        for figure, (page, x, y, width, height) in LRM_FIGURES.items():
            with self.subTest(figure=figure):
                self.assertGreater(page, 0)
                self.assertLessEqual(page, 442)
                self.assertGreaterEqual(x, 0)
                self.assertGreaterEqual(y, 0)
                self.assertGreater(width, 0)
                self.assertGreater(height, 0)
                self.assertLessEqual(x + width, 612)
                self.assertLessEqual(y + height, 792)

    def test_assets_and_html_references(self):
        for figure, (_, _, _, width, height) in LRM_FIGURES.items():
            with self.subTest(figure=figure):
                filename = f"figures/lrm-figure-{figure}.png"
                data = (ROOT / "specification" / filename).read_bytes()
                self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                self.assertEqual(data[12:16], b"IHDR")
                self.assertEqual(png_size(data), (width * 3, height * 3))
                chapter = figure.split("-")[0]
                paths = list((ROOT / "specification").glob(f"ch{chapter}-*.html"))
                self.assertEqual(len(paths), 1)
                parser = FigureImages()
                parser.feed(paths[0].read_text())
                matches = [i for i in parser.images if i.get("src") == filename]
                self.assertEqual(len(matches), 1)
                self.assertTrue(matches[0].get("alt"))
                self.assertEqual(parser.ids.count(f"figure-{figure}"), 1)

    def test_chapter_eleven_source_and_assets(self):
        # Documentation integrity only: this is not an executed VPI test.
        parsed = FigureImages()
        parsed.feed((ROOT / "specification/ch11-vpi.html").read_text())
        self.assertEqual(len(parsed.ids), len(set(parsed.ids)))
        expected = {f"figures/ch11-{name}.png" for name in CH11_CROPS}
        self.assertEqual({item["src"] for item in parsed.images}, expected)
        for item in parsed.images:
            self.assertTrue(item.get("alt"))
            data = (ROOT / "specification" / item["src"]).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            name = Path(item["src"]).stem.removeprefix("ch11-")
            width, height = CH11_CROPS[name][-2:]
            self.assertEqual(png_size(data), (width * 3, height * 3))
        for clause in range(1, 26):
            self.assertIn(f"s11-6-{clause}", parsed.ids)

    def test_annex_e_source_links_and_dimensions(self):
        # Documentation integrity, not primitive simulation evidence.
        html = (ROOT / "specification/annex-e-spice.html").read_text()
        for name, (_, _, _, width, height) in ANNEX_E_CROPS.items():
            relative = f"figures/annex-e-{name}.png"
            self.assertIn(f'src="{relative}"', html)
            data = (ROOT / "specification" / relative).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(png_size(data), (width * 3, height * 3))


class SyntaxText(HTMLParser):
    """The text of every `<div class="syntax">` display, entities decoded."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.parts = []
        self.blocks = []

    def handle_starttag(self, tag, attrs):
        if tag == "div":
            if self.depth:
                self.depth += 1
            elif "syntax" in dict(attrs).get("class", "").split():
                self.depth = 1
                self.parts = []

    def handle_endtag(self, tag):
        if tag == "div" and self.depth:
            self.depth -= 1
            if not self.depth:
                self.blocks.append("".join(self.parts))

    def handle_data(self, data):
        if self.depth:
            self.parts.append(data)


def syntax_text(source):
    parser = SyntaxText()
    parser.feed(source)
    parser.close()
    if parser.depth:
        raise ValueError("Unclosed syntax display")
    return parser.blocks


# The rendered Chapter 4 syntax text from root HTML SHA256
# c452aae6c5868af5538ce84d989bb3ae83b51e3047b9157784190688dca188fe.
CH4_SYNTAX_SHA256 = "c206b78ed2fa1dbba040bb45b5056ecb6ce58f10dfce7c977f8f595a0f6f4ff3"


class LrmSource(unittest.TestCase):
    """Bounded source-review guards on specification/*.html, not grammar completeness
    proof and not proof of whole-chapter source fidelity."""

    def test_annex_a_signed_base_separates_terminals_from_meta_symbols(self):
        page = (ROOT / "specification/annex-a-syntax.html").read_text()
        for base in "dDbBoOhH":
            spelling = "<b>'</b>[<b>s</b>|<b>S</b>]<b>" + base + "</b>"
            self.assertIn(spelling, page)
            self.assertEqual(html.unescape(re.sub(r"<[^>]*>", "", spelling)), "'[s|S]" + base)
        self.assertIn("lexical character classes", page)
        self.assertIn("Editorial source note", page)

    def test_ch2_comment_delimiters_are_literals_not_repetition_notation(self):
        page = (ROOT / "specification/ch2-lexical.html").read_text()
        block = re.search(r'<div class="syntax">(.*?)</div>', page, re.S).group(1)
        # AMS2023 physical24/printed11, visually reviewed2026-09-23.
        self.assertEqual(re.findall(r"<b>(.*?)</b>", block), ["//", "/*", "*/"])
        self.assertIn("one_line_comment ::= <b>//</b> comment_text \\n", block)
        self.assertIn("block_comment ::= <b>/*</b> comment_text <b>*/</b>", block)
        self.assertIn("comment_text ::= { Any_ASCII_character }", block)
        self.assertIn("      | block_comment", block)

    def test_ch4_rendered_syntax_matches_pre_markup_root(self):
        # Guards typography-only edits; it is not proof of full LRM fidelity.
        blocks = syntax_text((ROOT / "specification/ch4-expressions.html").read_text())
        self.assertTrue(blocks)
        digest = hashlib.sha256(json.dumps(blocks, ensure_ascii=False).encode()).hexdigest()
        self.assertEqual(digest, CH4_SYNTAX_SHA256)

    def test_entities_are_not_split_by_markup(self):
        for path in sorted((ROOT / "specification").glob("*.html")):
            with self.subTest(path=path.name):
                source = path.read_text()
                self.assertIsNone(re.search(r"&(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#x[0-9a-fA-F]+)<", source))

    def test_regression_rejects_tag_stripping_before_entity_decode(self):
        good = '<div class="syntax">&zeta;</div>'
        broken = '<div class="syntax">&zeta<b>;</b></div>'
        self.assertEqual(syntax_text(good), ["ζ"])
        self.assertNotEqual(syntax_text(good), syntax_text(broken))

    def test_ch12_literal_source_entities_and_editorial_boundary(self):
        page = (ROOT / "specification/ch12-vpi-routines.html").read_text()
        rendered = html.unescape(page)
        self.assertIn("systf_data_p = &amp;(systf_data_list[0]);", rendered)
        self.assertIn("while (systf_data_p-&gt;type)", rendered)
        for name in ("callback-layout", "resistor-source-defects",
                     "sampler-source-defects", "startup-source-defects",
                     "control-source-count"):
            self.assertIn('id="editorial-' + name + '"', page)
        self.assertEqual(page.count("Editorial source note (not LRM text)."), 5)

    def test_ch12_no_numbered_hdl_fixture_claims_vpi_execution(self):
        fixtures = ROOT / "tests/fixtures/ch12_vpi_routines"
        for path in fixtures.glob("[0-9]*.va"):
            with self.subTest(path=path.name):
                self.assertNotRegex(path.read_text(), r"(?m)^//! lrm 12(?:\.|$)")


class InformativeContent(HTMLParser):
    """Glossary terms and table cells of an informative annex."""

    def __init__(self):
        super().__init__()
        self.terms = []
        self.tables = []
        self.in_term = False
        self.term = ""
        self.in_cell = False
        self.cell = ""
        self.row = []

    def handle_starttag(self, tag, attrs):
        if tag == "dt":
            self.in_term, self.term = True, ""
        elif tag == "table":
            self.tables.append([])
        elif tag == "tr":
            self.row = []
        elif tag in ("td", "th"):
            self.in_cell, self.cell = True, ""

    def handle_data(self, data):
        if self.in_term:
            self.term += data
        if self.in_cell:
            self.cell += data

    def handle_endtag(self, tag):
        if tag == "dt":
            self.terms.append(self.term)
            self.in_term = False
        elif tag in ("td", "th"):
            self.row.append(self.cell)
            self.in_cell = False
        elif tag == "tr":
            self.tables[-1].append(self.row)


class InformativeSource(unittest.TestCase):
    """Source-review guards for informative annex content, not compiler coverage."""

    def test_glossary_exact_term_inventory(self):
        expected = [
            "AMS", "behavioral description", "behavioral model", "block",
            "branch", "compact model", "component", "constitutive relationships",
            "control flow", "child module", "flow", "instance", "instantiation",
            "Kirchhoff’s Laws", "level", "model", "module", "net declaration",
            "node", "NR method", "parameter", "parameter declaration", "port",
            "potential", "primitive", "probe", "reference direction",
            "reference node", "scope", "structural definitions", "terminal",
            "Verilog-A", "Verilog-AMS",
        ]
        parsed = InformativeContent()
        parsed.feed((ROOT / "specification/annex-h-glossary.html").read_text())
        self.assertEqual(parsed.terms, expected)

    def test_history_preserves_source_gaps_and_table_cells(self):
        page = (ROOT / "specification/annex-g-changes.html").read_text()
        parsed = InformativeContent()
        parsed.feed(page)
        self.assertEqual(len(parsed.tables), 7)
        for index, table in enumerate(parsed.tables):
            for row in table:
                self.assertEqual(len(row), 4 if index == 0 else 3)
        # Printed 415 omits item 14; printed 416 omits item 13.
        self.assertNotIn("14", [row[0] for row in parsed.tables[1][1:]])
        self.assertNotIn("13", [row[0] for row in parsed.tables[2][1:]])
        # Printed 423 contains a genuinely blank Mantis row, not lost HTML.
        self.assertIn(["7893", "", ""], parsed.tables[6])
        self.assertIn("Editorial context (not LRM text)", page)
        self.assertIn("$roi()", page)  # source typo; do not silently rewrite


# ---------------------------------------------------------------------------
# obligations / metric: the requirement ledger and the conformance metric
#. The ledger's rows are the normative sentences of the
# LRM, extracted here; the metric is each row's evidence level, computed from
# the fixtures' cites and one strict run's verdicts.
# ---------------------------------------------------------------------------

LEDGER = ROOT / "tests/fixtures/conformance/OBLIGATIONS.tsv"
LEDGER_HEAD = (
    "# The AMS LRM's normative sentences: the requirement ledger.\n"
    "# Rows are extracted by `tools/conformance.py obligations --update`; a reader\n"
    "# classifies `pol`, `kind` and `oracle` and adds `declar.` rows (ordinal >= 1000,\n"
    "# hash `manual`) for rules stated without a modal verb. A changed hash means the\n"
    "# text moved, and the row's classification is reset to `?` for a re-read.\n"
    "# id\thash\tmodal\tpol\tkind\toracle\ttext\n"
)
MANUAL_ORDINAL = 1000
# First match wins, so the prohibition forms come before their positive kin.
MODALS = [
    ("shall-not", re.compile(r"\bshall not\b|\bshall never\b|\bshall neither\b")),
    ("error", re.compile(r"\bis (?:an |)(?:error|illegal)\b|\bshall be an error\b|\bare (?:errors|illegal)\b|\bnot (?:be |)(?:allowed|permitted)\b|\billegal\b"
                         r"|\berror shall be\b|\bshall (?:report|issue|flag|generate|produce) an? error\b|\bshall be (?:reported|flagged) as an? error\b")),
    ("shall", re.compile(r"\bshall\b")),
    ("must", re.compile(r"\bmust\b")),
    ("impl-defined", re.compile(r"\bimplementation[- ](?:defined|dependent|specific)\b")),
    ("unspecified", re.compile(r"\bunspecified\b|\bundefined\b")),
    ("may", re.compile(r"\bmay\b|\bis optional\b|\bare optional\b")),
]
# CLAUSES.tsv's clause kind -> the default (pol, kind) of the clause's rows.
KIND_DEFAULT = {
    "non-normative": ("0", "non-normative"),
    "optional": ("0", "optional"),
    "unspecified": ("0", "unspecified"),
    "not-supported": ("0", "not-supported"),
    "no-prohibition": ("+", "-"),
    "implementation-defined": ("+", "implementation-defined"),
    "resource-limit": ("+-", "resource-limit"),
}
INDEPENDENT_ORACLES = {"hand2", "icarus", "verilator", "ngspice", "fd", "ref", "earley", "spec-example"}
MANDATORY_KINDS = {"-", "?", "implementation-defined", "resource-limit"}


def sentences(text):
    flat = re.sub(r"\s+", " ", text).strip()
    return [s for s in re.split(r"(?<=[.!?])\s+(?=[A-Z\"“(`$])", flat) if s]


def modal(sentence):
    low = sentence.lower()
    for name, pattern in MODALS:
        if pattern.search(low):
            return name
    return None


def sentence_hash(sentence):
    return hashlib.sha256(re.sub(r"\s+", " ", sentence).strip().encode()).hexdigest()[:8]


def extract_obligations(html):
    """{clause: [(ordinal, hash, modal, sentence)]} over every numbered clause
    of the LRM HTML, in reading order within the clause."""
    out = {}
    for section, item in html.items():
        rows = []
        for sent in sentences(item["text"]):
            m = modal(sent)
            if m:
                rows.append((len(rows) + 1, sentence_hash(sent), m, sent))
        out[section] = rows
    return out


def read_ledger(path=LEDGER):
    rows = {}
    if not path.exists():
        return rows
    for line in path.read_text().split("\n"):
        if not line or line.startswith("#"):
            continue
        c = line.split("\t")
        c += [""] * (7 - len(c))
        rows[c[0]] = dict(zip(("id", "hash", "modal", "pol", "kind", "oracle", "text"), c))
    return rows


def ledger_key(row_id):
    clause, _, n = row_id.partition(":")
    return sort_key(clause) + ((0, int(n)),)


def write_ledger(rows, path=LEDGER):
    with open(path, "w") as f:
        f.write(LEDGER_HEAD)
        for rid in sorted(rows, key=ledger_key):
            r = rows[rid]
            text = r["text"].replace("\t", " ")
            f.write("\t".join([rid, r["hash"], r["modal"], r["pol"], r["kind"], r["oracle"], text]) + "\n")


def default_class(clause, m, sentence, kinds):
    """(pol, kind) before a reader looks: the clause's CLAUSES.tsv kind, a
    note's informative status, and the prohibitions that need a refusal."""
    if sentence.startswith("NOTE"):
        return "0", "non-normative"
    k = kinds.get(("ams", clause))
    if k in KIND_DEFAULT:
        return KIND_DEFAULT[k]
    if m in ("shall-not", "error"):
        return "-", "-"
    if m == "unspecified":
        return "0", "unspecified"
    if m == "impl-defined":
        return "+", "implementation-defined"
    return "?", "?"


def obligations(argv):
    """`obligations --update`: re-extract the ledger and merge it with the
    reviewed columns; `obligations --check`: exit 1 when the ledger and the
    text disagree (a new, moved or vanished sentence). Prints a census."""
    html, _ = html_sections(ROOT)
    found = extract_obligations(html)
    kinds = clause_kinds()
    old = read_ledger()
    new, moved, added = {}, [], []
    for clause, rows in found.items():
        for n, h, m, sent in rows:
            rid = f"{clause}:{n}"
            prev = old.get(rid)
            if prev and prev["hash"] == h:
                new[rid] = prev
                continue
            pol, kind = default_class(clause, m, sent, kinds)
            if prev:
                moved.append(rid)
            else:
                added.append(rid)
            new[rid] = {"id": rid, "hash": h, "modal": m, "pol": pol, "kind": kind, "oracle": "?", "text": sent[:400]}
        # A clause no modal verb reaches still states something: a placeholder
        # a reader replaces with the clause's rules.
        if not rows and kinds.get(("ams", clause)) != "non-normative":
            rid = f"{clause}:{MANUAL_ORDINAL}"
            if rid not in old:
                pol, kind = KIND_DEFAULT.get(kinds.get(("ams", clause)), ("?", "?"))
                new[rid] = {"id": rid, "hash": "manual", "modal": "declar.", "pol": pol, "kind": kind,
                            "oracle": "?", "text": f"(no modal sentence in §{clause} {html[clause]['title']}; state its rules here)"}
    for rid, r in old.items():
        if r["hash"] == "manual":
            new[rid] = r  # a reader's row survives every re-extraction
    vanished = sorted(set(old) - set(new), key=ledger_key)
    print(f"ledger: {len(new)} rows over {len(found)} clauses; "
          f"{len(added)} new, {len(moved)} moved, {len(vanished)} vanished")
    for rid in moved:
        print(f"  moved: {rid}")
    for rid in vanished:
        print(f"  vanished: {rid}")
    if "--update" in argv:
        write_ledger(new)
        return 0
    return 1 if (added or moved or vanished) else 0


SUBCOMMANDS["obligations"] = obligations


def fixture_tags(path):
    """The directive lines the metric reads: lrm cites with their polarity,
    reject-only (and reject-run, which is always exclusive), neighbours,
    xfail. A `.c` fixture's polarity is per line
    (`lrm` / `lrm-reject`)."""
    tags = {"cites": [], "reject": False, "only": False, "neighbours": [], "xfail": False, "c": path.suffix == ".c",
            # A digital case judged against its `.expected.txt` byte for byte.
            "golden": path.suffix == ".v" and path.with_suffix(".expected.txt").exists()}
    lines = path.read_text(errors="replace").split("\n")
    rejecting = any(re.match(r"\s*//!\s*reject(-only|-run)?\s", ln) for ln in lines)
    for line in lines:
        line = line.strip()
        if not line.startswith("//!"):
            continue
        word, _, rest = line[3:].strip().partition(" ")
        rest = rest.strip()
        if word == "lrm":
            tags["cites"].append((rest, "neg" if rejecting else "pos"))
        elif word == "lrm-reject":
            tags["cites"].append((rest, "neg"))
        elif word == "reject":
            tags["reject"] = True
        elif word in ("reject-only", "reject-run"):
            # A run-time refusal (`//! reject-run`) is always exclusive: every
            # `error[` line the run prints must match (tests/suite.zig's Analog).
            tags["reject"] = tags["only"] = True
        elif word == "neighbour":
            # Normalise `..` so a legal twin in another chapter resolves to the
            # same root-relative key the verdicts file uses.
            tags["neighbours"].append(os.path.relpath(os.path.normpath(path.parent / rest), ROOT / "tests/fixtures"))
        elif word == "xfail":
            tags["xfail"] = True
    return tags


def vpi_runs():
    """{c path under tests/fixtures: 'pass' | 'xfail'} for build.zig's
    `vpiRuns`, the `.c` fixtures `zig build test` runs in-process: those with
    a `//! design` line. A `.c` that only compiles is not evidence
    and is absent here."""
    out = {}
    for path in fixture_files("*.c"):
        text = path.read_text(errors="replace")
        if re.search(r"(?m)^//! design ", text):
            # `//! refuse`: the run is refused by name, and build.zig holds it
            # to that exit and stdout, so a met refusal passes like any run.
            out[path.relative_to(FIXTURES).as_posix()] = "xfail" if re.search(r"(?m)^//! xfail ", text) else "pass"
    return out


def read_verdicts(path):
    out = {}
    for line in Path(path).read_text().split("\n"):
        if "\t" in line:
            v, p = line.split("\t", 1)
            out[p] = v
    return out


def levels(ledger, fixtures, verdicts, perturbed, killed, oracles=None):
    """{row id: level} and the unattributed failures {clause: [fixture]}.
    `fixtures` is {path: tags}; `verdicts`, `perturbed` are {path: verdict};
    `killed` is the set of row ids a mutation run killed a mutant for;
    `oracles` is {path: [independent oracle that agreed]}."""
    oracles = oracles or {}
    by_clause = {}
    for rid in ledger:
        by_clause.setdefault(rid.partition(":")[0], []).append(rid)
    exact, bare = {}, {}
    for path, t in fixtures.items():
        for cite, side in t["cites"]:
            target = exact if ":" in cite else bare
            target.setdefault(cite, []).append((path, side))
    # A bare cite of a one-row clause is unambiguous: it is that row's.
    for clause, items in bare.items():
        if len(by_clause.get(clause, [])) == 1:
            exact.setdefault(by_clause[clause][0], []).extend(items)

    def passed(p):
        return verdicts.get(p) == "pass"

    def failing(p):
        return verdicts.get(p) in ("fail", "xfail")

    def can_fail(p, side):
        t = fixtures[p]
        if t.get("specialized"):
            # Exact named assertion, registered and executed by the report.
            return True
        if t["c"]:
            # A C check is a condition with no want to perturb; the run's
            # exact stdout is the contract, and E5's mutants are its proof.
            return side == "pos" or any(s == "pos" for _, s in t["cites"])
        if side == "pos" and t.get("golden"):
            # A digital transcript is compared whole against its golden: any
            # output the rule changes fails it, so there is nothing to perturb.
            return True
        if side == "pos":
            return perturbed.get(p) == "pass"
        return t["only"] and bool(t["neighbours"]) and all(passed(n) for n in t["neighbours"])

    out, unattributed = {}, {}
    for rid, r in ledger.items():
        clause = rid.partition(":")[0]
        mine = exact.get(rid, [])
        if any(failing(p) for p, _ in mine):
            out[rid] = "F"
            continue
        level = "E1" if mine or bare.get(clause) else "E0"
        good = [(p, side) for p, side in mine if passed(p)]
        if good:
            level = "E2"
            pos = [p for p, side in good if side == "pos" and can_fail(p, side)]
            neg = [p for p, side in good if side == "neg" and can_fail(p, side)]
            need = r["pol"]
            if (need == "+" and pos) or (need == "-" and neg) or (need == "+-" and pos and neg):
                level = "E3"
                judged = r["oracle"] in INDEPENDENT_ORACLES or any(oracles.get(p) for p in pos + neg)
                if judged:
                    level = "E4"
                    if rid in killed:
                        level = "E5"
        out[rid] = level
    for clause, items in bare.items():
        bad = sorted({p for p, _ in items if failing(p)})
        if bad and len(by_clause.get(clause, [])) != 1:
            unattributed[clause] = bad
    return out, unattributed


def read_oracles():
    """{fixture: [engine]} from the independent engines' agreement tables:
    tests/fixtures/ieee1364/VERILATOR.tsv (`agrees` = yes) and any
    tests/fixtures/conformance/ORACLES.tsv rows `<fixture>\t<engine>` (iverilog, ngspice,
    ...). Agreement is evidence, not authority."""
    out = {}
    ver = ROOT / "tests/fixtures/ieee1364/VERILATOR.tsv"
    if ver.exists():
        for line in ver.read_text().split("\n"):
            c = line.split("\t")
            if len(c) > 4 and not line.startswith("#") and c[4] == "yes":
                out.setdefault("ieee1364/" + c[0], []).append("verilator")
    ica = ROOT / "tests/fixtures/conformance/ICARUS.tsv"
    if ica.exists():
        for line in ica.read_text().split("\n"):
            c = line.split("\t")
            if len(c) > 4 and not line.startswith("#") and c[4] == "yes":
                out.setdefault(c[0], []).append("icarus")
    extra = ROOT / "tests/fixtures/conformance/ORACLES.tsv"
    if extra.exists():
        for line in extra.read_text().split("\n"):
            c = line.split("\t")
            if len(c) >= 2 and not line.startswith("#"):
                out.setdefault(c[0], []).append(c[1])
    return out


def chapter_of(clause):
    head = clause.split(".")[0]
    return f"ch{head}" if head.isdigit() else f"{head}"


def metric(argv):
    """`metric --verdicts=F [--digital=F] [--perturbed=F] [--killed=F]
    [--levels=OUT]`: the evidence-level table. F files are `zig build suite
    -- --strict --verdicts=F` (and `--perturb --verdicts=F`) outputs;
    `--digital` is `zig build suite -- devices --verdicts=F`'s, the digital
    runner's cases (`.v` with a golden or `// digital-runner: reject`), which
    the .va suite never collects. `--killed` is one row id per line.
    `--levels` writes `<id>\t<level>`, the ratchet file."""
    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    if "verdicts" not in opts:
        print("metric: --verdicts=<file> from a strict run is required", file=sys.stderr)
        return 2
    ledger = read_ledger()
    if not ledger:
        print("metric: no ledger; run `obligations --update` first", file=sys.stderr)
        return 2
    root = FIXTURES
    runs = vpi_runs()
    paths = fixture_files("*.va", "*.v") + [root / c for c in sorted(runs)]
    fixtures = {str(p.relative_to(root)): fixture_tags(p) for p in paths}
    fixtures = {p: t for p, t in fixtures.items() if t["cites"] or t["reject"]}
    verdicts = read_verdicts(opts["verdicts"])
    # The digital runner's cases: a disjoint set of paths from the .va suite's.
    if "digital" in opts:
        for path, v in read_verdicts(opts["digital"]).items():
            verdicts.setdefault(path, v)
    # A declaration is not an execution result. VPI markers are emitted only
    # after the build checks the application's exit and exact output.
    if "specialized" in opts:
        for result in sorted(Path(opts["specialized"]).glob("vpi--*.tsv")):
            verdicts.update(read_verdicts(result))
    perturbed = read_verdicts(opts["perturbed"]) if "perturbed" in opts else {}
    killed = set(Path(opts["killed"]).read_text().split()) if "killed" in opts else killed_rows(ledger)
    oracles = read_oracles()
    lv, unattributed = levels(ledger, fixtures, verdicts, perturbed, killed, oracles)
    order = ["E0", "E1", "E2", "E3", "E4", "E5", "F"]
    table = {}
    for rid, level in lv.items():
        ch = chapter_of(rid.partition(":")[0])
        mandatory = ledger[rid]["kind"] in MANDATORY_KINDS
        t = table.setdefault(ch, {"rows": 0, "mand": 0, **{k: 0 for k in order}, "unattr": 0})
        t["rows"] += 1
        if mandatory:
            t["mand"] += 1
            t[level] += 1
    for clause in unattributed:
        table.setdefault(chapter_of(clause), {"rows": 0, "mand": 0, **{k: 0 for k in order}, "unattr": 0})["unattr"] += 1

    def keyf(ch):
        h = ch[2:] if ch.startswith("ch") else ch
        return (0, int(h)) if h.isdigit() else (1, h)

    total = {"rows": 0, "mand": 0, **{k: 0 for k in order}, "unattr": 0}
    print("CONFORMANCE — mandatory rows by evidence level; F = known nonconformance")
    print("block\trows\tmand\t" + "\t".join(order) + "\tF?\tproven\tnot-refuted")
    for ch in sorted(table, key=keyf):
        t = table[ch]
        for k in total:
            total[k] += t[k]
        print(row_line(f"AMS {ch}", t, order))
    print(row_line("AMS total", total, order))
    for clause, paths in sorted(unattributed.items(), key=lambda kv: sort_key(kv[0])):
        print(f"  F? §{clause}: failing fixture(s) cite the clause, not a sentence: {', '.join(paths)}")
    if "levels" in opts:
        with open(opts["levels"], "w") as f:
            for rid in sorted(lv, key=ledger_key):
                f.write(f"{rid}\t{lv[rid]}\n")
    return 0


def row_line(name, t, order):
    if not t["mand"]:
        return f"{name}\t{t['rows']}\t0\t" + "\t".join("0" for _ in order) + f"\t{t['unattr']}\tn/a\tn/a"
    mand = t["mand"]
    # Conservative: an unattributed failing clause costs at least one row.
    refuted = t["F"] + t["unattr"]
    return (f"{name}\t{t['rows']}\t{t['mand']}\t" + "\t".join(str(t[k]) for k in order)
            + f"\t{t['unattr']}\t{pct(t['E5'], mand)}\t{pct(t['mand'] - refuted, mand)}")


SUBCOMMANDS["metric"] = metric


VERDICTS = ROOT / "tests/fixtures/conformance/VERDICTS.tsv"
LEVELS = ROOT / "tests/fixtures/conformance/LEVELS.tsv"
STEPS = ROOT / "tests/fixtures/conformance/STEPS.txt"


def ratchet(argv):
    """`ratchet --verdicts=F [--levels=F] [--update]`: the run's per-fixture
    verdicts (and per-row levels) against the committed tests/fixtures/conformance/VERDICTS.tsv and
    tests/fixtures/conformance/LEVELS.tsv. Any difference fails, a fix as much as a regression, so the
    committed files are always this tree's truth and every change to them is
    reviewed by name.
    `--update` writes the run's files over the committed ones."""
    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    if "verdicts" not in opts:
        print("ratchet: --verdicts=<file> is required", file=sys.stderr)
        return 2
    pairs = [(Path(opts["verdicts"]), VERDICTS)]
    if "levels" in opts:
        pairs.append((Path(opts["levels"]), LEVELS))
    if "--update" in argv:
        for new, committed in pairs:
            committed.write_text(new.read_text())
            print(f"ratchet: wrote {committed.relative_to(ROOT)}")
        return 0
    status = 0
    for new, committed in pairs:
        old = committed.read_text().splitlines() if committed.exists() else []
        diff = list(difflib.unified_diff(old, new.read_text().splitlines(),
                                         str(committed.relative_to(ROOT)), "this run", lineterm="", n=0))
        if diff:
            status = 1
            print("\n".join(diff))
    if status:
        print("ratchet: the run differs from the committed lists. A regression is a bug; "
              "an improvement is committed with `ratchet --update`.")
    else:
        print("ratchet: verdicts and levels match the committed lists")
    return status


SUBCOMMANDS["ratchet"] = ratchet


def steps(argv):
    """`steps [--update]`: `zig build -l`'s step names against tests/fixtures/conformance/STEPS.txt.
    A step that disappears takes its tests with it and says nothing, which is
    how `2cc1c08` lost twelve (CLAUSE-AUDIT.md, provenance)."""
    out, code = run("zig", "build", "-l")
    if code:
        print(out, file=sys.stderr)
        return 2
    names = sorted({line.split()[0] for line in out.splitlines() if line.startswith("  ") and line.split()})
    if "--update" in argv:
        STEPS.write_text("\n".join(names) + "\n")
        print(f"steps: wrote {len(names)} names to {STEPS.relative_to(ROOT)}")
        return 0
    old = STEPS.read_text().split() if STEPS.exists() else []
    gone, new = sorted(set(old) - set(names)), sorted(set(names) - set(old))
    for n in gone:
        print(f"steps: GONE {n}")
    for n in new:
        print(f"steps: new {n}")
    if gone or new:
        print("steps: commit tests/fixtures/conformance/STEPS.txt with `steps --update` once the change is intended")
        return 1
    print(f"steps: {len(names)} build steps, as committed")
    return 0


SUBCOMMANDS["steps"] = steps



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
    the stronger claim costs nothing and closes CLAUSE-AUDIT.md §6.4."""
    if not argv:
        print("promote-reject-only: give the probe run's stderr", file=sys.stderr)
        return 2
    done = 0
    for line in Path(argv[0]).read_text().split("\n"):
        if not line.startswith("ONLY-OK "):
            continue
        path = Path(line[len("ONLY-OK "):].strip())
        path = FIXTURES / str(path).split("/tests/fixtures/", 1)[-1]
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


def link_sentences(argv):
    """`link-sentences [--apply]`: a fixture that cites clause C and quotes,
    in its header, a sentence of C's ledger rows gets `//! lrm C:n` for each
    sentence it quotes. A quote must cover the sentence's first 12 words or
    the whole of a shorter sentence, so a passing mention never links."""
    apply = "--apply" in argv
    ledger = read_ledger()
    rows_of = {}
    for rid, r in ledger.items():
        clause, _, n = rid.partition(":")
        if r["hash"] != "manual":
            rows_of.setdefault(clause, []).append((rid, norm(r["text"])))
    added = files = 0
    for path in fixture_files("*.va", "*.v"):
        text = path.read_text(errors="replace")
        cites = re.findall(r"(?m)^\s*//!\s*lrm\s+(\S+)\s*$", text)
        have = set(cites)
        prose = norm(header_text(text))
        new = []
        for c in cites:
            if ":" in c:
                continue
            for rid, sent in rows_of.get(c, []):
                words = sent.split()
                key = " ".join(words[:12])
                if len(words) >= 5 and key in prose and rid not in have and rid not in new:
                    new.append(rid)
        if not new:
            continue
        files += 1
        added += len(new)
        if apply:
            lines = text.split("\n")
            for rid in new:
                clause = rid.partition(":")[0]
                lines = insert_after(lines, lambda ln, c=clause: re.match(rf"\s*//!\s*lrm\s+{re.escape(c)}(?::\d+)?\s*$", ln), [f"//! lrm {rid}"])
            path.write_text("\n".join(lines))
    print(f"link-sentences: {added} sentence cites in {files} fixtures{' (written)' if apply else ''}")
    return 0


SUBCOMMANDS["link-sentences"] = link_sentences


class FixtureLinking(unittest.TestCase):
    def test_header_text_joins_wrapped_quotes(self):
        src = '// "The flow shall\n//  be zero."\n//! lrm 5.1\nmodule m; endmodule\n'
        self.assertEqual(norm(header_text(src)), "the flow shall be zero")

    def test_insert_after_last_matching_line(self):
        lines = ["//! lrm 5.1", "//! lrm 5.2", "//! reject E1", "module m;"]
        out = insert_after(lines, lambda ln: ln.startswith("//! lrm 5.1"), ["//! lrm 5.1:2"])
        self.assertEqual(out[1], "//! lrm 5.1:2")


MUTANTS = ROOT / "tests/fixtures/conformance/MUTANTS.tsv"
MUT_TREE = ROOT.parent / "vera-mut"
VQ = ROOT.parent / ".build-queue/vq"
# One mutation per site: (name, pattern, replacement). Spaces around the
# operators keep `<<`, `=>`, `->` and `<=` inside other tokens untouched.
MUTATORS = [
    ("eq->ne", re.compile(r" == "), " != "),
    ("ne->eq", re.compile(r" != "), " == "),
    ("lt->le", re.compile(r" < "), " <= "),
    ("le->lt", re.compile(r" <= "), " < "),
    ("gt->ge", re.compile(r" > "), " >= "),
    ("ge->gt", re.compile(r" >= "), " > "),
    ("and->or", re.compile(r" and "), " or "),
    ("or->and", re.compile(r" or "), " and "),
    ("true->false", re.compile(r"\btrue\b"), "false"),
    ("false->true", re.compile(r"\bfalse\b"), "true"),
    ("+1->-1", re.compile(r" \+ 1\b"), " - 1"),
    ("-1->+1", re.compile(r" - 1\b"), " + 1"),
]


def header_clauses(text):
    """The LRM clauses a source file's `//!` header names (`§5.6.1`, `LRM:
    5.6, 9.4`): the rules its code implements, which its mutants are judged by."""
    head = "\n".join(ln for ln in text.split("\n")[:40] if ln.startswith("//!"))
    return sorted(set(re.findall(r"(?:§|\b)((?:[1-9][0-9]?|[A-H])(?:\.[0-9]+)+)\b", head)), key=sort_key)


def mutation_sites(text):
    sites = []
    for i, line in enumerate(text.split("\n")):
        code = line.split("//")[0]
        t = code.strip()
        if not t or t.startswith("\\\\") or '"' in code:
            continue
        for name, pat, rep in MUTATORS:
            if pat.search(code):
                sites.append((i, name))
    return sites


def apply_mutant(text, line_no, name):
    lines = text.split("\n")
    pat, rep = next((p, r) for n, p, r in MUTATORS if n == name)
    code, sep, comment = lines[line_no].partition("//")
    lines[line_no] = pat.sub(rep, code, count=1) + sep + comment
    return "\n".join(lines)


def cites_index():
    idx = {}
    for p in fixture_files("*.va", "*.v"):
        t = fixture_tags(p)
        if t["xfail"]:
            continue  # a known gap is not evidence a mutant can be judged by
        for cite, _ in t["cites"]:
            idx.setdefault(cite.partition(":")[0], set()).add(str(p.relative_to(FIXTURES)))
    return idx


def load_vq():
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("vq", str(VQ))
    spec = importlib.util.spec_from_loader("vq", loader)
    vq = importlib.util.module_from_spec(spec)
    loader.exec_module(vq)
    return vq


def mutate(argv):
    """`mutate [--files=a.zig,b.zig] [--per-file=N] [--max-fixtures=K] [--seed=S]`:
    mutation testing. For each source file, up to N mutants at sites
    chosen by seed; each is built incrementally in W1 (`vq check -- ...`,
    so it queues like any build) and judged by the strict suite over the
    fixtures that cite the file's header clauses (at most K). A mutant some
    fixture fails is KILLED: that fixture's evidence can fail when the code
    is wrong (the metric's E5). A survivor names a check that cannot see
    that change. Results are appended to tests/fixtures/conformance/MUTANTS.tsv with the
    file's hash, so a kill stops counting once the file changes."""
    import random
    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    per_file, max_fx = int(opts.get("per-file", 4)), int(opts.get("max-fixtures", 40))
    rng = random.Random(int(opts.get("seed", 1)))
    vq = load_vq()
    if not (MUT_TREE / ".git").exists():
        subprocess.run(["git", "-C", str(ROOT), "worktree", "add", "--detach", str(MUT_TREE), "HEAD"], check=True)
    vq.sync(str(ROOT), str(MUT_TREE))
    idx = cites_index()
    if "files" in opts:
        files = [ROOT / f for f in opts["files"].split(",")]
    else:
        files = sorted(p for p in (ROOT / "lib").rglob("*.zig") if not p.name.endswith("test.zig"))
    work = MUT_TREE / ".zig-cache" / "mutate"
    work.mkdir(parents=True, exist_ok=True)
    # A kill counts only against fixtures the unmutated build passes, in the
    # same worker and mode (W1, Debug): a fixture failing for its own reason
    # would otherwise "kill" every mutant it judges.
    baseline = work / "baseline.tsv"
    if not baseline.exists() or "--rebaseline" in argv:
        subprocess.run([str(VQ), "check", "--worker", "w3", str(MUT_TREE), "--", "sh", "-c",
                        f'"$VQ_SUITE" "$VQ_VERA" --strict --verdicts={baseline} >/dev/null 2>&1'])
    passing = {ln.split("\t", 1)[1] for ln in baseline.read_text().split("\n") if ln.startswith("pass\t")}
    print(f"mutate: baseline {len(passing)} passing fixtures", flush=True)
    if not MUTANTS.exists():
        MUTANTS.write_text("# Written by `tools/conformance.py mutate`.\n"
                           "file\tsha\tline\top\toutcome\tkilled_by\n")
    for path in files:
        text = path.read_text()
        rel = str(path.relative_to(ROOT))
        clauses = header_clauses(text)
        fixtures = sorted(set().union(*(idx.get(c, set()) for c in clauses)) & passing) if clauses else []
        if not fixtures:
            print(f"mutate {rel}: no fixture cites its header clauses; skipped")
            continue
        if len(fixtures) > max_fx:
            fixtures = sorted(rng.sample(fixtures, max_fx))
        listing = work / "list.txt"
        listing.write_text("\n".join(fixtures) + "\n")
        sites = mutation_sites(text)
        rng.shuffle(sites)
        sha = hashlib.sha256(text.encode()).hexdigest()[:8]
        target = MUT_TREE / rel
        done = {tuple(ln.split("\t")[:4]) for ln in MUTANTS.read_text().split("\n")}
        for line_no, name in sites[:per_file]:
            if (rel, sha, str(line_no + 1), name) in done:
                continue  # already judged against this exact file
            target.write_text(apply_mutant(text, line_no, name))
            verdicts = work / "verdicts.tsv"
            verdicts.unlink(missing_ok=True)
            r = subprocess.run([str(VQ), "check", "--worker", "w3", str(MUT_TREE), "--", "sh", "-c",
                                f'"$VQ_SUITE" "$VQ_VERA" --strict --list={listing} --verdicts={verdicts} >/dev/null 2>&1'],
                               capture_output=True, text=True)
            if not verdicts.exists():
                # The rebuild failed: a mutant that does not compile is
                # stillborn; one the unit tests reject is killed by them.
                log = r.stdout + r.stderr
                if re.search(r"\.zig:\d+:\d+: error:|compilation errors", log):
                    outcome, by = "stillborn", ""
                elif re.search(r"FAILED|failed;|XPASS|MEMORY LEAK", log):
                    outcome, by = "killed", "unit:" + ",".join(sorted(set(re.findall(r" - (.{0,60}?)\s+FAILED", log))))[:200]
                else:
                    # Neither a compile error nor a test failure: the worker
                    # itself broke (2026-10-08: W3's watch died and 197
                    # mutants were recorded stillborn). Record nothing.
                    target.write_text(text)
                    print(f"mutate: worker failed on {rel}:{line_no + 1}; stopping\n{log[-2000:]}", file=sys.stderr)
                    return 1
            else:
                failed = [ln.split("\t", 1)[1] for ln in verdicts.read_text().split("\n") if ln.startswith(("fail\t", "xfail\t"))]
                outcome, by = ("killed", ",".join(failed)) if failed else ("survived", "")
            with open(MUTANTS, "a") as f:
                f.write(f"{rel}\t{sha}\t{line_no + 1}\t{name}\t{outcome}\t{by}\n")
            print(f"mutate {rel}:{line_no + 1} {name}: {outcome}{' by ' + by[:120] if by else ''}", flush=True)
        target.write_text(text)
    return 0


SUBCOMMANDS["mutate"] = mutate


def killed_rows(ledger):
    """Row ids with E5 evidence: a passing fixture that cites the row and that
    killed a mutant of a file whose header names the row's clause, recorded
    against the file as it is now (tests/fixtures/conformance/MUTANTS.tsv's hash)."""
    if not MUTANTS.exists():
        return set()
    out = set()
    by_clause = {}
    for rid in ledger:
        by_clause.setdefault(rid.partition(":")[0], []).append(rid)
    for line in MUTANTS.read_text().split("\n"):
        c = line.split("\t")
        if len(c) < 6 or c[4] != "killed":
            continue
        src = ROOT / c[0]
        if not src.exists() or hashlib.sha256(src.read_text().encode()).hexdigest()[:8] != c[1]:
            continue  # the code moved since; the kill no longer describes it
        clauses = set(header_clauses(src.read_text()))
        for fx in c[5].split(","):
            p = FIXTURES / fx
            if not p.exists():
                continue
            for cite, _ in fixture_tags(p)["cites"]:
                clause = cite.partition(":")[0]
                if clause not in clauses:
                    continue
                if ":" in cite:
                    out.add(cite)
                elif len(by_clause.get(clause, [])) == 1:
                    out.add(by_clause[clause][0])
    return out


# ---------------------------------------------------------------------------
# adversarial, determinism: input-size limits and device-text determinism
# ---------------------------------------------------------------------------

ADVERSARIAL = ROOT / "tests/fixtures/conformance/ADVERSARIAL.tsv"


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


def adversarial_verdict(rc, err):
    """L10's oracle: exit 0, or a refusal that names its diagnostic. A signal,
    a timeout, or an exit 1 that names no code is a finding."""
    import signal
    if rc is None:
        return "timeout"
    if rc < 0:
        return "signal " + signal.Signals(-rc).name
    if rc == 0:
        return "ok"
    return "named" if re.search(rb"(?m)^error\[E\d{4}\]", err) else "unnamed"


def adversarial_cases():
    """name -> a legal Verilog-A source, so exit 0 is the plain good answer and
    a named limit diagnostic the other."""
    ports = "(p, n);\n  inout p, n;\n  electrical p, n;\n"
    head = "module top" + ports

    def analog(body, decls=""):
        return f"{head}{decls}  analog begin\n{body}\n  end\nendmodule\n"

    def leaf(name):
        return f"module {name}{ports}  analog I(p, n) <+ 1.0e-3 * V(p, n);\nendmodule\n"

    c = {"control_resistor": leaf("top")}  # the harness itself: must be `ok`
    for k in (3, 4, 5):
        n = 10 ** k
        c[f"expr_nesting_1e{k}"] = analog("    I(p, n) <+ " + "(" * n + "V(p, n)" + " + 1.0)" * n + ";")
    c["begin_nesting_1e4"] = analog("begin " * 10 ** 4 + "I(p, n) <+ V(p, n);" + " end" * 10 ** 4)
    c["statements_1e5"] = analog("    x = V(p, n);\n" + "    x = 0.5 * x + V(p, n);\n" * 10 ** 5 + "    I(p, n) <+ x;",
                                 "  real x;\n")
    c["generate_1e6"] = (head + "  genvar i;\n  generate for (i = 0; i < 1000000; i = i + 1) begin : g\n"
                         "    analog I(p, n) <+ 1.0e-12 * V(p, n);\n  end\n  endgenerate\nendmodule\n")
    c["literal_65536_bit"] = analog(f"    I(p, n) <+ (65536'b{'1' * 65536} & 1) * V(p, n);")
    c["macro_self_recursive"] = "`define A `A\n" + analog("    I(p, n) <+ `A * V(p, n);")
    c["macro_mutual_recursive"] = "`define A `B\n`define B `A\n" + analog("    I(p, n) <+ `A * V(p, n);")
    for k in (4, 5):
        n = 10 ** k
        chain = "".join(f"`define M{i} `M{i + 1}\n" for i in range(n)) + f"`define M{n} 1.0e-3\n"
        c[f"macro_chain_1e{k}"] = chain + analog("    I(p, n) <+ `M0 * V(p, n);")
    # 2^40 tokens if expanded naively: the macro analogue of the billion laughs.
    laughs = "`define L0 1.0\n" + "".join(f"`define L{i} (`L{i - 1} + `L{i - 1})\n" for i in range(1, 41))
    c["macro_doubling_2e40"] = laughs + analog("    I(p, n) <+ `L40 * V(p, n);")
    c["modules_1e4"] = "".join(leaf(f"m{i}") for i in range(10 ** 4)) + head + "".join(
        f"  m{i} u{i}(p, n);\n" for i in range(10 ** 4)) + "endmodule\n"
    c["hierarchy_1e3_deep"] = "".join(f"module m{i}{ports}  m{i + 1} u(p, n);\nendmodule\n" for i in range(10 ** 3)) + leaf(
        f"m{10 ** 3}")
    return c


def adversarial(argv):
    """`adversarial [[NAME=]VERA ...]`: L10's adversarial sizes (deep
    expressions, `begin` and macro nesting, huge statement, generate, module
    and hierarchy counts, a 64k-bit literal) through `vera --check` under
    `ulimit -v 4194304` and a wall-clock budget -> tests/fixtures/conformance/ADVERSARIAL.tsv.
    Oracle: exit 0 or a named diagnostic; never a signal, a timeout, or an
    unnamed failure. Exit 1 when any row breaks it."""
    import concurrent.futures
    import shutil
    import tempfile
    # Four children at once, each capped at 4 GiB of address space (its zig
    # type-check child too); a run under `vq run --mem 8G` can still be killed
    # by the cgroup, so a SIGKILL is retried alone before it is believed.
    AS_KIB, TIMEOUT_S, JOBS = 4194304, 300, 4
    work = Path(tempfile.mkdtemp(prefix="vera-adversarial-"))
    cases = adversarial_cases()
    for name, src in cases.items():
        (work / f"{name}.va").write_text(src)
    bins = binaries(argv)
    cwd = {name: work / f"b{i}" for i, (name, _) in enumerate(bins)}
    for d in cwd.values():
        d.mkdir()  # each binary's --check writes .zig-cache/vera-check/<case> in its cwd

    def one(job):
        (bname, vera), case = job
        cmd = [vera, "--check", "--contract", str(ROOT / "lib/contract.zig"), str(work / f"{case}.va")]
        rc, _, err, secs = bounded(cmd, cwd[bname], TIMEOUT_S, AS_KIB)
        return job, rc, err, secs

    jobs = [(b, case) for case in cases for b in bins]
    with concurrent.futures.ThreadPoolExecutor(JOBS) as pool:
        results = list(pool.map(one, jobs))
    results = [one(r[0]) if r[1] == -9 else r for r in results]  # alone, see above
    rows, bad = [], 0
    for ((bname, _), case), rc, err, secs in results:
        v = adversarial_verdict(rc, err)
        bad += v not in ("ok", "named")
        lines = err.decode("utf-8", "replace").replace(str(work) + "/", "").splitlines()
        note = next((ln for ln in lines if ln.startswith(("error", "thread", "panic", "Segmentation"))), lines[0] if lines else "")
        exit_ = "-" if rc is None else str(rc)
        rows.append(f"{case}\t{bname}\t{len(cases[case])}\t{exit_}\t{secs:.1f}\t{v}\t{note[:200].replace(chr(9), ' ')}\n")
    shutil.rmtree(work, ignore_errors=True)
    ADVERSARIAL.write_text(
        "# Written by `tools/conformance.py adversarial`: each input through\n"
        f"# `vera --check` under `ulimit -v {AS_KIB}` and a {TIMEOUT_S} s budget. verdict: ok (exit 0), named\n"
        "# (refused with an error[Ennnn] code), else a finding: signal, timeout, unnamed (exit 1, no code).\n"
        "# bytes is the input's size; note is the first error line.\n"
        "case\tbinary\tbytes\texit\tseconds\tverdict\tnote\n" + "".join(rows))
    print(f"adversarial: {len(rows) - bad} / {len(rows)} runs within the oracle -> {ADVERSARIAL.relative_to(ROOT)}",
          file=sys.stderr)
    return 1 if bad else 0


SUBCOMMANDS["adversarial"] = adversarial


def determinism(argv):
    """`determinism [[NAME=]VERA ...]`: L11. `vera --emit-zig` on every .va
    fixture, per binary twice from the repo root (relative paths) and once from
    another cwd (absolute paths). Every run of every binary must give the same
    exit, the same device text byte for byte, and the same diagnostics once the
    repo's absolute path is stripped. Prints each difference; exit 1 if any."""
    import concurrent.futures
    import tempfile
    elsewhere = tempfile.mkdtemp(prefix="vera-determinism-")
    bins = binaries(argv)
    root = str(ROOT).encode() + b"/"

    def runs(f):
        """The fixture's differences from the first run, compared here so a
        worker holds one fixture's devices at a time."""
        d = os.path.dirname(f)
        rel = ["--emit-zig", "-I", "tests/fixtures", "-I", d, f]
        abs_ = ["--emit-zig", "-I", str(FIXTURES), "-I", str(ROOT / d), str(ROOT / f)]
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


class Adversarial(unittest.TestCase):
    def test_verdict_names_only_a_coded_refusal(self):
        self.assertEqual(adversarial_verdict(0, b""), "ok")
        self.assertEqual(adversarial_verdict(1, b"warning: x\nerror[E0420]: genvar loop\n"), "named")
        self.assertEqual(adversarial_verdict(1, b"error: codegen failed: OutOfMemory\n"), "unnamed")
        self.assertEqual(adversarial_verdict(-11, b""), "signal SIGSEGV")
        self.assertEqual(adversarial_verdict(None, b""), "timeout")


class Mutation(unittest.TestCase):
    def test_sites_skip_comments_strings_and_runner_text(self):
        src = 'if (a == b) x();\n// a == b\nconst s = "a == b";\n    \\\\ if (a == b)\n'
        self.assertEqual(mutation_sites(src), [(0, "eq->ne")])

    def test_apply_changes_one_site_and_keeps_the_comment(self):
        self.assertEqual(apply_mutant("if (a < b and c < d) x(); // a < b", 0, "lt->le"),
                         "if (a <= b and c < d) x(); // a < b")

    def test_header_clauses(self):
        self.assertEqual(header_clauses("//! Lowering.\n//! LRM: §5.6.1, §9.4, A.8.3.\nconst x = 1;\n"), ["5.6.1", "9.4", "A.8.3"])


POLS = {"+", "-", "+-", "0"}
KINDS = {"-", "optional", "implementation-defined", "resource-limit", "unspecified", "non-normative"}


def read_tsv(path):
    if not Path(path).exists():
        return []
    lines = [ln for ln in Path(path).read_text().split("\n") if ln and not ln.startswith("#")]
    return [ln.split("\t") for ln in lines[1:]]  # the first line is the header


def ledger_apply(argv):
    """`ledger-apply <dir> [--apply]`: merge readers' output (the rubric in the reading round) into the ledger and the fixtures.
    `*-class.tsv` sets a row's pol and kind (a `:1000` placeholder takes the
    note as its rule); `*-declar.tsv` adds `declar.` rows; `*-links.tsv` adds
    `//! lrm <id>` to a fixture. Every value and every link is validated:
    the fixture exists, the row exists, the fixture's polarity is the link's
    side, and a refusal links only to a prohibition. Anything else is
    reported and skipped, never written."""
    d = Path(argv[0])
    apply = "--apply" in argv
    ledger = read_ledger()
    bad, set_rows, new_rows, links = [], 0, 0, 0
    for f in sorted(d.glob("*-class.tsv")):
        for c in read_tsv(f):
            if len(c) < 3 or c[0] not in ledger or c[1] not in POLS or c[2] not in KINDS:
                bad.append(f"{f.name}: {c[:3]}")
                continue
            r = ledger[c[0]]
            r["pol"], r["kind"] = c[1], c[2]
            if r["hash"] == "manual" and len(c) > 3 and c[3].strip():
                r["text"] = c[3].strip()[:400]
            set_rows += 1
    for f in sorted(d.glob("*-declar.tsv")):
        for c in read_tsv(f):
            if len(c) < 4 or c[2] not in POLS or c[3] not in KINDS or not c[1].strip():
                bad.append(f"{f.name}: {c[:2]}")
                continue
            clause = c[0].strip().lstrip("§")
            text = c[1].strip()[:400]
            if any(r["hash"] == "manual" and r["text"] == text for rid, r in ledger.items() if rid.partition(":")[0] == clause):
                continue  # applied before: a merge is idempotent
            taken = [int(rid.partition(":")[2]) for rid in ledger if rid.partition(":")[0] == clause]
            n = max([MANUAL_ORDINAL] + [t for t in taken if t >= MANUAL_ORDINAL]) + 1
            rid = f"{clause}:{n}"
            ledger[rid] = {"id": rid, "hash": "manual", "modal": "declar.", "pol": c[2], "kind": c[3],
                           "oracle": "?", "text": text}
            new_rows += 1
    edits = {}
    for f in sorted(d.glob("*-links.tsv")):
        for c in read_tsv(f):
            if len(c) < 3:
                continue
            fx, rid, side = c[0].strip(), c[1].strip(), c[2].strip()
            path = FIXTURES / fx
            if not path.exists() or rid not in ledger or side not in ("pos", "neg"):
                bad.append(f"{f.name}: {fx} {rid} {side}")
                continue
            t = fixture_tags(path)
            actual = "neg" if t["reject"] else "pos"
            if t["c"]:
                actual = side  # a `.c` fixture's polarity is per line
            pol = ledger[rid]["pol"]
            ok_side = (side == "pos" and pol in ("+", "+-")) or (side == "neg" and pol in ("-", "+-"))
            if actual != side or not ok_side:
                bad.append(f"{f.name}: {fx} {rid}: fixture is {actual}, row pol {pol}")
                continue
            if rid in [cite for cite, _ in t["cites"]]:
                continue
            edits.setdefault(path, []).append((rid, side))
    for path, rows in edits.items():
        links += len(rows)
        if not apply:
            continue
        text = path.read_text()
        lines = text.split("\n")
        for rid, side in rows:
            clause = rid.partition(":")[0]
            key = "lrm-reject" if (path.suffix == ".c" and side == "neg") else "lrm"
            new = [f"//! {key} {rid}"]
            if not re.search(rf"(?m)^\s*//!\s*{key}\s+{re.escape(clause)}(?::\d+)?\s*$", "\n".join(lines)):
                new = [f"//! {key} {clause}"] + new
            lines = insert_after(lines, lambda ln, c=clause, k=key: re.match(rf"\s*//!\s*{k}\s+{re.escape(c)}(?::\d+)?\s*$", ln)
                                 or re.match(r"\s*//!\s*lrm(-reject)?\s", ln), new)
        path.write_text("\n".join(lines))
    if apply:
        write_ledger(ledger)
    print(f"ledger-apply: {set_rows} rows classified, {new_rows} declarative rows, "
          f"{links} links in {len(edits)} fixtures{' (written)' if apply else ''}; {len(bad)} rejected")
    for b in bad[:40]:
        print(f"  rejected: {b}")
    return 0


SUBCOMMANDS["ledger-apply"] = ledger_apply


def lint_cites(argv):
    """`lint-cites [--fix]`: every sentence cite against its row's polarity. A
    refusal cannot evidence a `+` row and a passing fixture cannot evidence a
    `-` row; such a cite names a sentence the fixture does not observe, and it
    inflates the metric. `--fix` removes those cites (the bare clause cite
    stays). Unknown ids are reported."""
    ledger = read_ledger()
    bad, unknown, files = 0, [], 0
    for path in fixture_files("*.va", "*.v", "*.c"):
        t = fixture_tags(path)
        drop = []
        for cite, side in t["cites"]:
            if ":" not in cite:
                continue
            r = ledger.get(cite)
            if r is None:
                unknown.append(f"{path.relative_to(FIXTURES)}: {cite}")
                continue
            if (side == "neg" and r["pol"] == "+") or (side == "pos" and r["pol"] == "-"):
                drop.append((cite, side))
        if not drop:
            continue
        files += 1
        bad += len(drop)
        if "--fix" in argv:
            text = path.read_text()
            for cite, side in drop:
                key = "lrm-reject" if (t["c"] and side == "neg") else "lrm"
                text = re.sub(rf"(?m)^\s*//!\s*{key}\s+{re.escape(cite)}\s*\n", "", text, count=1)
            path.write_text(text)
    print(f"lint-cites: {bad} cites in {files} fixtures contradict their row's polarity{' (removed)' if '--fix' in argv else ''}; "
          f"{len(unknown)} cite unknown rows")
    for u in unknown[:20]:
        print(f"  unknown: {u}")
    return 1 if (bad and "--fix" not in argv) or unknown else 0


SUBCOMMANDS["lint-cites"] = lint_cites


class ObligationLedger(unittest.TestCase):
    def test_modal_order_puts_prohibitions_first(self):
        self.assertEqual(modal("The value shall not be negative."), "shall-not")
        self.assertEqual(modal("It is an error to assign a net."), "error")
        self.assertEqual(modal("Otherwise an error shall be reported."), "error")
        self.assertEqual(modal("The tool shall report an error."), "error")
        self.assertEqual(modal("The flow shall be zero."), "shall")
        self.assertEqual(modal("A module may contain branches."), "may")
        self.assertIsNone(modal("The result is the sum."))

    def test_sentences_split_at_terminators_only_before_a_capital(self):
        self.assertEqual(sentences("A x. B y.  c d. (E) f"), ["A x.", "B y. c d.", "(E) f"])

    def test_levels_need_evidence_that_ran_could_fail_and_was_judged_twice(self):
        ledger = {
            "5.1:1": {"pol": "+", "kind": "-", "oracle": "hand2"},
            "5.1:2": {"pol": "-", "kind": "-", "oracle": "hand"},
            "5.2:1": {"pol": "+", "kind": "-", "oracle": "fd"},
            "5.3:1": {"pol": "+", "kind": "-", "oracle": "?"},
            "5.3:2": {"pol": "+", "kind": "-", "oracle": "?"},
        }
        tag = lambda lrm, reject=False, only=False, nb=(): {"cites": [(c, "neg" if reject else "pos") for c in lrm], "reject": reject, "only": only, "neighbours": list(nb), "xfail": False, "c": False}
        fixtures = {
            "a.va": tag(["5.1:1"]),
            "b.va": tag(["5.1:2"], reject=True, only=True, nb=["c.va"]),
            "c.va": tag(["5.1"]),
            "d.va": tag(["5.2"]),  # bare cite of a one-row clause
            "e.va": tag(["5.3"]),  # bare cite of a two-row clause, failing
        }
        verdicts = {"a.va": "pass", "b.va": "pass", "c.va": "pass", "d.va": "pass", "e.va": "xfail"}
        perturbed = {"a.va": "pass", "d.va": "pass"}
        lv, unattr = levels(ledger, fixtures, verdicts, perturbed, killed={"5.1:1"})
        self.assertEqual(lv["5.1:1"], "E5")  # passed, perturbed, independent, killed
        self.assertEqual(lv["5.1:2"], "E3")  # discriminating refusal, but a `hand` oracle
        self.assertEqual(lv["5.2:1"], "E4")  # the bare cite is unambiguous
        self.assertEqual(lv["5.3:1"], "E1")  # cited only through its clause
        self.assertEqual(unattr, {"5.3": ["e.va"]})


# ---------------------------------------------------------------------------
# grammar: the R3 oracle (L5c). Every Syntax box read
# into BNF, an Earley recognizer over it, the alternatives passing positive
# fixtures derive, and VerA's parse-level acceptance against the recognizer's.
# None of it reads VerA's parser: the oracle is the LRM's text.
# ---------------------------------------------------------------------------

GRAMMAR_TSV = ROOT / "tests/fixtures/conformance/GRAMMAR.tsv"
GRAMMAR_DIFF_TSV = ROOT / "tests/fixtures/conformance/GRAMMAR-DIFF.tsv"
# Boxes that are not grammar: 1.4's notation examples, and Annex G's history.
GRAMMAR_SKIP_FILES = ("ch1-intro.html", "annex-g-changes.html")


class SyntaxBoxes(HTMLParser):
    """Every `class="syntax"` <div> or <pre>, as [(clause, file, parts)]:
    `parts` is [(bold?, text)]. Bold (<b>, <strong>) is a terminal (1.4 item
    2). Dropped: <sup> footnote marks, the <em>/<i> caption, and a footnote
    printed inside the box (a line opening with <sup> or `1)`); a <sub> joins
    the text before it (4.5.12's t<sub>0</sub>). `clause` is the number of the
    last heading above the box."""

    def __init__(self, name):
        super().__init__(convert_charrefs=True)
        self.name, self.clause, self.heading = name, "", None
        self.box, self.tag, self.depth, self.bold, self.skip, self.sub = None, None, 0, 0, 0, 0
        self.footnote = False
        self.boxes = []

    def handle_starttag(self, tag, attrs):
        if self.box is None:
            if re.fullmatch(r"h[1-6]", tag):
                self.heading = []
            elif tag in ("div", "pre") and "syntax" in (dict(attrs).get("class") or "").split():
                self.box, self.tag, self.depth, self.footnote = [], tag, 1, False
            return
        if tag == self.tag:
            self.depth += 1
        elif tag in ("b", "strong"):
            self.bold += 1
        elif tag in ("sup", "em", "i"):
            self.skip += 1
            if tag == "sup" and (not self.box or self.box[-1][1].endswith("\n")):
                self.footnote = True
        elif tag == "sub":
            self.sub += 1

    def handle_endtag(self, tag):
        if self.box is None:
            if self.heading is not None and re.fullmatch(r"h[1-6]", tag):
                words = "".join(self.heading).split()
                self.clause = words[0] if words else self.clause
                self.heading = None
            return
        if tag == self.tag:
            self.depth -= 1
            if not self.depth:
                self.boxes.append((self.clause, self.name, self.box))
                self.box = None
        elif tag in ("b", "strong"):
            self.bold -= 1
        elif tag in ("sup", "em", "i"):
            self.skip -= 1
        elif tag == "sub":
            self.sub -= 1

    def handle_data(self, data):
        if self.heading is not None:
            self.heading.append(data)
        if self.box is None or self.skip or self.footnote:
            return
        m = re.search(r"(?:^|\n)\s*\d+\)\s", data)
        if m:
            data, self.footnote = data[:m.start()], True
        if self.sub and self.box:
            self.box[-1] = (self.box[-1][0], self.box[-1][1] + data)
        else:
            self.box.append((self.bold > 0, data))


# Plain (non-bold) text of a box: meta-symbols, names, `// from A.x` notes.
BOX_LEXEME = re.compile(r"::=|\.\.\.|//[^\n]*|[|\[\]{}]|\\n|[\w$]+(?:-[A-Za-z]\w*)*|\S")


def box_lexemes(parts):
    """A box as lexemes: ("T", text) a bold terminal, ("U", text) a terminal
    printed in plain type (an anomaly 1.4 has no reading for), ("N", name),
    and the meta-symbols `::=`, `|`, `[`, `]`, `{`, `}`, `...`."""
    out = []
    for bold, text in parts:
        if bold:
            out.extend(("T", w) for w in text.split())
            continue
        for m in BOX_LEXEME.finditer(text):
            s = m.group(0)
            if s.startswith("//"):
                continue
            if s in ("::=", "|", "[", "]", "{", "}", "..."):
                out.append((s, s))
            elif re.fullmatch(r"[\w$][\w$-]*", s):
                out.append(("N", s))
            else:
                out.append(("U", s))
    return out


def ebnf(lex):
    """One alternative's lexemes as a tree: a sequence of ("T"|"U"|"N", text)
    and ("opt"|"rep", [sequence, ...]) for [ ] and { }."""
    pos = 0

    def alts(close):
        nonlocal pos
        out = [[]]
        while pos < len(lex):
            k, s = lex[pos]
            pos += 1
            if k in ("]", "}"):
                if k != close:
                    raise ValueError(f"unbalanced {k}")
                return out
            if k == "|":
                out.append([])
            elif k in ("[", "{"):
                out[-1].append(("opt" if k == "[" else "rep", alts("]" if k == "[" else "}")))
            elif k == "...":
                raise ValueError("elision inside an alternative")
            else:
                out[-1].append((k, s))
        if close:
            raise ValueError(f"unclosed {close}")
        return out

    tree = alts(None)
    if len(tree) != 1:
        raise ValueError("a top-level | survived the split")
    return tree[0]


def render(seq):
    """The alternative's text: names bare, bold terminals quoted, plain-type
    punctuation bare as printed."""
    parts = []
    for k, v in seq:
        if k == "N" or k == "U":
            parts.append(v)
        elif k == "T":
            parts.append(f'"{v}"' if "'" in v else f"'{v}'")
        else:
            o, c = ("[", "]") if k == "opt" else ("{", "}")
            parts.append(o + " " + " | ".join(render(a) for a in v) + " " + c)
    return " ".join(parts)


def box_productions(lexemes, anonymous):
    """[(name, [alternative lexemes])]. A box with no `::=` before its first
    lexeme (9.17.1's `$discontinuity` form) is one production named
    `anonymous`. Alternatives that are only `...` (a chapter's elision) go."""
    prods, depth = [], 0
    for i, (k, s) in enumerate(lexemes):
        if k == "::=":
            continue
        if k == "N" and i + 1 < len(lexemes) and lexemes[i + 1][0] == "::=":
            prods.append((s, [[]]))
            depth = 0
            continue
        if not prods:
            prods.append((anonymous, [[]]))
        if k == "|" and depth == 0:
            prods[-1][1].append([])
            continue
        depth += {"[": 1, "{": 1, "]": -1, "}": -1}.get(k, 0)
        prods[-1][1][-1].append((k, s))
    return [(n, [a for a in alts if a != [("...", "...")]]) for n, alts in prods]


class Alt:
    __slots__ = ("id", "lhs", "seq", "text", "note")

    def __init__(self, id, lhs, seq, text, note):
        self.id, self.lhs, self.seq, self.text, self.note = id, lhs, seq, text, note


CAPTION = re.compile(r"\s*Syntax \d+-\d+")


def read_syntax(docs=None):
    """Every Syntax box of Annex A and the chapters as alternatives, and the
    extraction's notes. Ids are `<clause>/<n>`, the n-th alternative of the
    boxes under that heading: `A.6.4/12`, `9.17.3/2`.

    Annex A is the formal syntax and comes first. A chapter box quotes it
    (`// from A.6.5`) in whatever typography the chapter used, so a chapter
    alternative with the same characters as an Annex A alternative of the
    same production is the same requirement and gets no row; one with an
    elision (`...`) inside it is an excerpt and gets none either. The rest
    are rows, noted `not in Annex A` or `differs from Annex A`. Every
    alternative keeps its ordinal whether or not it is a row, so an id does
    not move when an excerpt changes."""
    docs = Path(docs or ROOT / "specification")
    files = ["annex-a-syntax.html"] + sorted(
        (p.name for p in docs.glob("ch*.html") if p.name not in GRAMMAR_SKIP_FILES),
        key=lambda n: int(re.search(r"\d+", n).group()))
    boxes = []
    for name in files:
        parser = SyntaxBoxes(name)
        parser.feed((docs / name).read_text())
        parser.close()
        boxes += parser.boxes
    prods = []
    for clause, fname, parts in boxes:
        parts = [(b, t) for b, t in parts if not CAPTION.match(t)]
        anonymous = "syntax_" + re.sub(r"[.-]", "_", clause)
        for lhs, raw in box_productions(box_lexemes(parts), anonymous):
            prods.append((clause, fname.startswith("annex-a"), lhs, raw))
    defined = {lhs for _, _, lhs, _ in prods}
    alts, notes, counter, annex, seen = [], [], {}, set(), {}
    for clause, in_annex, lhs, raw in prods:
        for lex in raw:
            # A `$name` in plain type is a production name only where one is
            # defined (A.7.5.1's `$setup_timing_check`); elsewhere it is a
            # terminal printed without bold (9.16's `$simprobe`).
            lex = [("U", s) if k == "N" and s.startswith("$") and s not in defined else (k, s) for k, s in lex]
            while lex and lex[0][0] == "...":
                lex = lex[1:]
            while lex and lex[-1][0] == "...":
                lex = lex[:-1]
            if not lex:
                continue
            counter[clause] = counter.get(clause, 0) + 1
            aid = f"{clause}/{counter[clause]}"
            key = "".join(s for _, s in lex)
            if key in seen.get(lhs, ()):
                continue
            seen.setdefault(lhs, set()).add(key)
            if in_annex:
                annex.add(lhs)
                note = ""
            elif any(k == "..." for k, _ in lex):
                notes.append(f"{aid} {lhs}: an excerpt with an elision; no row")
                continue
            else:
                note = "differs from Annex A" if lhs in annex else "not in Annex A"
            try:
                seq = ebnf(lex)
            except ValueError as e:
                notes.append(f"{aid} {lhs}: {e}; read as written")
                seq = [(k, s) for k, s in lex if k in ("T", "U", "N")]
                note = (note + "; " if note else "") + str(e)
            if any(k == "U" for k, _ in lex):
                notes.append(f"{aid} {lhs}: terminal in plain type: " + " ".join(s for k, s in lex if k == "U"))
            alts.append(Alt(aid, lhs, seq, render(seq), note))
    return alts, notes


def write_grammar_tsv(alts, path=None):
    path = path or GRAMMAR_TSV
    head = ("# Every alternative of every Syntax box: the grammar-coverage denominator.\n"
            "# Written by `tools/conformance.py grammar extract`; never edit by hand.\n"
            "# Terminals (bold in the LRM) are quoted; plain-type punctuation is bare.\n"
            "# note: empty for Annex A; a chapter row says how it relates to Annex A.\n"
            "# id\tproduction\ttext\tnote\n")
    Path(path).write_text(head + "".join(f"{a.id}\t{a.lhs}\t{a.text}\t{a.note}\n" for a in alts))


def grammar_extract(argv):
    """`extract`: every Syntax box into tests/fixtures/conformance/GRAMMAR.tsv, with the extraction's
    notes and every name no box defines (a transcription finding, or a
    chapter box's argument placeholder)."""
    alts, notes = read_syntax()
    write_grammar_tsv(alts)
    annex = sum(1 for a in alts if a.id.startswith("A."))
    print(f"grammar extract: {len(alts)} alternatives ({annex} Annex A, {len(alts) - annex} from chapter boxes) "
          f"of {len({a.lhs for a in alts})} productions -> {GRAMMAR_TSV.relative_to(ROOT)}")
    for n in notes:
        print(f"  note {n}")
    for name, users in sorted(grammar_undefined(alts).items()):
        reading = next((f"; read as `{b or 'empty'}`" for r, b, _ in GRAMMAR_READINGS if r == name), "")
        print(f"  undefined {name} (in {', '.join(sorted(set(users))[:4])}{', ...' if len(set(users)) > 4 else ''}){reading}")
    return 0


GRAMMAR_COMMANDS = {"extract": grammar_extract}


def grammar(argv):
    """`grammar extract|earley|coverage|diff [...]`: the R3 oracle
    (L5c)."""
    if not argv or argv[0] not in GRAMMAR_COMMANDS:
        print(f"usage: conformance.py grammar {'|'.join(GRAMMAR_COMMANDS)} ...", file=sys.stderr)
        return 2
    return GRAMMAR_COMMANDS[argv[0]](argv[1:])


SUBCOMMANDS["grammar"] = grammar


# ---- tokens ---------------------------------------------------------------
# Verilog-AMS lexical tokens (2.x, A.8.7, A.8.8, A.9.3), independent of
# lib/frontend/lexer.zig. A sized number's size, base and value may be
# separated by white space (2.6.1); the token's text drops it.
OPERATORS = ["<<<", ">>>", "===", "!==", "&&&", "**", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||",
             "~&", "~|", "~^", "^~", "<+", "->", "+:", "-:", "*)", "=>", "*>"]
TOKEN = re.compile(r"""
    (?P<ws>[ \t\r\n\f]+)
  | (?P<lc>//[^\n]*)
  | (?P<bc>/\*.*?\*/)
  | (?P<str>"(?:[^"\\\n]|\\[^\n])*")
  | (?P<esc>\\[!-~]+)
  | (?P<num>(?:[0-9][0-9_]*[ \t\r\n]*)?'[sS]?[dDbBoOhH][ \t\r\n]*[0-9a-fA-FxXzZ?_]+
          | [0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9][0-9_]*|[TGMKkmunpfa](?![A-Za-z0-9_$]))?)
  | (?P<sys>\$[A-Za-z0-9_$]+)
  | (?P<dir>`[A-Za-z_][A-Za-z0-9_$]*)
  | (?P<id>[A-Za-z_][A-Za-z0-9_$]*)
  | (?P<star>\(\*\))
  | (?P<attr>\(\*)
  | (?P<op>""" + "|".join(re.escape(o) for o in OPERATORS) + r""")
  | (?P<other>[^\s])
  | (?P<bad>.)
""", re.S | re.X)


def vams_keywords():
    if not hasattr(vams_keywords, "words"):
        table = KeywordTable()
        table.feed((ROOT / "specification/annex-b-keywords.html").read_text())
        vams_keywords.words = frozenset(table.words)
    return vams_keywords.words


class Tok:
    __slots__ = ("kind", "text", "pos", "end")

    def __init__(self, kind, text, pos, end=None):
        self.kind, self.text, self.pos = kind, text, pos
        self.end = pos + len(text) if end is None else end

    def __repr__(self):
        return f"{self.kind}:{self.text}"


def lex(text, comments=None):
    """Tokens of preprocessed text. `kind` is `id`, `kw` (Table B.1), `esc`,
    `sys`, `num`, `str`, `dir` (a directive the preprocessor left), `op`, or
    `bad`: a character that starts no token and is not white space (2.3).
    `comments`, if a set, collects `lc`/`bc` for each comment form seen."""
    keywords, out = vams_keywords(), []
    for m in TOKEN.finditer(text):
        kind, s = m.lastgroup, m.group()
        if kind == "ws":
            continue
        if kind in ("lc", "bc"):
            if comments is not None:
                comments.add(kind)
            continue
        if kind == "star":
            out += [Tok("op", "(", m.start()), Tok("op", "*", m.start() + 1), Tok("op", ")", m.start() + 2)]
            continue
        if kind == "num":
            s = re.sub(r"\s+", "", s)
        elif kind == "id" and s in keywords:
            kind = "kw"
        elif kind in ("attr", "other"):
            kind = "op"
        out.append(Tok(kind, s, m.start(), m.end()))
    return out


# ---- the grammar as BNF -----------------------------------------------------
# The lexical productions are read by the tokenizer, not the parser: numbers
# (A.8.7), strings (A.8.8), comments (A.9.2), white space (A.9.4) and the
# identifier spellings of A.9.3. A token-level production that names one of
# them matches a token of that class; a number token is parsed again, one
# character at a time, against A.8.7 itself.
LEXICAL_CLAUSES = ("A.8.7/", "A.8.8/", "A.9.2/", "A.9.4/")
IDENTIFIER_CLASSES = {"simple_identifier": "id", "escaped_identifier": "esc",
                      "system_function_identifier": "sys", "system_task_identifier": "sys",
                      "system_parameter_identifier": "sys", "string_literal": "str"}


def lexical_names(alts):
    names = {a.lhs for a in alts if a.id.startswith(LEXICAL_CLAUSES)} | set(IDENTIFIER_CLASSES)
    number = {a.lhs for a in alts if a.id.startswith("A.8.7/")}
    return names, number


def names_in(seq):
    for k, v in seq:
        if k == "N":
            yield v
        elif k in ("opt", "rep"):
            for a in v:
                yield from names_in(a)


def grammar_undefined(alts):
    """{name: [alt ids that use it]} for names no box defines."""
    lexical, _ = lexical_names(alts)
    defined = {a.lhs for a in alts} | lexical
    out = {}
    for a in alts:
        if a.lhs in lexical:
            continue
        for n in names_in(a.seq):
            if n not in defined:
                out.setdefault(n, []).append(a.id)
    return out


# Readings of Annex A's undefined names, for the recognizer only (tests/fixtures/conformance/GRAMMAR.tsv
# keeps the text as printed). Each is the evident intent of a defect the
# annex's own editorial note lists or the chapters resolve. Without the first
# three no analog assignment derives at all. A derivation that needs one of
# these is a BNF transcription issue, not evidence about VerA.
GRAMMAR_READINGS = [
    ("string", "string_literal", "plain `string` in A.2.5, A.8.2-A.8.4 is undefined; 7.3.1's primary has string_literal"),
    ("scalar_analog_variable_lvalue", "analog_variable_lvalue",
     "A.6.2 uses it undefined; A.8.5's analog_variable_lvalue is the scalar lvalue"),
    ("array_analog_variable_lvalue", "array_variable_identifier", "A.8.5 uses it undefined"),
    ("array_variable_identifier", "identifier", "undefined; A.9.3 makes every other *_identifier an identifier"),
    ("array_", "", "A.8.5 prints `array_ variable_identifier` with an internal space: one name"),
    ("string_declaration", "syntax_3_3", "A.2.8 uses it undefined; 3.3's box is the string declaration"),
    ("macro_text", "", "10.4's macro text is the rest of the line, which the directive parse does not read"),
    ("analog_procedural_assignment", "array_analog_variable_assignment",
     "A.8.5 ends the array assignment with `;` and A.6.2 adds another (Annex A's editorial note): one `;`"),
]
# A chapter box's own placeholders (`expr`, `td`, `fd`, ...) are argument
# slots no production defines: a slot reads as an expression, a `*list*` or
# `*args*` slot as a list of them.
PLACEHOLDER = "analog_expression | expression | constant_assignment_pattern"


class BNF:
    """A grammar over integer symbols. A symbol's key is ("n", name) for a
    nonterminal, ("t", text) for a token's exact text, ("c", class) for a
    lexical class. `rules[r] = (lhs, rhs)`; `alt[r]` is the tests/fixtures/conformance/GRAMMAR.tsv id the
    rule is an alternative of (None for a [ ] or { } helper or a reading)."""

    def __init__(self, terminal, classes=()):
        self.terminal, self.classes = terminal, set(classes)
        self.index, self.keys, self.rules, self.alt, self.helpers = {}, [], [], [], 0

    def sym(self, key):
        i = self.index.get(key)
        if i is None:
            i = self.index[key] = len(self.keys)
            self.keys.append(key)
        return i

    def name(self, v):
        return self.sym(("c", v) if v in self.classes else ("n", v))

    def add(self, lhs, rhs, alt=None):
        self.rules.append((self.sym(("n", lhs)), tuple(rhs)))
        self.alt.append(alt)

    def seq(self, seq):
        out = []
        for k, v in seq:
            if k in ("T", "U"):
                out += [self.sym(("t", t)) for t in self.terminal(v)]
            elif k == "N":
                out.append(self.name(v))
            else:
                self.helpers += 1
                h = f"#{self.helpers}"
                hs = self.sym(("n", h))
                self.add(h, [])
                for a in v:
                    self.add(h, ([hs] if k == "rep" else []) + self.seq(a))
                out.append(hs)
        return out

    def finish(self):
        n = len(self.keys)
        self.term = [k[0] != "n" for k in self.keys]
        self.by_lhs = [[] for _ in range(n)]
        for r, (lhs, _) in enumerate(self.rules):
            self.by_lhs[lhs].append(r)
        self.lhs = [l for l, _ in self.rules]
        self.rhs = [r for _, r in self.rules]
        null = set()
        changed = True
        while changed:
            changed = False
            for lhs, rhs in self.rules:
                if lhs not in null and all(s in null for s in rhs):
                    null.add(lhs)
                    changed = True
        first = [set([i]) if self.term[i] else set() for i in range(n)]
        changed = True
        while changed:
            changed = False
            for lhs, rhs in self.rules:
                f = first[lhs]
                before = len(f)
                for s in rhs:
                    f |= first[s]
                    if s not in null:
                        break
                changed |= len(f) != before
        self.null = null
        self.first = [frozenset(f) for f in first]
        self.rule_first, self.rule_null = [], []
        for _, rhs in self.rules:
            f = set()
            for s in rhs:
                f |= self.first[s]
                if s not in null:
                    break
            self.rule_first.append(frozenset(f))
            self.rule_null.append(all(s in null for s in rhs))
        self.cache = {}
        return self


def quote_strings(seq):
    """`" analysis_identifier "` (bold quotes around a name, A.8.2, A.6.5) is
    one string literal token to a lexer: read the span as string_literal."""
    out, i = [], 0
    while i < len(seq):
        k, v = seq[i]
        if k in ("opt", "rep"):
            out.append((k, [quote_strings(a) for a in v]))
        elif k == "T" and v == '"':
            j = next((j for j in range(i + 1, len(seq)) if seq[j] == ("T", '"')), None)
            if j is not None:
                out.append(("N", "string_literal"))
                i = j
            else:
                out.append((k, v))
        else:
            out.append((k, v))
        i += 1
    return out


def token_bnf(alts, chapters=True):
    """The token-level grammar: every non-lexical alternative and the
    readings. With `chapters`, also every chapter box's row, its placeholders
    and, for each chapter-only production nothing references, a graft where
    its form belongs (one that ends in `;` is a statement, the rest a
    primary; a directive or a form that can be empty is not grafted), so a
    fixture can derive it. Without, Annex A alone."""
    if not chapters:
        alts = [a for a in alts if not a.note]
    lexical, _ = lexical_names(alts)
    # 4.6.4.2's `exp` is flicker_noise's exponent argument, not A.8.7's
    # exponent letter: a chapter placeholder that shares a lexical name.
    classes = {n for n in lexical if any(n in names_in(a.seq) for a in alts if a.lhs not in lexical)} - {"exp"}
    g = BNF(lambda text: [t.text for t in lex(text)], classes | {"sign"})
    defined = {a.lhs for a in alts}
    for a in alts:
        if a.lhs not in lexical:
            g.add(a.lhs, g.seq(quote_strings(a.seq)), a.id)
    readings = {name for name, _, _ in GRAMMAR_READINGS}
    for name, body, _ in GRAMMAR_READINGS:
        if not body or body in defined | readings | classes | lexical:
            g.add(name, [g.name(body)] if body else [])
    if not chapters:
        return g.finish()
    referenced = {n for a in alts for n in names_in(a.seq)} | {b for _, b, _ in GRAMMAR_READINGS}
    chapter = {a.lhs for a in alts if a.note}
    undefined = ({n for a in alts if a.note for n in names_in(a.seq)} - defined - lexical - {r for r, _, _ in GRAMMAR_READINGS}) | {"exp"}
    for n in sorted(undefined):
        if re.search(r"list|args|arguments", n):
            g.add(n, g.seq(ebnf(box_lexemes([(False, "[ _slot ] { , [ _slot ] }")]))))
        else:
            g.add(n, [g.name("_slot")])
    for body in PLACEHOLDER.split(" | "):
        g.add("_slot", [g.name(body)])
    by_lhs = {}
    for a in alts:
        by_lhs.setdefault(a.lhs, []).append(a.seq)

    def ends_in_semicolon(name, seen=()):
        def last(seq):
            k, v = seq[-1] if seq else (None, None)
            return (k in ("T", "U") and v == ";") or (k == "N" and v not in seen and ends_in_semicolon(v, seen + (v,)))
        return bool(by_lhs.get(name)) and all(last(q) for q in by_lhs[name])

    for root in sorted(chapter - referenced):
        seqs = by_lhs[root]
        if any(q and q[0][0] == "T" and q[0][1].startswith("`") for q in seqs):
            continue  # a compiler directive (10.2-10.4): `directive_start` parses it
        if any(all(k in ("opt", "rep") for k, _ in q) for q in seqs):
            continue  # can be empty (9.21's table_ctrl_substr, inside a string): no statement or primary
        hosts = ("analog_statement", "statement") if ends_in_semicolon(root) else ("analog_primary", "primary")
        for host in hosts:
            g.add(host, [g.name(root)])
    return g.finish()


# ---- Earley ---------------------------------------------------------------
class Chart:
    """An Earley run: `sets[i]` the items (rule, dot, origin) before token i,
    `waits[i]` {symbol: items whose dot is before it}, `comps[i]` {lhs:
    [(rule, origin)]} the items complete at i. `fail` is the index of the
    first token no item could read, or None."""
    __slots__ = ("g", "toks", "start", "sets", "waits", "comps", "fail", "accepted")


def earley(g, toks, start):
    """Recognize `toks` (one frozenset of terminal symbol ids per token)
    from nonterminal `start`. Predictions are filtered by the next token's
    FIRST set, and a nullable symbol is stepped over as it is predicted
    (Aycock and Horspool), so empty rules need no second pass."""
    rhs_of, lhs_of, term, null = g.rhs, g.lhs, g.term, g.null
    by_lhs, rule_first, rule_null, cache = g.by_lhs, g.rule_first, g.rule_null, g.cache
    n = len(toks)
    c = Chart()
    c.g, c.toks, c.start, c.fail = g, toks, start, None
    sets, waits, comps = [], [], []
    current = set((r, 0, 0) for r in by_lhs[start])
    empty = frozenset()
    for i in range(n + 1):
        T = toks[i] if i < n else empty
        S = current
        agenda = list(S)
        wait, comp, predicted, nxt = {}, {}, set(), set()
        while agenda:
            item = agenda.pop()
            r, d, o = item
            rhs = rhs_of[r]
            if d == len(rhs):
                A = lhs_of[r]
                comp.setdefault(A, []).append((r, o))
                for r2, d2, o2 in (wait if o == i else waits[o]).get(A, ()):
                    it = (r2, d2 + 1, o2)
                    if it not in S:
                        S.add(it)
                        agenda.append(it)
                continue
            X = rhs[d]
            if term[X]:
                if X in T:
                    nxt.add((r, d + 1, o))
                continue
            wait.setdefault(X, []).append(item)
            if X in null:
                it = (r, d + 1, o)
                if it not in S:
                    S.add(it)
                    agenda.append(it)
            if X not in predicted:
                predicted.add(X)
                key = (X, T)
                rules = cache.get(key)
                if rules is None:
                    rules = cache[key] = [r2 for r2 in by_lhs[X] if rule_null[r2] or not rule_first[r2].isdisjoint(T)]
                for r2 in rules:
                    it = (r2, 0, i)
                    if it not in S:
                        S.add(it)
                        agenda.append(it)
        sets.append(S)
        waits.append(wait)
        comps.append(comp)
        if i < n:
            if not nxt:
                c.fail = i
                break
            current = nxt
    c.sets, c.waits, c.comps = sets, waits, comps
    c.accepted = c.fail is None and any(o == 0 for _, o in comps[n].get(start, ()))
    return c


def derived(c):
    """The derivations of an accepted chart: ({alt id}, {(token index, class
    symbol)}): every alternative some complete parse uses, and the lexical
    class each token was read as. Walks back from the start item over items
    that exist in the chart, memoized on (rule, dot, origin, end)."""
    g, sets, comps = c.g, c.sets, c.comps
    rhs_of, term = g.rhs, g.term
    n = len(c.toks)
    top = [(r, 0, n) for r, o in comps[n].get(c.start, ()) if o == 0]
    done, seen, classes = set(top), set(), set()
    stack = list(top)
    while stack:
        r, o, e = stack.pop()
        rhs = rhs_of[r]
        walk = [(len(rhs), e)]
        while walk:
            d, e2 = walk.pop()
            key = (r, d, o, e2)
            if d == 0 or key in seen:
                continue
            seen.add(key)
            X = rhs[d - 1]
            if term[X]:
                if e2 > o and (r, d - 1, o) in sets[e2 - 1]:
                    classes.add((e2 - 1, X))
                    walk.append((d - 1, e2 - 1))
                continue
            for r2, q in comps[e2].get(X, ()):
                if q >= o and (r, d - 1, o) in sets[q]:
                    it = (r2, q, e2)
                    if it not in done:
                        done.add(it)
                        stack.append(it)
                    walk.append((d - 1, q))
    return {g.alt[r] for r, _, _ in done if g.alt[r]}, classes


# ---- preprocessing --------------------------------------------------------
# Enough of 10 and IEEE 1364-2005 19 to turn a fixture into the text a
# parser sees. What it cannot model it refuses (Unexpandable), and `coverage`
# counts the fixture as skipped rather than guessing.
class Unexpandable(Exception):
    pass


def zig_text(path, name):
    """The text of a Zig `pub const name =` multiline string literal."""
    lines = path.read_text().split("\n")
    i = next(i for i, ln in enumerate(lines) if re.match(rf"pub const {name}\s*=", ln))
    out = []
    for ln in lines[i + 1:]:
        t = ln.strip()
        if not t.startswith("\\\\"):
            break
        out.append(t[2:])
    return "\n".join(out) + "\n"


# Annex D's files: the LRM's text, which lib/frontend/pp transcribes verbatim.
STD_HEADERS = {"constants.vams": ("annex_d.zig", "constants_vams"),
               "disciplines.vams": ("annex_d.zig", "disciplines_vams"),
               "driver_access.vams": ("annex_e.zig", "driver_access_vams")}
# Directives that change nothing a parser sees. The first take the rest of
# their line as operands; the second are the word alone (IEEE 1364-2005 19.1,
# 19.6, 19.10), so the text after one on its line is ordinary source.
LINE_DIRECTIVES = {"timescale", "default_nettype", "unconnected_drive", "pragma", "line"}
WORD_DIRECTIVES = {"celldefine", "endcelldefine", "resetall", "nounconnected_drive"}
# An escaped identifier (2.8.1) is one unit everywhere: a comma inside one
# separates no macro argument, and `\name names a macro.
ARG_SCAN = re.compile(r'"(?:[^"\\\n]|\\.)*"|//[^\n]*|/\*.*?\*/|\\\S+|.', re.S)
PP_SCAN = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:[^"\\\n]|\\.)*"|`(?:[A-Za-z_][A-Za-z0-9_$]*|\\\S+)|[^`/"]+|.', re.S)
# 10.5's two, and VerA's own (the clause leaves the spelling to the tool).
PREDEFINED = ("__VAMS_ENABLE__", "__VAMS_COMPACT_MODELING__", "__VERA__")


class Preprocessor:
    def __init__(self, include_dirs, prelude=True):
        self.dirs = [Path(d) for d in include_dirs]
        self.macros = {n: (None, "1") for n in PREDEFINED}
        self.directives = []  # (name, line text) of `default_discipline, `default_transition, `define
        self.depth = 0
        if prelude:  # D.1 and D.2 are preloaded (VerA's prelude; their guards make an `include a no-op)
            for name in ("constants.vams", "disciplines.vams"):
                self.run(self.header(name), Path(name))
            self.directives = []

    def header(self, name):
        file, const = STD_HEADERS[name]
        return zig_text(ROOT / "lib/frontend/pp" / file, const)

    def include(self, name, here):
        for d in [here.parent] + self.dirs:
            p = d / name
            if p.is_file():
                return p.read_text(errors="replace"), p
        if name in STD_HEADERS:
            return self.header(name), Path(name)
        raise Unexpandable(f"`include \"{name}\" not found")

    def run(self, text, here):
        self.depth += 1
        if self.depth > 40:
            raise Unexpandable("`include or macro nesting deeper than 40")
        out, stack, pos = [], [], 0
        active = lambda: all(s[0] for s in stack)  # noqa: E731
        while pos < len(text):
            m = PP_SCAN.match(text, pos)
            s = m.group()
            pos = m.end()
            if not s.startswith("`"):
                if active():
                    out.append(s)
                elif "\n" in s:
                    out.append("\n" * s.count("\n"))
                continue
            name = s[1:]
            if name in ("ifdef", "ifndef", "elsif"):
                w = re.compile(r"[ \t]*([A-Za-z_][A-Za-z0-9_$]*)").match(text, pos)
                if not w:
                    raise Unexpandable(f"`{name} without a name")
                pos, defined = w.end(), w.group(1) in self.macros
                if name == "elsif":
                    if not stack:
                        raise Unexpandable("`elsif outside a conditional")
                    top = stack[-1]
                    top[0] = top[2] and not top[1] and defined
                    top[1] = top[1] or top[0]
                else:
                    parent = active()
                    on = parent and (defined if name == "ifdef" else not defined)
                    stack.append([on, on, parent])
            elif name == "else":
                if not stack:
                    raise Unexpandable("`else outside a conditional")
                top = stack[-1]
                top[0], top[1] = top[2] and not top[1], True
            elif name == "endif":
                if not stack:
                    raise Unexpandable("`endif outside a conditional")
                stack.pop()
            elif not active():
                continue
            elif name == "define":
                pos = self.define(text, pos)
            elif name == "undef":
                w = re.compile(r"[ \t]*([A-Za-z_][A-Za-z0-9_$]*)").match(text, pos)
                if w:
                    pos = w.end()
                    if w.group(1) not in PREDEFINED:
                        self.macros.pop(w.group(1), None)
            elif name == "undefineall":
                self.macros = {n: v for n, v in self.macros.items() if n in PREDEFINED}
            elif name == "include":
                w = re.compile(r'[ \t]*"([^"\n]*)"').match(text, pos)
                if not w:
                    raise Unexpandable("`include without a quoted name")
                pos = w.end()
                body, path = self.include(w.group(1), here)
                out.append(self.run(body, path))
            elif name in WORD_DIRECTIVES:
                pass
            elif name in LINE_DIRECTIVES or name in ("default_discipline", "default_transition"):
                end = text.find("\n", pos)
                end = len(text) if end < 0 else end
                if name not in LINE_DIRECTIVES:
                    self.directives.append((name, s + text[pos:end]))
                pos = end
            elif name == "__FILE__":
                out.append(f'"{here}"')
            elif name == "__LINE__":
                out.append(str(text.count("\n", 0, m.start()) + 1))
            elif name in self.macros:
                body, pos = self.expand(name, text, pos)
                out.append(self.run(body, here))
            else:
                raise Unexpandable(f"`{name}")
        if stack:
            raise Unexpandable("unterminated `ifdef")
        self.depth -= 1
        return "".join(out)

    def define(self, text, pos):
        w = re.compile(r"[ \t]*(\\\S+|[A-Za-z_][A-Za-z0-9_$]*)").match(text, pos)
        if not w:
            raise Unexpandable("`define without a name")
        name, pos = w.group(1), w.end()
        params = None
        if text.startswith("(", pos):
            close = text.find(")", pos)
            if close < 0:
                raise Unexpandable("`define with an unclosed parameter list")
            params = [p.strip() for p in text[pos + 1:close].split(",")]
            if any("=" in p for p in params):
                raise Unexpandable("`define with a default argument")
            pos = close + 1
        body = []
        while True:
            end = text.find("\n", pos)
            end = len(text) if end < 0 else end
            line = text[pos:end]
            pos = end + 1
            cont = line.endswith("\\")
            line = line[:-1] if cont else line
            # A one-line comment is not part of the macro text (1364 19.3.1).
            cut = [m.start() for m in PP_SCAN.finditer(line) if m.group().startswith("//")]
            body.append(line[:cut[0]] if cut else line)
            if not cont or pos > len(text):
                break
        self.directives.append(("define", f"`define {name}" + (f"({', '.join(params)})" if params is not None else "")))
        if name not in PREDEFINED:
            self.macros[name] = (params, "\n".join(body).strip())
        return min(pos, len(text))

    def expand(self, name, text, pos):
        params, body = self.macros[name]
        if params is None:
            return body, pos
        w = re.compile(r"\s*\(").match(text, pos)
        if not w:
            raise Unexpandable(f"`{name} used without its arguments")
        pos, depth, args, cur = w.end(), 0, [], []
        while True:
            m = ARG_SCAN.match(text, pos)
            if not m:
                raise Unexpandable(f"`{name}( unclosed")
            s, pos = m.group(), m.end()
            # An actual keeps its white space: the space that ends an escaped
            # identifier before `)` is part of it (2.8.1).
            if s in ("(", "[", "{"):
                depth += 1
            elif s in (")", "]", "}"):
                if depth == 0 and s == ")":
                    args.append("".join(cur))
                    break
                depth -= 1
            elif s == "," and depth == 0:
                args.append("".join(cur))
                cur = []
                continue
            cur.append(s)
        if len(args) > len(params):
            raise Unexpandable(f"`{name} given {len(args)} arguments for {len(params)}")
        args += [""] * (len(params) - len(args))
        table = dict(zip(params, args))
        out = []
        for m in PP_SCAN.finditer(body):
            s = m.group()
            if s.startswith(('"', "`", "//", "/*")):
                out.append(s)
            else:
                out.append(re.sub(r"[A-Za-z_][A-Za-z0-9_$]*", lambda w: table.get(w.group(), w.group()), s))
        return "".join(out), pos


def preprocess(path, include_dirs=None):
    """(text, directives) of a fixture: its preprocessed text, and the
    `default_discipline / `default_transition / `define lines it ran."""
    path = Path(path)
    dirs = include_dirs if include_dirs is not None else [FIXTURES, path.parent]
    pp = Preprocessor(dirs)
    text = pp.run(path.read_text(errors="replace"), path)
    return text, pp.directives


# ---- the oracle -----------------------------------------------------------
class Oracle:
    """The grammar compiled once: `g` the token grammar (chapter boxes,
    readings and grafts included), `annex` Annex A and the readings alone,
    `ng` A.8.7 over characters."""

    def __init__(self, alts=None):
        self.alts = alts or read_syntax()[0]
        self.g = token_bnf(self.alts)
        self.annex = token_bnf(self.alts, chapters=False)
        _, self.number = lexical_names(self.alts)
        ng = BNF(list)
        for a in self.alts:
            if a.lhs in self.number:
                ng.add(a.lhs, ng.seq(a.seq), a.id)
        # A.8.7 prints non_zero_unsigned_number's `_` in plain type (its
        # editorial note): the underscore character.
        ng.add("_", [ng.sym(("t", "_"))])
        self.ng = ng.finish()
        self.memo = {}

    def number_chart(self, text, start):
        key = (text, start)
        if key not in self.memo:
            ng = self.ng
            toks = [frozenset([ng.index[("t", ch)]]) if ("t", ch) in ng.index else frozenset() for ch in text]
            self.memo[key] = earley(ng, toks, ng.index[("n", start)])
        return self.memo[key]

    def terms(self, g, tok):
        """The terminal symbols of `g` token `tok` can be."""
        out = set()
        i = g.index.get(("t", tok.text))
        if i is not None:
            out.add(i)
        classes = [n for n, k in IDENTIFIER_CLASSES.items() if k == tok.kind]
        if tok.kind == "num":
            classes = [k[1] for k in g.keys if k[0] == "c" and k[1] in self.number
                       and self.number_chart(tok.text, k[1]).accepted]
        if tok.text in ("+", "-"):
            classes.append("sign")
        for n in classes:
            i = g.index.get(("c", n))
            if i is not None:
                out.add(i)
        return frozenset(out)

    def parse(self, toks, start="source_text", annex=False):
        g = self.annex if annex else self.g
        return earley(g, [self.terms(g, t) for t in toks], g.index[("n", start)])

    def derive(self, toks, chart):
        """Alternatives an accepted chart derives, A.8.7's included."""
        alts, classes = derived(chart)
        for pos, sym in classes:
            name = chart.g.keys[sym][1]
            if chart.g.keys[sym][0] == "c":
                if name in self.number:
                    alts |= derived(self.number_chart(toks[pos].text, name))[0]
                else:
                    alts |= {a.id for a in self.alts if a.lhs == name}
        return alts


DIRECTIVE_START = {"define": "text_macro_definition", "default_discipline": "default_discipline_directive",
                   "default_transition": "default_transition_compiler_directive"}


def lexical_alts(alts, raw):
    """A.9.2 and A.9.4, which the tokenizer reads: the comment forms and the
    white space characters `raw` contains (every file has an end)."""
    comments = set()
    lex(raw, comments)
    want = {("comment", "one_line_comment"): "lc" in comments, ("comment", "block_comment"): "bc" in comments,
            ("white_space", "space"): " " in raw, ("white_space", "tab"): "\t" in raw,
            ("white_space", "newline"): "\n" in raw, ("white_space", "eof"): True}
    out = {a.id for a in alts if want.get((a.lhs, a.text))}
    if comments:
        out |= {a.id for a in alts if a.lhs == "comment_text"}
    for kind, lhs in (("lc", "one_line_comment"), ("bc", "block_comment")):
        if kind in comments:
            out |= {a.id for a in alts if a.lhs == lhs}
    return out


def refusal_context(toks, chart):
    """Where the recognizer stopped: `line L: a b c >>d<< e`."""
    i = chart.fail if chart.fail is not None else len(toks)
    before = " ".join(t.text for t in toks[max(0, i - 8):i])
    at = toks[i].text if i < len(toks) else "<end>"
    after = " ".join(t.text for t in toks[i + 1:i + 4])
    return f"{before} >>{at}<< {after}".strip()


_ORACLE = []


def oracle():
    if not _ORACLE:
        _ORACLE.append(Oracle())
    return _ORACLE[0]


def bad_directive(o, directives):
    """The first `default_discipline / `default_transition / `define whose
    head 10.2-10.4's box does not derive, as a refusal context, or None."""
    for name, line in directives:
        toks = lex(line)
        c = o.parse(toks, DIRECTIVE_START[name])
        if not c.accepted:
            return "directive " + refusal_context(toks, c)
    return None


def derive_fixture(rel):
    """(rel, status, detail, alternatives): `derived`, `refused` (the
    recognizer rejects text VerA accepted) or `skipped` (not preprocessable
    here, with the reason)."""
    o, path = oracle(), FIXTURES / rel
    try:
        text, directives = preprocess(path)
    except Unexpandable as e:
        return rel, "skipped", str(e), set()
    toks = lex(text)
    if any(t.kind == "dir" for t in toks):
        return rel, "skipped", "directive " + next(t.text for t in toks if t.kind == "dir"), set()
    bad = bad_directive(o, directives)
    if bad:
        return rel, "refused", bad, set()
    c = o.parse(toks)
    if not c.accepted:
        return rel, "refused", refusal_context(toks, c), set()
    alts = o.derive(toks, c) | lexical_alts(o.alts, path.read_text(errors="replace"))
    for name, line in directives:
        dt = lex(line)
        alts |= o.derive(dt, o.parse(dt, DIRECTIVE_START[name]))
    return rel, "derived", "", alts


def positive_passing(verdicts):
    """Fixtures a strict run passed that make no refusal claim and carry no
    known-gap marker: the only ones whose acceptance is evidence."""
    out = []
    for rel, v in sorted(read_verdicts(verdicts).items()):
        path = FIXTURES / rel
        if v != "pass" or not path.is_file() or path.suffix not in (".va", ".v", ".vams"):
            continue
        t = fixture_tags(path)
        if not t["reject"] and not t["xfail"]:
            out.append(rel)
    return out


def verdicts_file(opts):
    if "verdicts" in opts:
        return Path(opts["verdicts"])
    if VERDICTS.exists():
        return VERDICTS
    print("grammar: --verdicts=<file> from a strict run is required (no tests/fixtures/conformance/VERDICTS.tsv)", file=sys.stderr)
    return None


def pool_map(fn, items, jobs):
    """`[fn(x) for x in items]` in `jobs` forked workers, in any order."""
    if jobs <= 1:
        return list(map(fn, items))
    import multiprocessing
    with multiprocessing.get_context("fork").Pool(jobs) as pool:
        return list(pool.imap_unordered(fn, items, chunksize=4))


def grammar_opts(argv):
    return dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)


def grammar_coverage(argv):
    """`coverage [--verdicts=F] [--jobs=N] [--list=a.va,b.va]`: R3 closed by
    the passing positive fixtures (F: a strict run's `--verdicts` output).
    Prints the worklist: every alternative no such fixture derives."""
    opts = grammar_opts(argv)
    verdicts = verdicts_file(opts)
    if verdicts is None:
        return 2
    fixtures = opts["list"].split(",") if "list" in opts else positive_passing(verdicts)
    o = oracle()
    covered, status = set(), {}
    for rel, st, detail, alts in pool_map(derive_fixture, fixtures, int(opts.get("jobs", 8))):
        status[rel] = (st, detail)
        covered |= alts
    by = lambda s: sorted(r for r, (st, _) in status.items() if st == s)  # noqa: E731
    print(f"grammar coverage: {len(fixtures)} passing positive fixtures ({verdicts}): "
          f"{len(by('derived'))} derived, {len(by('refused'))} refused by the recognizer, "
          f"{len(by('skipped'))} skipped (not preprocessable here)")
    reasons = {}
    for rel in by("skipped"):
        reasons.setdefault(re.sub(r'"[^"]*"', '"..."', status[rel][1]), []).append(rel)
    for why, rels in sorted(reasons.items(), key=lambda kv: -len(kv[1])):
        print(f"  skipped {len(rels):4d}  {why}  (e.g. {rels[0]})")
    for rel in by("refused"):
        print(f"  refused  {rel}: {status[rel][1]}")
    rows = [a for a in o.alts]
    done = [a for a in rows if a.id in covered]
    print(f"alternatives: {len(rows)}; derived by a passing positive fixture: {len(done)} ({pct(len(done), len(rows))}); "
          f"not derived: {len(rows) - len(done)}")
    print("worklist (grammar coverage): id\tproduction\ttext")
    for a in rows:
        if a.id not in covered:
            print(f"  {a.id}\t{a.lhs}\t{a.text}")
    return 0


GRAMMAR_COMMANDS["coverage"] = grammar_coverage


def grammar_earley(argv):
    """`earley [--start=NAME] [--derive] FILE...`: the recognizer on each file
    (preprocessed with tests/fixtures and the file's directory on the include
    path): `accept`, or `refuse` at the first token no Earley item can read.
    `--derive` lists the alternatives an accepted file derives."""
    opts = grammar_opts(argv)
    files = [a for a in argv if not a.startswith("--")]
    if not files:
        print("usage: conformance.py grammar earley [--start=NAME] [--derive] FILE...", file=sys.stderr)
        return 2
    o, status = oracle(), 0
    for f in files:
        path = Path(f).resolve()
        try:
            text, directives = preprocess(path)
        except Unexpandable as e:
            print(f"{f}: skip: {e}")
            continue
        toks = lex(text)
        c = o.parse(toks, opts.get("start", "source_text"))
        bad = bad_directive(o, directives)
        if bad or not c.accepted:
            status = 1
            print(f"{f}: refuse at {bad or refusal_context(toks, c)}")
            continue
        print(f"{f}: accept ({len(toks)} tokens)")
        if "--derive" in argv:
            got = o.derive(toks, c)
            for a in o.alts:
                if a.id in got:
                    print(f"  {a.id}\t{a.lhs}\t{a.text}")
    return status


GRAMMAR_COMMANDS["earley"] = grammar_earley


# ---- diff: the recognizer against VerA ---------------------------------------
GENERATOR_AVOID = ("paramset", "primitive", "config", "connectmodule", "macromodule", "connectrules", "(*")
# A.1.2's first module form needs a port list, whose shortest port is empty,
# and A.4.2's loop generate an undeclared genvar: fillers VerA refuses for
# their own reasons (tests/fixtures/conformance/GRAMMAR-DIFF.tsv), which would hide every target.
GENERATOR_AVOID_ALTS = ("A.1.2/9", "A.4.2/5")


class Generator:
    """Sentences of a BNF that use one chosen rule (L5c item 2): the shortest
    chain of rules from the start down to the rule's left side, every other
    symbol expanded at random within a height budget (the shortest rule once
    the budget runs out), so a sentence stays small and is always finite."""

    def __init__(self, g, start):
        inf = 1 << 30
        h = [0 if t else inf for t in g.term]
        rh = [inf] * len(g.rules)
        changed = True
        while changed:
            changed = False
            for r, (lhs, rhs) in enumerate(g.rules):
                v = 1 + max((h[x] for x in rhs), default=0)
                rh[r] = min(rh[r], v)
                if v < h[lhs]:
                    h[lhs], changed = v, True
        # A paramset, UDP, config or connect module is a narrow host with
        # rules of its own (6.4.1, 7.x): reach a symbol through one only when
        # nothing else reaches it, so a disagreement is about the target.
        avoid = {i for w in GENERATOR_AVOID for i in [g.index.get(("t", w))] if i is not None}
        self.avoid = {r for r, rhs in enumerate(g.rhs) if avoid.intersection(rhs) or g.alt[r] in GENERATOR_AVOID_ALTS}
        parent = {start: None}
        for skip in (self.avoid, set()):
            queue = list(parent)
            for a in queue:
                for r in g.by_lhs[a]:
                    if rh[r] < inf and r not in skip:
                        for i, x in enumerate(g.rhs[r]):
                            if not g.term[x] and x not in parent:
                                parent[x] = (r, i)
                                queue.append(x)
        self.g, self.start, self.h, self.rh, self.parent, self.inf = g, start, h, rh, parent, inf

    def why_not(self, r):
        """None if rule `r` can be generated from the start, else why not."""
        if self.rh[r] >= self.inf:
            return "uses a name with no derivation"
        if self.g.lhs[r] not in self.parent:
            return f"not reachable from {self.g.keys[self.start][1]}"
        return None

    def sentence(self, r, rng, instance, slack=1):
        """Terminal symbols, each through `instance(sym)`, of a sentence
        whose derivation uses rule `r`."""
        g, spine = self.g, []
        x = g.lhs[r]
        while self.parent[x] is not None:
            spine.append(self.parent[x])
            x = g.lhs[self.parent[x][0]]
        spine.reverse()
        out = []

        def free(x, budget):
            # Mostly the shortest rules, so the filler around the target
            # stays small and a disagreement points at the target.
            if g.term[x]:
                out.append(instance(x))
                return
            rules = [q for q in g.by_lhs[x] if q not in self.avoid] or g.by_lhs[x]
            empty = [q for q in rules if not g.rhs[q]]
            if empty and rng.random() < 0.7:
                return  # mostly leave a [ ] or { } out
            low = min(self.rh[q] for q in rules)
            ok = [q for q in rules if self.rh[q] <= (budget if rng.random() < 0.2 else low)]
            for y in g.rhs[rng.choice(ok or [q for q in rules if self.rh[q] == low])]:
                free(y, budget - 1)

        def down(level):
            q, at = spine[level] if level < len(spine) else (r, None)
            for i, y in enumerate(g.rhs[q]):
                if i == at:
                    down(level + 1)
                else:
                    free(y, self.h[y] + slack)

        down(0)
        return out


def join_tokens(texts):
    """Source text for generated tokens: one space between tokens, none
    inside the spellings a lexer reads as one (`'{`, `@*`), a line per `;`."""
    out = []
    for i, t in enumerate(texts):
        prev = texts[i - 1] if i else ""
        glue = (prev, t) in (("'", "{"), ("@", "*"))
        out.append(("" if glue or not out else " ") + t + ("\n" if t in (";", "begin", "end") else ""))
    return "".join(out).replace("\n ", "\n")


class Instances:
    """A text for each terminal symbol of the token grammar: exact text as
    is; a lexical class a fresh legal spelling; a number generated from A.8.7
    itself, one forced alternative at a time when `number_rule` is set."""

    def __init__(self, o, rng, number_rule=None):
        self.o, self.rng, self.n, self.number_rule = o, rng, 0, number_rule
        self.ngen = Generator(o.ng, o.ng.index[("n", "number")])

    def __call__(self, sym):
        kind, v = self.o.g.keys[sym]
        if kind == "t":
            return v
        self.n += 1
        if v in self.o.number:
            ng = self.o.ng
            gen = Generator(ng, ng.index[("n", v)]) if v != "number" else self.ngen
            r = self.number_rule
            if r is not None and v == "number":
                self.number_rule = None
            else:
                r = self.rng.choice(ng.by_lhs[ng.index[("n", v)]])
            return "".join(ng.keys[c][1] for c in gen.sentence(r, self.rng, lambda c: c, slack=1))
        if v == "escaped_identifier" and self.rng.random() < 0.9:
            v = "simple_identifier"  # mostly plain names; 2.8.1's form still gets its share
        return {"simple_identifier": f"g{self.n}", "escaped_identifier": f"\\e{self.n} ",
                "system_task_identifier": "$strobe", "system_function_identifier": "$abstime",
                "system_parameter_identifier": "$mfactor", "string_literal": '"s"', "sign": "+"}[v]


def vera_verdict(vera, path, includes, cwd, timeout=120):
    """VerA's parse-level answer for one file: (`accept` | `syntax` |
    `crash` | `timeout`, detail). `--lint` stops after the frontend, which
    is where every syntax diagnostic is decided. A refusal is a syntax
    refusal when every error's stage is preprocess or parse; one with a
    later-stage error parsed the text, so it counts as accepted."""
    cmd = ["sh", "-c", 'ulimit -v 4194304; exec "$@"', "sh", vera, "--lint", "--diagnostics=json", "--color=never"]
    for d in includes:
        cmd += ["-I", str(d)]
    try:
        p = subprocess.run(cmd + [str(path)], capture_output=True, text=True, timeout=timeout, cwd=cwd)
    except subprocess.TimeoutExpired:
        return "timeout", f"no answer in {timeout} s"
    errors = []
    for line in (p.stdout + "\n" + p.stderr).splitlines():
        if line.startswith("{"):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("level") == "error":
                errors.append(d)
    if p.returncode == 0:
        return "accept", ""
    if not errors:
        tail = (p.stderr.strip().splitlines() or [""])[-1]
        return "crash", f"exit {p.returncode}: {tail[:160]}"
    codes = ",".join(sorted({e.get("code", "?") for e in errors}))
    first = errors[0]
    detail = f"{codes} {first.get('title', '')}: {first.get('message', '')}"[:240]
    if all(e.get("stage") in ("preprocess", "parse") for e in errors):
        return "syntax", detail
    return "accept", "semantic " + detail


def earley_job(job):
    """(label, verdict, Annex-A-only verdict, detail) of the recognizer on a
    file or a text: `accept`, `refuse` or `skip` (not preprocessable here)."""
    label, path, includes, text = job
    o, directives = oracle(), []
    if text is None:
        try:
            text, directives = preprocess(path, includes)
        except Unexpandable as e:
            return label, "skip", "skip", str(e)
    bad = bad_directive(o, directives)
    if bad:
        return label, "refuse", "refuse", bad
    toks = lex(text)
    if any(t.kind == "dir" for t in toks):
        return label, "skip", "skip", "directive " + next(t.text for t in toks if t.kind == "dir")
    c = o.parse(toks)
    if not c.accepted:
        return label, "refuse", "refuse", refusal_context(toks, c)
    alone = o.parse(toks, annex=True).accepted
    return label, "accept", "accept" if alone else "refuse", ""


def mutants(rel, n, seed):
    """`n` one-token mutants of a fixture's own text: (name, text). Tokens on
    directive lines are left alone, so a mutant never just breaks an
    `include; kinds cycle delete, duplicate, swap with the next token."""
    import random
    raw = (FIXTURES / rel).read_text(errors="replace")
    toks = [t for t in lex(raw) if t.kind != "dir"]
    starts = {i for i, line in enumerate(raw.split("\n")) if line.lstrip().startswith("`")}
    line_of = lambda pos: raw.count("\n", 0, pos)  # noqa: E731
    toks = [t for t in toks if line_of(t.pos) not in starts]
    rng, out = random.Random(f"{seed}:{rel}"), []
    for j in range(min(n, len(toks) - 1)):
        kind = ("delete", "duplicate", "swap")[j % 3]
        i = rng.randrange(len(toks) - 1)
        a, b = toks[i], toks[i + 1]
        sa, sb = raw[a.pos:a.end], raw[b.pos:b.end]
        if kind == "delete":
            text = raw[:a.pos] + " " + raw[a.end:]
        elif kind == "duplicate":
            text = raw[:a.end] + " " + sa + " " + raw[a.end:]
        else:
            text = raw[:a.pos] + sb + raw[a.end:b.pos] + sa + raw[b.end:]
        out.append((f"{kind} line {line_of(a.pos) + 1} `{sa}`" + (f" `{sb}`" if kind == "swap" else ""), text))
    return out


def generated_cases(o, k, seed):
    """[(alt id, sample, text)] deriving every alternative k times, and the
    alternatives no sentence can carry, {alt id: why}."""
    import random
    g = o.g
    gen = Generator(g, g.index[("n", "source_text")])
    rule_of = {}
    for r, a in enumerate(g.alt):
        if a:
            rule_of.setdefault(a, r)
    host = next(r for r, a in enumerate(g.alt) if a and g.keys[g.lhs[r]][1] == "analog_primary"
                and g.rhs[r] == (g.index[("c", "number")],))
    ng = o.ng
    out, skipped = [], {}
    for a in o.alts:
        if a.id in rule_of:
            r, nrule = rule_of[a.id], None
        elif a.lhs in o.number:
            nrule = next(q for q, x in enumerate(ng.alt) if x == a.id)
            r = host
            nwhy = Generator(ng, ng.index[("n", "number")]).why_not(nrule)
            if nwhy:
                skipped[a.id] = "A.8.7: " + nwhy
                continue
        else:
            skipped[a.id] = "lexical (A.8.8, A.9.2-A.9.4): the tokenizer reads it, no sentence carries it"
            continue
        why = gen.why_not(r)
        if why:
            skipped[a.id] = why
            continue
        for j in range(k):
            rng = random.Random(f"{seed}:{a.id}:{j}")
            inst = Instances(o, rng, nrule)
            texts = gen.sentence(r, rng, inst)
            out.append((a.id, j, join_tokens(texts)))
    return out, skipped


DIFF_HEAD = (
    "# Where the Annex A recognizer and VerA's parse-level acceptance disagree:\n"
    "# Written by `tools/conformance.py grammar diff`.\n"
    "# source: fixture (as committed), mutant (one token deleted, duplicated or\n"
    "# swapped), generated (a sentence derived from the grammar for one alternative).\n"
    "# earley: accept | refuse at >>token<<; `(needs a chapter box)` marks an\n"
    "# acceptance Annex A (with GRAMMAR_READINGS) alone does not give.\n"
    "# vera: accept (no error, or only errors after parsing) | syntax (every error\n"
    "# from the preprocess or parse stage) | crash.\n"
    "# class: vera-bug (the grammar is right and VerA's parser is not, or VerA\n"
    "# crashed), extension (a documented VerA extension,\n"
    "# which Annex A does not derive), bnf-transcription (the BNF as printed\n"
    "# fails to state a rule the LRM states elsewhere, or states it wrongly; the\n"
    "# PDF prints the same BNF unless the reason says otherwise), context-rule\n"
    "# (a rule outside the BNF decides it: a declaration, a chapter's\n"
    "# restriction, a directive rule, a resource limit; also a BNF restriction\n"
    "# VerA enforces after parsing, where both refuse and only the stage\n"
    "# differs). `reason` says which, and `probe` marks a reading confirmed on\n"
    "# an isolated minimal file.\n"
    "# source\tcase\tearley\tvera\tclass\treason\n")


def grammar_diff(argv):
    """`diff --vera=PATH [--verdicts=F] [--k=2] [--mutants=3] [--seed=1]
    [--jobs=8] [--only=fixture,mutant,generated] [--limit=N] [--work=DIR]
    [--no-vera]`: the grammar oracle's diff. The recognizer and VerA (`--lint`,
    at most four at once, each under `ulimit -v 4 GiB`) judge the same text:
    every .va fixture, one-token mutants of the positive ones the recognizer
    derives, and k sentences generated for each alternative. Each
    disagreement is classified and written to tests/fixtures/conformance/GRAMMAR-DIFF.tsv."""
    import shutil
    from concurrent.futures import ThreadPoolExecutor
    opts = grammar_opts(argv)
    verdicts = verdicts_file(opts)
    if verdicts is None:
        return 2
    vera = opts.get("vera", str(ROOT / "zig-out/bin/vera"))
    k, nmut, seed = int(opts.get("k", 2)), int(opts.get("mutants", 3)), opts.get("seed", "1")
    jobs, limit = int(opts.get("jobs", 8)), int(opts.get("limit", 1 << 30))
    only = set(opts.get("only", "fixture,mutant,generated").split(","))
    work = Path(opts.get("work", ROOT / ".zig-cache/grammar-diff"))
    shutil.rmtree(work / "cases", ignore_errors=True)
    (work / "cases").mkdir(parents=True)
    o = oracle()
    cases = {}

    def add(source, case, path, inc, text=None, known=None):
        cases[(source, case)] = {"source": source, "case": case, "path": path, "inc": inc, "text": text,
                                 "vera": known, "earley": None}

    def run_earley(keys):
        todo = [((s, c), cases[(s, c)]["path"], cases[(s, c)]["inc"], cases[(s, c)]["text"]) for s, c in keys]
        for key, verdict, alone, detail in pool_map(earley_job, todo, jobs):
            cases[key]["earley"] = (verdict, alone, detail)

    fixtures = sorted((rel, v) for rel, v in read_verdicts(verdicts).items()
                      if rel.endswith(".va") and (FIXTURES / rel).is_file())[:limit]
    positive = set()
    for rel, v in fixtures:
        t = fixture_tags(FIXTURES / rel)
        if v == "pass" and not t["reject"] and not t["xfail"]:
            positive.add(rel)
        if "fixture" in only or "mutant" in only:
            add("fixture", rel, FIXTURES / rel, [FIXTURES, (FIXTURES / rel).parent],
                known=("accept", "a passing positive fixture") if rel in positive else None)
    run_earley(list(cases))
    if "fixture" not in only:
        cases.clear()
    if "mutant" in only:
        derived_ok = [rel for rel, _ in fixtures if rel in positive]
        for rel in derived_ok:
            if "fixture" in only and cases[("fixture", rel)]["earley"][0] != "accept":
                continue
            for j, (name, text) in enumerate(mutants(rel, nmut, seed)):
                path = work / "cases" / f"m{len(cases):05d}_{Path(rel).name}"
                path.write_text(text)
                add("mutant", f"{rel}: {name}", path, [FIXTURES, (FIXTURES / rel).parent])
    if "generated" in only:
        gen, skipped = generated_cases(o, k, seed)
        print(f"grammar diff: {len(gen)} sentences for {len({a for a, _, _ in gen})} alternatives; "
              f"{len(skipped)} alternatives carry no sentence:")
        for why in sorted(set(skipped.values())):
            print(f"  {sum(1 for v in skipped.values() if v == why):4d}  {why}")
        for aid, j, text in gen[:limit]:
            path = work / "cases" / f"g{len(cases):05d}.va"
            path.write_text(text)
            add("generated", f"{aid}#{j}", path, [], text=text)
    run_earley([key for key, c in cases.items() if c["earley"] is None])
    # VerA's answers are cached by (binary, include path, text), so a re-run
    # that only re-classifies (`--no-vera`) needs no compiler at all.
    cache_file = work / "vera-cache.json"
    cache = json.loads(cache_file.read_text()) if cache_file.exists() else {}
    stamp = f"{vera}:{os.stat(vera).st_mtime_ns}" if os.path.exists(vera) else vera

    def key(c):
        inc = [str(Path(d).resolve()) for d in c["inc"]]
        h = hashlib.sha256(f"{stamp}|{inc}|".encode() + Path(c["path"]).read_bytes()).hexdigest()
        return h[:32]

    need = [c for c in cases.values() if c["vera"] is None and c["earley"][0] != "skip"]
    for c in need:
        if key(c) in cache:
            c["vera"] = tuple(cache[key(c)])
    need = [c for c in need if c["vera"] is None]
    if need and "--no-vera" not in argv:
        print(f"grammar diff: running {vera} on {len(need)} files", flush=True)
        with ThreadPoolExecutor(4) as ex:
            for i, (c, v) in enumerate(zip(need, ex.map(lambda c: vera_verdict(vera, c["path"], c["inc"], work), need))):
                c["vera"] = v
                cache[key(c)] = list(v)
                if i % 250 == 249:
                    cache_file.write_text(json.dumps(cache))
                    print(f"grammar diff: {i + 1}/{len(need)}", flush=True)
        cache_file.write_text(json.dumps(cache))
    rows, tally = [], {}
    for c in cases.values():
        e, alone, edetail = c["earley"]
        t = tally.setdefault(c["source"], {"cases": 0, "agree": 0, "skip": 0, "disagree": 0, "crash": 0,
                                           "timeout": 0, "unrun": 0, "self": 0})
        t["cases"] += 1
        if e == "skip":
            t["skip"] += 1
            continue
        if c["source"] == "generated" and e != "accept":
            t["self"] += 1  # the generator's own sentence: a tooling bug, never a finding
            continue
        if c["vera"] is None:
            t["unrun"] += 1  # `--no-vera` and nothing cached
            continue
        v, vdetail = c["vera"]
        if v in ("crash", "timeout"):
            t[v] += 1
        elif (e == "accept") == (v == "accept"):
            t["agree"] += 1
            continue
        t["disagree"] += 1
        cls, reason = classify_diff(c, e, alone, edetail, v, vdetail)
        earley = "accept" + (" (needs a chapter box)" if alone != "accept" else "") if e == "accept" else f"refuse at {edetail}"
        vtext = f"{v}" + (f": {vdetail}" if vdetail else "")
        case = c["case"] + (f" | {c['text']}" if c["text"] else "")
        rows.append((c["source"], case, earley, vtext, cls, reason))
    clean = lambda x: re.sub(r"\s+", " ", str(x)).strip()  # noqa: E731
    order = {"fixture": 0, "mutant": 1, "generated": 2}
    rows.sort(key=lambda r: (order[r[0]], r[4], r[1]))
    GRAMMAR_DIFF_TSV.write_text(DIFF_HEAD + "".join("\t".join(clean(x) for x in r) + "\n" for r in rows))
    for src, t in tally.items():
        print(f"grammar diff: {src}: {t['cases']} cases, {t['skip']} not preprocessable here, "
              + (f"{t['self']} refused by the recognizer (generator bug), " if t["self"] else "")
              + (f"{t['unrun']} without a VerA answer, " if t["unrun"] else "")
              + f"{t['agree']} agree, {t['disagree']} disagree ({t['crash']} VerA crashes, {t['timeout']} timeouts)")
    by = {}
    for r in rows:
        by[(r[0], r[4])] = by.get((r[0], r[4]), 0) + 1
    for (src, cls), n in sorted(by.items()):
        print(f"  {src:10s} {cls:18s} {n}")
    print(f"grammar diff: wrote {GRAMMAR_DIFF_TSV.relative_to(ROOT)} ({len(rows)} rows)")
    stale = [r for _, r, _ in DIFF_RULES if r not in DIFF_RULES_USED]
    for r in stale:
        print(f"grammar diff: rule matched nothing: {r[:100]}")
    unclassified = sum(1 for r in rows if r[4] == "unclassified")
    if unclassified:
        print(f"grammar diff: {unclassified} disagreements match no DIFF_RULES entry")
    return 1 if unclassified else 0


# Each disagreement's class and reason: the first rule whose every condition
# holds. `dir` is E (the recognizer accepts, VerA refuses at parse level), V
# (VerA's parser accepts, the recognizer refuses) or X (VerA crashed);
# `at` searches the recognizer's refusal point (`a b >>c<< d`), `vera`
# VerA's diagnostic, `case` the case (fixture, mutant, or alternative id and
# sentence), `chapter` whether only a chapter box's form makes it derive.
# `probe` in a reason means the reading was confirmed on an isolated minimal
# file (the quoted text, in a module) under both the recognizer and VerA
# (2026-10-08, the pinned vera-run003 binary); the rest were read case by
# case. A rule that matches nothing is reported, and so is a case no rule
# matches, so the table cannot silently outlive the disagreements it reads.
DIFF_RULES = [
    # VerA crashed: always a VerA bug.
    ("vera-bug", "VerA segfaults (exit 139) on `cross()` with only its first argument (A.6.5 makes the rest "
     "optional); probe `analog @(cross(V(p) - 1.0)) x = 1.0;`", {"dir": "X", "case": r"cross \( [^,]*\) \)"}),
    ("vera-bug", "VerA segfaults (exit 139) on an empty argument to `$table_model` or `$limit`; probes "
     "`x = $table_model(0.5, , \"3LL\");`, `x = $limit(V(a), , 0.1);`", {"dir": "X"}),

    # ---- VerA's parser accepts what Annex A does not derive -----------------
    # The LRM's own text needs what the BNF lacks (the PDF prints the same BNF).
    ("bnf-transcription", "A.1.4 has no module-level string declaration and A.2.8's string_declaration is "
     "undefined; 3.3 declares module strings (`string myName = default_name;`)", {"dir": "V", "at": r">>string<<"}),
    ("bnf-transcription", "`units` is a Table B.1 keyword, so A.9.1's attr_name ::= identifier cannot spell it; "
     "3.2.1 uses it as a standard attribute (`(* desc=\"...\", units=\"...\" *)`)", {"dir": "V", "at": r">>units<<"}),
    ("bnf-transcription", "A.2.1.1's aliasparam names a parameter_identifier; 3.4.7 and 9.18 alias a hierarchical "
     "system parameter (`aliasparam m = $mfactor;`)", {"dir": "V", "at": r"aliasparam \S+ = >>\$"}),
    ("bnf-transcription", "6.3.6 overrides a hierarchical system parameter by defparam, by name or in a paramset, "
     "`.`-prefixed; A.9.3's hierarchical_identifier ends in an identifier, so `inst.$angle` does not derive",
     {"dir": "V", "at": r"\. >>\$\w+<<"}),
    ("bnf-transcription", "3.6.2.7: a discipline can specify user-defined attributes; A.1.7's discipline_item "
     "has no form for one", {"dir": "V", "at": r"(potential|flow) \w+ ; >>\w+<< ="}),
    ("bnf-transcription", "6.4.3 computes a paramset output variable from `.module_output_variable_identifier`; "
     "no primary derives that form", {"dir": "V", "at": r"[*/+-] >>\.<<"}),
    ("bnf-transcription", "6.7.1: analog functions can be accessed hierarchically; A.8.2's analog_function_call "
     "names an analog_function_identifier only", {"dir": "V", "at": r"\w+ \. \w+ >>\(<<"}),
    ("bnf-transcription", "A.2.4's param_assignment takes one range; 3.4.8 declares multidimensional parameter "
     "arrays", {"dir": "V", "at": r"\] >>\[<<"}),
    ("bnf-transcription", "A.8.3 applies a unary operator to a primary only (as IEEE 1364-2005 A.8.3 does), so "
     "`!!1` or `- -2.0` does not derive; 2.5 puts a unary operator to the left of its operand, and VerA and "
     "every other implementation read two operators (probe `i = !!1;`)", {"dir": "V", "at": r"[-+!~] >>[-+!~]<<"}),
    ("vera-bug", "A.8.1's assignment pattern has no empty element; VerA takes `'{1.0, , 3.0}` and `'{1.0, }` "
     "with no diagnostic (probes; 3.6.3's `'{2.3,4.5,,6.0}` is a nodeset bus initializer)",
     {"dir": "V", "at": r"\{ [^>]*, >>[,}]<<", "vera": r"^($|semantic E0921)"}),
    ("vera-bug", "VerA takes an empty argument where A.8.2 or A.6.5 require one, with no diagnostic: "
     "`noise_table(tbl, , \"tbl\")`, `white_noise(x, )`, `timer(, 1.0)`, `f(, 1.0)` (probes)",
     {"dir": "V", "at": r"(\(|,) >>[,)]<<", "vera": r"^$"}),
    ("vera-bug", "VerA's parser takes an empty argument in a call (A.8.2 derives none; probe `x = f(, 1.0);` "
     "passes with f defined); the later refusal here is for something else",
     {"dir": "V", "at": r"(\(|,) >>[,)]<<", "vera": r"^semantic (?!E0(502|505|516|517|522|894))"}),
    # Both refuse; VerA's parser reads a wider form and refuses it by clause
    # after parsing, so only the stage differs.
    ("context-rule", "both refuse: Annex A derives no such text, and VerA's parser reads a wider form and "
     "refuses it after parsing, by clause (later stage); only the stage differs",
     {"dir": "V", "vera": r"^semantic E0(40[1-8]|41[0-4]|42[2]|43[045]|316|317|326|330|349|363|50[25]|509|516|522|"
                          r"572|70[123]|708|517|894|90[16])"}),
    ("bnf-transcription", "an assignment pattern where A.8.1 and A.2.4 derive none (nested, an override value, a "
     "nodeset, a function argument); 3.3, 3.4.8, 3.6.3 and 4.7.2.3 use one there", {"dir": "V", "at": r">>'<< \{"}),
    ("bnf-transcription", "the recognizer's tokenizer reads `+:`/`-:` as A.8.3's indexed part-select operator, but "
     "in A.7.4's edge-sensitive path `( terminal [ polarity_operator ] : data_source_expression )` they are a "
     "polarity and a colon (IEEE 1364-2005 14.2.3 writes `( posedge clock => ( out +: in ) ) = (10, 8);`)",
     {"dir": "V", "at": r">>[-+]:<<"}),
    ("bnf-transcription", "A.7.5.3's edge_descriptor and A.5.3's edge_indicator are characters (`x1`, `0x`, "
     "`(01)`), which the token-level recognizer reads as an identifier or a number; IEEE 1364-2005 15.4 writes "
     "`edge[01, 0x, x1] clr`", {"dir": "V", "at": r"(edge \[[^>]*|table \( )>>\w+<<"}),
    # VerA's parser takes text no rule gives it.
    ("extension", "VerA extension (`vera_lte`, `vera_interp`): an attribute after `ddt`/`absdelay`; "
     "A.8.2 allows { attribute_instance } only after an analog_function_identifier (probe "
     "`ddt (* vera_lte = 0 *) (V(p))`)", {"dir": "V", "at": r"(ddt|absdelay|idt|idtmod|transition) >>\(\*<<"}),
    ("vera-bug", "A.1.9 and Syntax 6-4 require a paramset_item_declaration before the paramset statements; VerA "
     "takes a paramset with none (probe `paramset ps b; .g = 2.0; endparamset`)", {"dir": "V", "at": r"paramset \S+ \S+ ; >>\.<<"}),
    ("vera-bug", "A.2.6 types a formal by a separate block item declaration (4.7.1); `input integer n;` is no "
     "input_declaration, and VerA takes it (probe)", {"dir": "V", "at": r"input >>(integer|real|string)<<"}),
    ("vera-bug", "A.6.3: only a named block (`begin : name`) declares; VerA takes a declaration in an unnamed "
     "analog block (probe `analog begin real x; ...`)", {"dir": "V", "at": r"begin >>(real|integer|string|parameter)<<"}),
    ("vera-bug", "A.2.1.3 lists either net_decl_assignments or bare net identifiers; VerA takes a list mixing "
     "them (probe `electrical p = 1.5, n;`)", {"dir": "V", "at": r"= [\d.]+ , \w+ >>;<<"}),
    ("vera-bug", "A.7.1's pulsestyle_onevent takes a list_of_path_outputs, without parentheses; VerA takes "
     "`pulsestyle_onevent (y);` (probe; the fixture says it derives)", {"dir": "V", "at": r"pulsestyle_on\w+ >>\(<<"}),
    ("vera-bug", "VerA takes `supply1 supply1 s1;` (probe): A.2.1.3's net_declaration has one net_type, and a "
     "keyword is no discipline_identifier",
     {"dir": "V", "at": r"(supply[01]|tri[01]?|wire|wand|wor|triand|trior|trireg|uwire) >>\1<<"}),
    ("vera-bug", "VerA takes VAMS 2.x's `{...}` concatenation, `{}` included, as a filter coefficient list "
     "(probe); A.8.2's analog_filter_function_arg is a parameter, a `'{...}` pattern or nothing (4.5.11 writes "
     "`laplace_zp(white_noise(k), , '{1,0,1,0,-1,0,-1,0})`)", {"dir": "V", "at": r"(\{ >>\}<<|, >>\{<<)", "vera": r"positive"}),
    ("vera-bug", "VerA takes a variable initializer that is no constant_expression (`real w = white_noise(4e-21, "
     "\"dec\");`); Syntax 3-1 and A.2.2.1 write `real_identifier = constant_expression` "
     "(ch04_expressions/white_noise_declaration_initializer.va relies on it)", {"dir": "V", "at": r"real \w+ = >>\w+<<"}),
    ("vera-bug", "VerA takes a null item among an analog function's declarations (`input a; ; real a;`, probe); "
     "A.2.6 has none", {"dir": "V", "at": r"(input|inout|output) \w+ ; >>;<<"}),
    ("vera-bug", "VerA takes `child(s);`, a module item with no instance name (probe); A.4.1's module_instance "
     "needs a name_of_module_instance", {"dir": "V", "at": r"\w+ \( \w+ >>\)<< ;", "vera": r"^$"}),
    ("vera-bug", "VerA takes `#d 20 = 1'bx;`, a number as an assignment target (probe)", {"dir": "V", "at": r"# \w+ \d+ = >>"}),
    ("vera-bug", "VerA takes `output` in a function declared without `analog` (probe `function real f; input a; "
     "output b; ...`); A.2.6's function_item_declaration has tf_input_declaration only", {"dir": "V", "at": r">>output<<"}),

    # ---- the recognizer accepts what VerA's parser refuses ------------------
    # The grammar's own text over-generates.
    ("bnf-transcription", "only a chapter box's placeholder (`variable_name`, `mcd`: names no production defines) "
     "derives it, and the recognizer reads any expression in that slot", {"dir": "E", "chapter": True,
                                                                       "case": r"^(3\.3|9\.5\.1|A\.2\.8/4)"}),
    ("bnf-transcription", "A.8.2's nature_access_function includes nature_attribute_identifier, whose alternatives "
     "are the attribute keywords abstol, access, ddt_nature, idt_nature and units (A.9.3): the grammar derives "
     "`access(p) <+ 1.0;`, which names no access function (3.6.1; probe)",
     {"dir": "E", "case": r"\b(abstol|access|ddt_nature|idt_nature|units) \("}),
    ("bnf-transcription", "A.8.5 ends array_analog_variable_assignment with `;` and A.6.2 adds another (Annex "
     "A's editorial note), so the grammar as printed derives `g2 = g3; ;` and `for (a = b; c; d = e;)`, which "
     "VerA refuses", {"dir": "E", "case": r"(=[^;]*;\s*;|\bfor\s*\(|duplicate line \d+ `;`)", "vera": r"found `;`|E0219"}),
    ("bnf-transcription", "A.2.4 prints `PATHPULSE$` as a terminal of its own, but 2.8.1's identifier syntax makes "
     "`PATHPULSE$a$y` one identifier (which VerA takes, probe): the spaced sequence the grammar derives is "
     "another text", {"dir": "E", "case": r"PATHPULSE\$\s+\\?\w+\s+\$"}),
    # A rule outside the grammar refuses it.
    ("context-rule", "a VerA resource limit (nesting depth, literal length), not a language rule", {"dir": "E", "vera": r"E0241|E0134"}),
    ("context-rule", "10.3: macro text substitutes as tokens, so two macros' `/` and `*` never form a comment; "
     "the recognizer's preprocessing pastes the texts, so it cannot judge this file", {"dir": "E", "case": r"70_pasted_macros"}),
    ("context-rule", "the grammar derives `child #(2.0, 3.0) (a, b);` as a UDP instantiation (A.5.4: unnamed "
     "instance, delay2); that `child` is a module, whose instance needs a name, comes from its declaration",
     {"dir": "E", "case": r"parameterized_instantiation_unsupported\.va: swap"}),
    ("context-rule", "a compiler-directive rule of 10 or IEEE 1364-2005 19 (operands, macro text, conditional "
     "nesting); the recognizer reads Annex A and 10.2-10.4's boxes, not directive operands", {"dir": "E", "vera": r"^syntax: E01"}),
    ("context-rule", "a port declaration names an identifier not in the module's port list (6.5.2): a "
     "declaration rule the grammar cannot tie", {"dir": "E", "vera": r"^syntax: E0206"}),
    ("context-rule", "a loop generate's index is a declared genvar (6.6.2; A.4.2 just names a genvar_identifier)",
     {"dir": "E", "vera": r"E0238"}),
    ("context-rule", "a generate block's name collides with another declaration (6.6, scopes)", {"dir": "E", "vera": r"E0230"}),
    ("context-rule", "4.7.1's analog function rules: no named block, and a return carries a value",
     {"dir": "E", "vera": r"E022[67]"}),
    ("context-rule", "4.7.1's analog function rules: each formal has a direction and a data type, and there is "
     "at least one", {"dir": "E", "vera": r"E022[45]", "file": r"analog\s+function"}),
    ("context-rule", "a function declares at least one input (IEEE 1364-2005 10.4.1; 4.7.1 for analog "
     "functions)", {"dir": "E", "vera": r"E0224"}),
    ("context-rule", "6.4.1's restrictions on paramset statements", {"dir": "E", "vera": r"E0237"}),
    ("context-rule", "IEEE 1364-2005 clause 14's specify rules (a module path's source and destination are ports "
     "of the right direction, ...)", {"dir": "E", "vera": r"E0245"}),
    ("context-rule", "2.6.2: \"Scale factors are not allowed to be used in defining digital delays\"", {"dir": "E", "vera": r"E0247"}),
    ("context-rule", "attribute instances do not nest (IEEE 1364-2005 3.8)", {"dir": "E", "vera": r"E0357"}),
    ("context-rule", "7.3.1: access of a discrete bit grouping wider than 31 bits is illegal", {"dir": "E", "vera": r"E0222"}),
    ("context-rule", "`resetall inside a module (IEEE 1364-2005 19.6)", {"dir": "E", "vera": r"E0236"}),
    ("context-rule", "a concatenation operand needs a width (IEEE 1364-2005 5.1.14)", {"dir": "E", "vera": r"E0216"}),
    ("context-rule", "the grammar derives `V(a, b, c)` as a call of a user function named V; that V is an "
     "access function taking at most two nets comes from the discipline (5.5.1)", {"dir": "E", "case": r"140_access_three_nets"}),
    ("context-rule", "break, continue and return outside a loop or a function (5.9, 4.7.2.2); A.1.9's "
     "paramset_statement derives analog_function_statement, jump statements included",
     {"dir": "E", "vera": r"E0205 .*(return|break|continue)"}),
    # VerA's parser refuses what the grammar derives and no rule forbids.
    # (Wave 2 A, 2026-10-08: the min:typ:max, null port, declaration-form,
    # `$root`, hierarchical-name, switch-terminal, branch-terminal, `@*`,
    # analog-event null and E0225 rows parse now; their rules went with them.)
    ("context-rule", "9.22: the driver access family, driver_update with it, is legal only in a connect module; A.6.5 "
     "derives `driver_update` in any digital event, and VerA parses it and refuses it by that clause (E0818)",
     {"dir": "E", "vera": r"E0818"}),
]


def classify_diff(c, e, alone, edetail, v, vdetail):
    """(class, reason) for one disagreement: the first DIFF_RULES entry that
    holds, or `unclassified`, which `grammar diff` reports as a failure."""
    direction = "X" if v in ("crash", "timeout") else "E" if e == "accept" else "V"
    case = c["case"] + (" | " + c["text"] if c["text"] else "")
    vtext = f"{v}: {vdetail}" if v != "accept" else vdetail
    for cls, reason, cond in DIFF_RULES:
        if cond.get("dir", direction) != direction:
            continue
        if "chapter" in cond and cond["chapter"] != (alone != "accept"):
            continue
        if "file" in cond and re.search(cond["file"], Path(c["path"]).read_text(errors="replace")) is None:
            continue
        if any(re.search(cond[k], {"at": edetail, "vera": vtext, "case": case}[k]) is None
               for k in ("at", "vera", "case") if k in cond):
            continue
        DIFF_RULES_USED.add(reason)
        return cls, reason
    return "unclassified", "no DIFF_RULES entry matches"


DIFF_RULES_USED = set()


GRAMMAR_COMMANDS["diff"] = grammar_diff


class GrammarOracle(unittest.TestCase):
    """grammar: the box reader, the tokenizer and preprocessor, the Earley
    recognizer and its derivations, the generator, and the classifier."""

    @classmethod
    def setUpClass(cls):
        cls.o = oracle()

    def test_box_reader_splits_alternatives_at_top_level_bars_only(self):
        lex_ = box_lexemes([(False, "a ::= "), (True, "x"), (False, " [ b | c ] { "), (True, ","),
                            (False, " d }\n  | e 0")])
        (name, alts), = box_productions(lex_, "anon")
        self.assertEqual(name, "a")
        self.assertEqual([render(ebnf(x)) for x in alts], ["'x' [ b | c ] { ',' d }", "e 0"])

    def test_box_reader_drops_captions_and_in_box_footnotes(self):
        p = SyntaxBoxes("t.html")
        p.feed('<h3>9.9 T</h3><div class="syntax">x ::= <b>a</b>\n'
               '<sup>1</sup>The $ character shall not be followed by white_space.\n'
               '<strong>Syntax 9-9&mdash;caption</strong></div>')
        (clause, _, parts), = p.boxes
        self.assertEqual(clause, "9.9")
        text = "".join(t for _, t in parts if not CAPTION.match(t))
        self.assertNotIn("white_space", text)
        self.assertNotIn("caption", text)

    def test_extraction_matches_the_committed_ledger_and_the_lrm(self):
        alts, _ = read_syntax()
        by_id = {a.id: a for a in alts}
        self.assertEqual(by_id["A.1.2/1"].text, "{ description }")
        self.assertEqual(by_id["A.6.4/22"].text, "{ attribute_instance } ';'")
        self.assertEqual(by_id["A.8.7/37"].text, "\"'\" [ 's' | 'S' ] 'd'")
        self.assertEqual(by_id["5.6.7/11"].note, "differs from Annex A")
        self.assertEqual(len(by_id), len(alts))  # ids are unique
        head = "".join(ln + "\n" for ln in GRAMMAR_TSV.read_text().split("\n") if ln.startswith("#"))
        rows = [ln for ln in GRAMMAR_TSV.read_text().split("\n") if ln and not ln.startswith("#")]
        self.assertEqual(rows, [f"{a.id}\t{a.lhs}\t{a.text}\t{a.note}" for a in alts],
                         "tests/fixtures/conformance/GRAMMAR.tsv drifted from docs/: run `grammar extract`")
        self.assertIn("grammar-coverage denominator", head)

    def test_tokens(self):
        kinds = lambda s: [(t.kind, t.text) for t in lex(s)]  # noqa: E731
        self.assertEqual(kinds("8 'h FF 1.5e-3 2k"), [("num", "8'hFF"), ("num", "1.5e-3"), ("num", "2k")])
        self.assertEqual(kinds("@(*) (* a *)"), [("op", "@"), ("op", "("), ("op", "*"), ("op", ")"),
                                                 ("op", "(*"), ("id", "a"), ("op", "*)")])
        self.assertEqual(kinds("\\a+b  module $strobe"), [("esc", "\\a+b"), ("kw", "module"), ("sys", "$strobe")])
        self.assertEqual(kinds("integer\x0bx")[1][0], "bad")  # 2.3: a vertical tab is no white space
        self.assertEqual(kinds('"a\\\nb"')[0], ("op", '"'))  # a string stays on its line

    def test_preprocessor(self):
        pp = Preprocessor([FIXTURES])
        text = pp.run("`define SQ(x) ((x)*(x))\n`ifdef NOPE\nbad\n`else\ny = `SQ(a+1);\n`endif\n"
                      "`resetall module m; `define ID(A) (A)\nz = `ID(\\w.v );\n", Path("t.va"))
        self.assertEqual([t.text for t in lex(text)],
                         ["y", "=", "(", "(", "a", "+", "1", ")", "*", "(", "a", "+", "1", ")", ")", ";",
                          "module", "m", ";", "z", "=", "(", "\\w.v", ")", ";"])
        with self.assertRaises(Unexpandable):
            Preprocessor([FIXTURES]).run("`UNDEFINED_MACRO\n", Path("t.va"))
        text, _ = preprocess(FIXTURES / "ch05_analog_behavior/rlc.va")
        self.assertIn("$strobe", text)  # `CHECK from check.vh expanded

    def test_earley_on_a_small_grammar_derives_and_refuses(self):
        g = BNF(list)
        g.add("S", [g.sym(("t", "a")), g.sym(("n", "S")), g.sym(("t", "b"))], "S/1")
        g.add("S", [], "S/2")
        g.finish()
        toks = lambda s: [frozenset([g.index[("t", ch)]]) for ch in s]  # noqa: E731
        c = earley(g, toks("aabb"), g.index[("n", "S")])
        self.assertTrue(c.accepted)
        self.assertEqual(derived(c)[0], {"S/1", "S/2"})
        c = earley(g, toks("aab"), g.index[("n", "S")])
        self.assertFalse(c.accepted)
        self.assertEqual(earley(g, toks("ba"), g.index[("n", "S")]).fail, 0)

    def test_numbers_derive_a_8_7_by_character(self):
        o = self.o
        self.assertTrue(o.number_chart("8'hFF", "number").accepted)
        self.assertFalse(o.number_chart("8'hFG", "number").accepted)
        alts = derived(o.number_chart("1.5e-3", "number"))[0]
        texts = {a.text for a in o.alts if a.id in alts and a.lhs == "real_number"}
        self.assertEqual(texts, {"unsigned_number [ '.' unsigned_number ] exp [ sign ] unsigned_number"})
        self.assertTrue(o.number_chart("1k", "real_number").accepted)

    def test_real_fixtures(self):
        o = self.o
        for rel in ("ch05_analog_behavior/rlc.va", "annex_a_syntax/behavioral_statements.va",
                    "annex_a_syntax/jump_statements.va", "ch04_expressions/absdelay.va"):
            with self.subTest(rel=rel):
                rel_, status, detail, alts = derive_fixture(rel)
                self.assertEqual(status, "derived", detail)
                self.assertIn("A.6.10/1", alts)  # contribution_statement
        # A.1.4 declares no module string (3.3 does): the oracle says so.
        self.assertEqual(derive_fixture("ch03_data_types/string_variables.va")[1], "refused")
        toks = lex("module m; analog begin x = ; end endmodule")
        c = o.parse(toks)
        self.assertFalse(c.accepted)
        self.assertEqual(refusal_context(toks, c), "module m ; analog begin x = >>;<< end endmodule")

    def test_generated_sentences_are_recognized(self):
        import random
        o, g = self.o, self.o.g
        gen = Generator(g, g.index[("n", "source_text")])
        for aid in ("A.6.4/22", "A.8.9/16", "A.2.4/4", "9.4.1/1", "A.6.5/13"):
            r = next(i for i, a in enumerate(g.alt) if a == aid)
            for j in range(3):
                rng = random.Random(f"t:{aid}:{j}")
                text = join_tokens(gen.sentence(r, rng, Instances(o, rng)))
                c = o.parse(lex(text))
                with self.subTest(aid=aid, text=text):
                    self.assertTrue(c.accepted)
                    self.assertIn(aid, o.derive(lex(text), c))

    def test_classifier(self):
        c = {"case": "x.va", "text": None, "path": FIXTURES / "ch05_analog_behavior/rlc.va"}
        self.assertEqual(classify_diff(c, "refuse", "refuse", "p ; electrical p ; >>string<< s ;", "accept",
                                       "a passing positive fixture")[0], "bnf-transcription")
        self.assertEqual(classify_diff(c, "accept", "accept", "", "crash", "exit -11:")[0], "vera-bug")
        self.assertEqual(classify_diff(c, "refuse", "refuse", "x ; >>disable<< w ;", "accept",
                                       "semantic E0401 `disable` is not an analog statement:")[0], "context-rule")
        self.assertEqual(classify_diff(c, "accept", "accept", "", "syntax", "E9999 never seen")[0], "unclassified")




class EvidenceTests(unittest.TestCase):
    """`run`'s accounting: only the named test in the named artifact counts,
    a skip or a failure never covers a clause, and a result row cannot be
    invented or silently overwritten."""

    def test_specialized_requires_the_exact_executed_test(self):
        row = {"id": "timer", "artifact": "host--timer", "test": "absolute time"}
        self.assertEqual(specialized_status(row, {}), "not-run")
        self.assertEqual(specialized_status(row, {
            "host--different": {"host.test.absolute time": "pass"},
        }), "not-run")
        for status in ("pass", "fail", "skip", "xfail"):
            self.assertEqual(specialized_status(row, {
                "host--timer": {"host.test.absolute time": status},
            }), status)

    def test_skips_and_failures_never_cover_a_clause(self):
        clauses = {("ams", "5.1"): {"title": "Events", "classification": "-"}}
        citations = {("ams", "5.1"): [{"test": "host", "kind": "specialized", "polarity": "pos"}]}
        for status, state in (("pass", "covered"), ("fail", "failing"), ("xfail", "failing"),
                              ("skip", "not-run"), ("not-run", "not-run")):
            row, = clause_results(clauses, citations, {"host": status})
            self.assertEqual(row["status"], state)
            self.assertEqual(row["specialized"], status == "pass")

    def test_passing_specialized_test_counts_without_a_fixture(self):
        clauses = {("ams", "5.1"): {"title": "Events", "classification": "-"}}
        cites = {("ams", "5.1"): [{"test": "host", "kind": "specialized", "polarity": "pos"}]}
        row, = clause_results(clauses, cites, {"host": "pass"})
        self.assertEqual(row["status"], "covered")
        self.assertTrue(row["specialized"])
        self.assertFalse(row["fixture"])

    def test_failure_does_not_disappear_behind_a_passing_test(self):
        clauses = {("ams", "5.1"): {"title": "Events", "classification": "-"}}
        citations = {("ams", "5.1"): [
            {"test": name, "kind": kind, "polarity": "pos"}
            for name, kind in (("fixture", "fixture"), ("host", "specialized"))
        ]}
        row, = clause_results(clauses, citations, {"fixture": "pass", "host": "xfail"})
        self.assertEqual(row["status"], "failing")

    def test_missing_citations_and_missing_execution_are_distinct(self):
        clauses = {("ams", "5.1"): {"title": "Events", "classification": "-"}}
        row, = clause_results(clauses, {}, {})
        self.assertEqual(row["status"], "uncovered")
        row, = clause_results(clauses, {("ams", "5.1"): [
            {"test": "declared-only", "kind": "specialized", "polarity": "pos"}]}, {})
        self.assertEqual(row["status"], "not-run")

    def test_no_fixed_oracle_is_not_reported_as_a_missing_test(self):
        clauses = {("ams", "1.4"): {"title": "Conventions", "classification": "non-normative"}}
        row, = clause_results(clauses, {}, {}, {("ams", "1.4"): "no-fixed-oracle"})
        self.assertEqual(row["status"], "not-applicable")
        self.assertEqual(row["disposition"], "no-fixed-oracle")
        # A passing test still covers a clause that has a disposition: the
        # disposition explains the absence of a test, not the presence of one.
        cites = {("ams", "1.4"): [{"test": "doc", "kind": "fixture", "polarity": "pos"}]}
        row, = clause_results(clauses, cites, {"doc": "pass"}, {("ams", "1.4"): "no-fixed-oracle"})
        self.assertEqual(row["status"], "covered")

    def test_dispositions_only_name_whole_clauses(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "tests/fixtures/conformance/GAPS.tsv"
            path.parent.mkdir(parents=True)
            path.write_text("standard\tcitation\tbaseline\tdisposition\tsources\treason\n"
                            "ams\t1.4\tuncovered\tno-fixed-oracle\t-\tnon-normative\n"
                            "ams\t3.4.1:1\tF\texecutable\t-\tsentence\n")
            self.assertEqual(read_dispositions(root), {("ams", "1.4"): "no-fixed-oracle"})

    def test_markdown_separates_no_fixed_oracle_from_uncovered(self):
        report = {
            "measured_at": "now", "commit": "c", "source_sha256": "s",
            "fixture_counts": {}, "assertion_validation_counts": {},
            "spice_counts": {}, "specialized_counts": {}, "unit_execution_counts": {},
            "clauses": [{"standard": "ams", "clause": "1.4", "title": "Conventions",
                         "classification": "non-normative", "status": "not-applicable",
                         "fixture": False, "specialized": False}],
            "feature_groups": [], "specialized_checks": {},
            "ams_obligations": {"mandatory": 0, "total": 0, "levels": {},
                                "unattributed_failures": {}},
            "suites": [],
        }
        text = markdown(report)
        self.assertIn("| No fixed oracle |", text)
        self.assertIn("| Verilog-AMS 2023 | 1 | 0 | 0 | 0 | 0 | 0 | 1 |", text)
        self.assertIn("not conformance failures", text)

    def test_passing_refusal_does_not_turn_an_unsupported_feature_into_coverage(self):
        clauses = {("ieee", "7.1"): {"title": "Gates", "classification": "not-supported"}}
        citations = {("ieee", "7.1"): [{"test": "reject", "kind": "fixture", "polarity": "neg"}]}
        row, = clause_results(clauses, citations, {"reject": "pass"})
        self.assertEqual(row["status"], "unsupported")
        self.assertTrue(row["negative"])
        row, = clause_results(clauses, citations, {"reject": "xfail"})
        self.assertEqual(row["status"], "failing")

    def test_result_rows_cannot_silently_overwrite_or_invent_a_verdict(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.tsv"
            for text in ("pass\tx\nfail\tx\n", "success\tx\n", "pass\t\n", "pass\tx\ty\n"):
                path.write_text(text)
                with self.assertRaises(ValueError):
                    read_results(path)
            path.write_text("pass\tx\nskip\ty\n")
            self.assertEqual(read_results(path), {"x": "pass", "y": "skip"})
        with self.assertRaises(ValueError):
            merge_results({"x": "pass"}, {"x": "pass"})

    def test_successful_build_cannot_substitute_for_missing_execution_records(self):
        with self.assertRaises(ValueError):
            require_results({}, {"a.c", "b.c"}, "VPI")
        with self.assertRaises(ValueError):
            require_results({"a.c": "pass"}, {"a.c", "b.c"}, "VPI")
        require_results({"a.c": "pass", "b.c": "xfail"}, {"a.c", "b.c"}, "VPI")
        row = {"id": "VPI-LINE-INSTANCE", "artifact": "vpi_acceptance", "test": "VPI-LINE-INSTANCE"}
        with self.assertRaises(ValueError):
            require_specialized_results([row], {})
        require_specialized_results([row], {
            "vpi_acceptance": {"vpi_app.test.VPI-LINE-INSTANCE": "xfail"},
        })

    def test_catalog_points_to_real_assertions_and_requirements(self):
        rows = read_specialized(ROOT, clause_inventory(), read_ledger())
        self.assertTrue(rows)
        self.assertTrue(any(":" in row["citation"] for row in rows))
        self.assertTrue(any(row["source"].endswith(".c") for row in rows))

    def test_specialized_assertion_can_evidence_a_sentence(self):
        ledger = {"5.1:1": {"pol": "+", "kind": "-", "oracle": "?"}}
        tags = {"host": {"cites": [("5.1:1", "pos")], "specialized": True, "c": False}}
        for status, expected in (("pass", "E3"), ("skip", "E1"), ("fail", "F"), ("xfail", "F")):
            rows, _ = levels(ledger, tags, {"host": status}, {}, set())
            self.assertEqual(rows["5.1:1"], expected)

    def test_perturbation_requires_a_matching_normal_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(assertion_validation(root, {"a.va": "pass"}), {})
            (root / "ams-perturbed.tsv").write_text("pass\ta.va\n")
            self.assertEqual(assertion_validation(root, {"a.va": "pass"}), {"a.va": "pass"})
            with self.assertRaises(ValueError):
                assertion_validation(root, {"b.va": "pass"})
            with self.assertRaises(ValueError):
                require_results({"a.va": "pass"}, {"a.va", "b.va"}, "AMS assertion validation")

    def test_perturbation_never_overwrites_normal_failure_or_missing_execution(self):
        ledger = {"5.1:1": {"pol": "+", "kind": "-", "oracle": "?"}}
        tags = {"a.va": {"cites": [("5.1:1", "pos")], "c": False, "only": False, "neighbours": []}}
        for normal, expected in (("pass", "E3"), ("fail", "F"), ("xfail", "F"), ("skip", "E1")):
            rows, _ = levels(ledger, tags, {"a.va": normal}, {"a.va": "pass"}, set())
            self.assertEqual(rows["5.1:1"], expected)
        for validation in ("fail", "xfail", "skip", "unasserted", None):
            rows, _ = levels(ledger, tags, {"a.va": "pass"}, {"a.va": validation}, set())
            self.assertEqual(rows["5.1:1"], "E2")

    def test_unified_collection_uses_fresh_perturbations_and_preserves_normal_results(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tests").mkdir()
            (root / "ams.tsv").write_text("pass\tch01_intro/current_source.va\n")
            before = collect_report(root, [])
            self.assertEqual(before["ams_obligations"]["rows"]["5.6.1:1"], "E2")
            (root / "ams-perturbed.tsv").write_text("pass\tch01_intro/current_source.va\n")
            after = collect_report(root, [])
            self.assertEqual(after["ams_obligations"]["rows"]["5.6.1:1"], "E3")
            self.assertEqual(after["fixture_results"], before["fixture_results"])
            self.assertEqual(after["assertion_validation_counts"], {"pass": 1})

    def test_bare_clause_does_not_cover_all_its_sentences(self):
        ledger = {f"5.1:{i}": {"pol": "+", "kind": "-", "oracle": "?"} for i in (1, 2)}
        tags = {"host": {"cites": [("5.1", "pos")], "specialized": True, "c": False}}
        rows, _ = levels(ledger, tags, {"host": "pass"}, {}, set())
        self.assertEqual(set(rows.values()), {"E1"})

    def test_behavior_group_requires_all_checks_and_preserves_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "groups.tsv"
            path.write_text("timing\tTiming behavior\ta;b\n")
            for second, expected in (("pass", "covered"), ("fail", "failing"), ("xfail", "failing"),
                                     ("skip", "not-run"), ("unasserted", "not-run"), (None, "not-run")):
                results = {"a": "pass"}
                if second is not None:
                    results["b"] = second
                row, = feature_groups(path, {"a", "b"}, results)
                self.assertEqual(row["status"], expected)
            row, = feature_groups(path, {"a", "b"}, {"a": "xfail"})
            self.assertEqual(row["status"], "failing")

    def test_behavior_groups_reject_unknown_and_double_counted_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "groups.tsv"
            for text in ("one\tDescription\tmissing\n", "one\tDescription\ta;a\n",
                         "one\tDescription\ta\ntwo\tDescription\ta\n",
                         "one\tDescription\ta\none\tDescription\tb\n"):
                path.write_text(text)
                with self.assertRaises(ValueError):
                    feature_groups(path, {"a", "b"}, {})


class GapInventoryTests(unittest.TestCase):
    """GAPS.tsv, PROFILES.json and FEATURE_GAPS.tsv name real clauses, files
    and checks, and claim no execution."""

    def test_review_inventory_keeps_every_baseline_gap_and_valid_references(self):
        clauses = clause_inventory()
        ledger = read_ledger()
        seen = set()
        counts = {"ams": 0, "ieee": 0, "sentence": 0}
        for line in (FIXTURES / "conformance/GAPS.tsv").read_text().splitlines():
            if not line or line.startswith("#"):
                continue
            standard, cite, baseline, disposition, sources, reason = line.split("\t")
            self.assertNotIn((standard, cite), seen)
            seen.add((standard, cite))
            self.assertIn((standard, cite.split(":")[0]), clauses)
            if ":" in cite:
                self.assertIn(cite, ledger)
                self.assertIn(ledger[cite]["kind"], MANDATORY_KINDS)
                counts["sentence"] += 1
            else:
                counts[standard] += 1
            self.assertIn(baseline, {"uncovered", "unsupported", "failing", "not-run", "E0", "E1", "F"})
            self.assertIn(disposition, {"executable", "host-profile", "no-fixed-oracle", "existing-partial", "conditional"})
            self.assertTrue(reason)
            if sources != "-":
                for source in sources.split(";"):
                    path = (ROOT / source).resolve()
                    self.assertTrue(path.is_relative_to(ROOT) and path.is_file(), source)
            if disposition == "executable":
                self.assertNotEqual(sources, "-")
        # This is the frozen pre-regression review inventory, not live coverage.
        self.assertEqual(counts, {"ams": 27, "ieee": 231, "sentence": 23})

    def test_pending_profiles_have_inputs_and_explicit_oracles(self):
        profiles = json.loads((FIXTURES / "conformance/PROFILES.json").read_text())
        seen = set()
        for row in profiles["scenarios"]:
            self.assertNotIn(row["id"], seen)
            seen.add(row["id"])
            self.assertTrue(row["setup"] and row["pending"])
            self.assertTrue((ROOT / row["source"]).is_file())
            self.assertTrue(row.get("expected") or row.get("expect"))
            if "expected" in row:
                self.assertTrue((ROOT / row["expected"]).read_text())
            if "runner" in row:
                source = ROOT / row["runner"]
                names = {node.name for node in ast.walk(ast.parse(source.read_text()))
                         if isinstance(node, ast.FunctionDef)}
                self.assertTrue(row["tests"])
                self.assertTrue(set(row["tests"]) <= names)

    def test_behavior_inventory_names_real_checks_without_claiming_execution(self):
        specialized = read_specialized(ROOT, clause_inventory(), read_ledger())
        known = {p.relative_to(FIXTURES).as_posix() for p in FIXTURES.rglob("*") if p.is_file()}
        known.update("specialized:" + row["id"] for row in specialized)
        rows = feature_groups(FIXTURES / "conformance/FEATURE_GAPS.tsv", known, {})
        self.assertTrue(rows)
        self.assertEqual({row["status"] for row in rows}, {"not-run"})


class FixtureLayoutTests(unittest.TestCase):
    """The path relationships discovery and coverage depend on."""

    def test_host_and_vpi_designs_exist(self):
        missing = []
        for path in fixture_files("*_host.zig", "*.c"):
            key = "design" if path.suffix == ".c" else "device"
            for rel in re.findall(rf"(?m)^//! {key} (.+)$", path.read_text()):
                if not (FIXTURES / rel).is_file():
                    missing.append(f"{path.relative_to(ROOT)}: {rel}")
        self.assertEqual(missing, [])

    def test_legal_neighbours_exist(self):
        missing = []
        for path in fixture_files("*.va", "*.v"):
            for rel in re.findall(r"(?m)^\s*//! neighbour (.+)$", path.read_text()):
                if not (path.parent / rel).is_file():
                    missing.append(f"{path.relative_to(FIXTURES)}: {rel}")
        self.assertEqual(missing, [])

    def test_spice_models_exist_at_the_declared_relative_path(self):
        missing = []
        for path in FIXTURES.rglob("*.sp"):
            for rel in re.findall(r'(?im)^\s*\.hdl\s+"([^"]+)"', path.read_text()):
                if not (path.parent / rel).is_file():
                    missing.append(f"{path.relative_to(FIXTURES)}: {rel}")
        self.assertEqual(missing, [])

    def test_spice_oracle_hashes_match_the_deck(self):
        for path in FIXTURES.rglob("*.sp"):
            oracle = path.with_suffix(".expected.json")
            if not oracle.exists():
                continue
            expected = json.loads(oracle.read_text()).get("netlist_sha256")
            if expected:
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected, str(path))

    def test_digital_goldens_have_a_source(self):
        missing = []
        for path in FIXTURES.rglob("*.expected.txt"):
            stem = path.name.removesuffix(".expected.txt")
            if not path.with_name(stem + ".v").is_file():
                missing.append(str(path.relative_to(FIXTURES)))
        self.assertEqual(missing, [])

    def test_fixture_verdict_baseline_names_existing_sources(self):
        missing = []
        for line in VERDICTS.read_text().splitlines():
            if not line or line.startswith("#"):
                continue
            _, rel = line.split("\t", 1)
            if not (FIXTURES / rel).is_file():
                missing.append(rel)
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
