#!/usr/bin/env python3
"""Host observations: what a simulator host says about a model, which the
model cannot assert about itself.

    tests/host.py diagnostic_observations --vera VERA [--results F] [--strict]
    tests/host.py paired_compiler_observations --vera VERA [--results F]
    tests/host.py <profile> [--adapter EXE] [--results F]
    tests/host.py selftest [-v]

The first two take the exact `vera` the build made (`zig build
test`). The profiles (`PROFILES` below, also under `zig build test`) need a real host bound through an adapter
(`--adapter`, or `VERA_HOST_PROFILE_ADAPTER`); without one every assertion
records a skip, never a pass. `tests/README.md` has the adapter protocol.
`selftest` feeds the oracles wrong observations and checks they refuse; it
is never conformance evidence. Each runner records its results as
`<artifact>.test.<method>` rows, the names `SPECIALIZED.tsv` registers.
"""
import argparse
import copy
import io
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures"
# The `--vera` runners' compiler and the profiles' adapter, set by `main`.
VERA = None
ADAPTER = None


# ---------------------------------------------------------------------------
# The adapter protocol: one JSON request on stdin, one JSON response on stdout.
# ---------------------------------------------------------------------------

def configure_adapter(path):
    global ADAPTER
    ADAPTER = Path(path).resolve(strict=True) if path else None
    if ADAPTER is not None and (not ADAPTER.is_file() or not os.access(ADAPTER, os.X_OK)):
        raise ValueError(f"host profile adapter is not executable: {ADAPTER}")


def decode_response(output):
    response = json.loads(output)
    if not isinstance(response, dict) or type(response.get("schema_version")) is not int or response["schema_version"] != 1:
        raise ValueError("host profile response must have schema_version 1")
    if response.get("status") == "unavailable":
        reason = response.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            raise ValueError("unavailable host profile requires an applicability reason")
        raise unittest.SkipTest(reason)
    if response.get("status") != "ok" or not isinstance(response.get("observations"), dict):
        raise ValueError("host profile response requires status ok and observations object")
    return response["observations"]


class HostProfileCase(unittest.TestCase):
    def observe(self, scenario, source, setup):
        if ADAPTER is None:
            self.skipTest(f"{scenario}: no real host adapter configured")
        source = Path(source)
        if not source.is_absolute():
            source = ROOT / source
        source = source.resolve(strict=True)
        with tempfile.TemporaryDirectory(prefix=f"vera-{scenario}-") as directory:
            request = {
                "schema_version": 1,
                "scenario": scenario,
                "source": str(source),
                "work_dir": directory,
                "setup": setup,
            }
            completed = subprocess.run(
                [str(ADAPTER)], input=json.dumps(request), cwd=ROOT,
                text=True, capture_output=True, timeout=180,
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            return decode_response(completed.stdout)


class EvidenceResult(unittest.TextTestResult):
    """Every outcome as a `<artifact>.test.<method>` row: a skip, an error and
    an unexpected success are each recorded, never dropped or promoted."""
    artifact = "profile_observations"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.rows = {}

    def record(self, test, status):
        name = f"{self.artifact}.test.{test._testMethodName}"
        if name in self.rows:
            raise ValueError(f"duplicate profile observation: {name}")
        self.rows[name] = status

    def addSuccess(self, test):
        super().addSuccess(test)
        self.record(test, "pass")

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.record(test, "fail")

    def addError(self, test, err):
        super().addError(test, err)
        self.record(test, "fail")

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.record(test, "skip")

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self.record(test, "xfail")

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self.record(test, "fail")


def evidence_result(artifact):
    return type("EvidenceResult_" + artifact, (EvidenceResult,), {"artifact": artifact})


def write_results(path, rows):
    if path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(f"{status}\t{name}\n" for name, status in sorted(rows.items())))


def run_cases(case_class, artifact, argv=None):
    """A profile runner: the adapter, the cases, the results file."""
    parser = argparse.ArgumentParser(prog=f"host.py {artifact}", description=case_class.__doc__)
    parser.add_argument("--adapter", type=Path, default=os.environ.get("VERA_HOST_PROFILE_ADAPTER"))
    parser.add_argument("--results", type=Path)
    args = parser.parse_args(argv)
    configure_adapter(args.adapter)
    result = unittest.TextTestRunner(verbosity=2, resultclass=evidence_result(artifact)).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(case_class)
    )
    write_results(args.results, result.rows)
    return int(not result.wasSuccessful())


def run_vera_cases(case_class, artifact, argv=None):
    """A `--vera` runner: the build supplies the exact artifact. `--strict`
    returns nonzero for the known (expected) failures too."""
    global VERA
    parser = argparse.ArgumentParser(prog=f"host.py {artifact}", description=case_class.__doc__)
    parser.add_argument("--vera", required=True, type=Path)
    parser.add_argument("--results", type=Path)
    parser.add_argument("--strict", action="store_true", help="Exit nonzero for known conformance failures too")
    args = parser.parse_args(argv)
    VERA = args.vera.resolve(strict=True)
    result = unittest.TextTestRunner(verbosity=2, resultclass=evidence_result(artifact)).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(case_class)
    )
    write_results(args.results, result.rows)
    return int(not result.wasSuccessful() or (args.strict and bool(result.expectedFailures)))


# ---------------------------------------------------------------------------
# diagnostic_observations: simulator diagnostics an HDL model cannot observe.
# ---------------------------------------------------------------------------

DIAGNOSTIC_FIXTURES = FIXTURES / "ch09_system_tasks"


class DiagnosticObservations(unittest.TestCase):
    """Observe simulator diagnostics that cannot be asserted inside an HDL model.

    Expected failures retain real positive assertions and unittest's XPASS guard.
    Compilation/execution failures in setUp are errors, never expected failures.
    """

    def setUp(self):
        fixture = getattr(type(self), self._testMethodName).fixture
        source = DIAGNOSTIC_FIXTURES / fixture
        self.scratch = tempfile.TemporaryDirectory(prefix="vera-diagnostic-")
        self.addCleanup(self.scratch.cleanup)
        work = Path(self.scratch.name)
        # These are host-only inputs, so the ordinary AMS fixture collector
        # must not award them assertion credit. Activate their runner settings
        # only in this private copy; keep the basename for source locations.
        text = source.read_text(encoding="utf-8").replace("// observation: ", "//! ")
        local = work / source.name
        local.write_text(text)
        result = subprocess.run(
            [str(VERA), "--run", "--work-dir", str(work / "build"), str(local)],
            cwd=work, text=True, capture_output=True, timeout=180,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.output = diagnostic_text(result.stdout + result.stderr)
        self.filename = source.name

    def assertLocation(self):
        # The standard does not prescribe file:line versus a design location.
        self.assertRegex(self.output, re.escape(Path(self.filename).stem))

    def assertTime(self):
        # 2 ns, allowing scientific, fixed-point or explicitly scaled output.
        self.assertRegex(self.output, r"(?i)(?:2(?:\.0*)?\s*(?:e-0?9|ns)|0\.0{8}2)(?!\d)")

    def test_finish_default_reports_time_and_location(self):
        self.assertLocation()
        self.assertTime()

    def test_finish_zero_has_no_diagnostic(self):
        self.assertEqual(self.output.strip(), "")

    def test_finish_two_reports_time_location_and_statistics(self):
        self.assertLocation()
        self.assertTime()
        self.assertRegex(self.output, r"(?i)memory")
        self.assertRegex(self.output, r"(?i)cpu")

    def test_finish_initial_reports_initialization(self):
        self.assertLocation()
        self.assertRegex(self.output, r"(?i)initiali[sz]")

    def test_finish_dc_reports_swept_value(self):
        self.assertLocation()
        self.assertRegex(self.output, r"\bdrive\b[^\n]*\b2(?:\.0*)?\b")

    def test_info_reports_simulation_time(self):
        self.assertIn("observe-info", self.output)
        self.assertTime()

    def test_info_initial_reports_initialization(self):
        self.assertIn("observe-info", self.output)
        self.assertRegex(self.output, r"(?i)initiali[sz]")

    def test_info_dc_reports_swept_value(self):
        self.assertIn("observe-info", self.output)
        self.assertRegex(self.output, r"\bdrive\b[^\n]*\b2(?:\.0*)?\b")

    def test_info_has_no_error_severity(self):
        self.assertIn("observe-info", self.output)
        lines = "\n".join(line for line in self.output.splitlines() if "observe-info" in line)
        self.assertNotRegex(lines, r"(?i)\b(?:fatal|error|warning)\b")


def diagnostic_text(output):
    """Exclude runner progress; its time labels are not task diagnostics."""
    scaffold = r"(?:=== [^\n]+ ===|--- point \d+ ---|  t = \S+  dt = \S+)"
    return "\n".join(line for line in output.splitlines() if not re.fullmatch(scaffold, line))


# Exact tests and inputs are paired explicitly. No source file or clause gets
# credit merely because some other assertion in this executable passed.
for name, fixture in {
    "test_finish_default_reports_time_and_location": "diagnostic_finish_default.va",
    "test_finish_zero_has_no_diagnostic": "diagnostic_finish_zero.va",
    "test_finish_two_reports_time_location_and_statistics": "diagnostic_finish_statistics.va",
    "test_finish_initial_reports_initialization": "diagnostic_finish_initial.va",
    "test_finish_dc_reports_swept_value": "diagnostic_finish_dc_sweep.va",
    "test_info_reports_simulation_time": "diagnostic_info_transient.va",
    "test_info_initial_reports_initialization": "diagnostic_info_initial.va",
    "test_info_dc_reports_swept_value": "diagnostic_info_dc_sweep.va",
    "test_info_has_no_error_severity": "diagnostic_info_initial.va",
}.items():
    getattr(DiagnosticObservations, name).fixture = fixture


# ---------------------------------------------------------------------------
# paired_compiler_observations: a named refusal beside its numeric control.
# ---------------------------------------------------------------------------

def assert_exclusive_refusal(result, code):
    """Only actual error records can satisfy a named, exclusive refusal."""
    if result.returncode != 1:
        raise AssertionError(f"expected a diagnosed refusal (exit 1), got {result.returncode}\n"
                             + result.stdout + result.stderr)
    errors = []
    for line in result.stderr.splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise AssertionError(f"non-diagnostic stderr in refusal: {line}") from error
        if not isinstance(record, dict) or not {"level", "code"} <= record.keys():
            raise AssertionError(f"malformed diagnostic record: {line}")
        if record["level"] == "error":
            errors.append(record["code"])
    if not errors or set(errors) != {code}:
        raise AssertionError(f"expected only error[{code}], got {errors!r}\n{result.stderr}")


def assert_numeric_control(result, expected):
    """Require every named comparison, including its independent literal."""
    output = result.stdout + result.stderr
    if result.returncode != 0:
        raise AssertionError(f"legal control exited {result.returncode}\n{output}")
    if "FAIL" in output or re.search(r"(?m)^\s*error(?:\[|:)", output):
        raise AssertionError(f"legal control reported a failure\n{output}")
    observed = {}
    for line in output.splitlines():
        if "ok=" not in line:
            continue
        match = re.fullmatch(r"(.+) got=(\S+) want=(\S+) ok=(\S+)", line.strip())
        if not match:
            raise AssertionError(f"malformed check: {line}")
        label, got_text, want_text, verdict = match.groups()
        if label in observed:
            raise AssertionError(f"repeated check: {label}")
        if label not in expected:
            raise AssertionError(f"unexpected check: {label}")
        if verdict != "1":
            raise AssertionError(f"failed check: {line}")
        try:
            got, want = float(got_text), float(want_text)
        except ValueError as error:
            raise AssertionError(f"non-numeric check: {line}") from error
        literal, tolerance = expected[label]
        if not math.isfinite(got) or not math.isfinite(want):
            raise AssertionError(f"non-finite check: {line}")
        if want != literal or abs(got - literal) > tolerance:
            raise AssertionError(f"check disagrees with independent value {literal}: {line}")
        observed[label] = got
    if observed.keys() != expected.keys():
        raise AssertionError(f"missing checks: {sorted(expected.keys() - observed.keys())}\n{output}")


class PairedCompilerObservations(unittest.TestCase):
    """Named paired checks for requirements whose effect includes a refusal.

    Every assertion requires both the named diagnostic on the forbidden input
    and the numeric results of its legal control. Source comments, warnings and
    a successful compile alone earn no positive behavioral evidence.
    """

    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="vera-paired-")
        self.addCleanup(scratch.cleanup)
        self.work = Path(scratch.name)

    def invoke(self, relative, *, reject=False):
        source = FIXTURES / relative
        command = [
            str(VERA), "--lint" if reject else "--run",
            "--diagnostics=json" if reject else "--diagnostics=text",
            "--color=never", "-I", str(FIXTURES),
            "--work-dir", str(self.work / source.stem), str(source),
        ]
        return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=180)

    def test_paramset_selection_uses_only_paramset_ranges(self):
        # Both candidates admit l=1. A has no un-overridden parameter and wins.
        # Looking at the module's range too early would wrongly fall back to B.
        assert_exclusive_refusal(
            self.invoke("ch06_hierarchy/paramset_selection_ignores_module_ranges_rejected.va",
                        reject=True), "E0361"
        )
        assert_numeric_control(
            self.invoke("ch06_hierarchy/paramset_selection_by_paramset_ranges.va"),
            {
                "the paramset with fewer un-overridden parameters is selected": (2.0, 0.0),
                "so the resistor stamps 0.5 / 2.0": (0.25, 0.0),
            },
        )

    def test_bare_default_discipline_withdraws_the_default(self):
        assert_exclusive_refusal(
            self.invoke("ch10_directives/default_discipline_reset_leaves_no_default.va",
                        reject=True), "E0337"
        )
        assert_numeric_control(
            self.invoke("ch10_directives/default_discipline_undeclared_net.va"),
            {"the defaulted net has the electrical potential access": (0.5, 0.0)},
        )

    def test_standalone_hierarchy_accepts_instances_and_parameter_overrides(self):
        assert_exclusive_refusal(
            self.invoke("ch06_hierarchy/nested_module_definition_rejected.va", reject=True),
            "E0240",
        )
        assert_numeric_control(
            self.invoke("ch06_hierarchy/hierarchy_overview_instances_and_overrides.va"),
            {
                "a parameter overridden by order": (2.0, 0.0),
                "a parameter overridden by name": (3.0, 0.0),
                "a parameter altered by a defparam": (5.0, 0.0),
                "an instance with no override keeps the declared default": (1.0, 0.0),
                "a vector port element the child drives, read by the parent": (0.5, 1e-12),
                "and the other element, independently": (0.25, 1e-12),
            },
        )
        assert_numeric_control(
            self.invoke("ch06_hierarchy/defparam_precedence_over_instance_override.va"),
            {
                "the defparam wins a conflict with the instance assignment": (5.0, 0.0),
                "a defparam alone replaces the default": (7.0, 0.0),
                "an instance the defparam does not name keeps its own assignment": (3.0, 0.0),
                "and the winning value is the one the device stamps": (2.5, 0.0),
                "for the defparam-only instance too": (3.5, 0.0),
                "and for the untouched one": (1.5, 0.0),
            },
        )


# ---------------------------------------------------------------------------
# report_observations: operating-point, parameter-report and model-help pages.
# ---------------------------------------------------------------------------

REPORT_SOURCE = "tests/fixtures/ch02_lexical/operating_point_report_attributes.va"
HELP_SOURCE = "tests/fixtures/ch06_hierarchy/model_help_descriptions.va"
OUTPUT_VARIABLE_SOURCE = "tests/fixtures/ch03_data_types/desc_units_output_variable_rows.va"
NUMBER = re.compile(r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eEdD][+-]?\d+)?")
NAME = re.compile(r"[A-Za-z_$][A-Za-z_0-9$]*(?:\.[A-Za-z_$][A-Za-z_0-9$]*)*")


def report_rows(report):
    """Extract values only from complete tokens in the original report."""
    if not isinstance(report, dict) or not isinstance(report.get("text"), str):
        raise AssertionError("a report must contain the actual host text")
    text = report["text"]
    rows = report.get("rows")
    if not text.strip() or not isinstance(rows, list):
        raise AssertionError("a report must contain nonempty text and row spans")
    values = {}
    occupied = []
    for row in rows:
        if not isinstance(row, dict):
            raise AssertionError("a report row must contain name/value spans")
        spans = []
        for key in ("name_span", "value_span"):
            span = row.get(key)
            if (not isinstance(span, list) or len(span) != 2
                    or any(type(offset) is not int for offset in span)
                    or not 0 <= span[0] < span[1] <= len(text)):
                raise AssertionError(f"invalid {key}: {span!r}")
            start, end = span
            if any(start < old_end and old_start < end for old_start, old_end in occupied):
                raise AssertionError("report tokens must not overlap")
            occupied.append((start, end))
            spans.append((start, end))
        (ns, ne), (vs, ve) = spans
        name, value = text[ns:ne], text[vs:ve]
        if not NAME.fullmatch(name) or not NUMBER.fullmatch(value):
            raise AssertionError(f"invalid report tokens: {name!r}, {value!r}")
        # Do not accept a span selecting resistance within resistance_alias
        # or selecting 12 within a value such as 120 or 1.2e+12.
        for start, end in spans:
            for index in (start - 1, end):
                if 0 <= index < len(text) and re.match(r"[A-Za-z_0-9$.+-]", text[index]):
                    raise AssertionError("a span selected only part of a report token")
        if "\n" in text[min(ns, vs):max(ne, ve)] or "\r" in text[min(ns, vs):max(ne, ve)]:
            raise AssertionError("a report name and value must belong to the same row")
        name = name.rsplit(".", 1)[-1]
        if name in values:
            raise AssertionError(f"duplicate report entry: {name}")
        number = float(value.replace("D", "e").replace("d", "e"))
        if not math.isfinite(number):
            raise AssertionError(f"nonfinite report value: {value}")
        values[name] = number
    return values


def assert_report_omits(test, report, name):
    # Inspect the full raw output as well as the parsed rows. An adapter
    # cannot hide an unwanted entry merely by leaving its span out.
    test.assertNotRegex(report["text"], rf"(?<![A-Za-z_0-9$]){re.escape(name)}(?![A-Za-z_0-9$])")
    test.assertNotIn(name, report_rows(report))


class ReportObservations(HostProfileCase):
    """Exact operating-point, parameter-report and model-help host assertions.

    The operating_point_reports scenario returns observations:
      short_report, full_report, parameter_report:
        {"text": RAW_HOST_REPORT, "rows": [
          {"name_span": [start, end], "value_span": [start, end]}, ...]}
      state_before_reports, state_after_reports:
        {"mfactor": NUMBER, "resistance": NUMBER, "voltage_pn": NUMBER,
         "current_p_to_n": NUMBER, "hidden": NUMBER, "multiplied": NUMBER,
         "divided": NUMBER, "unchanged": NUMBER}

    Report text must be the actual single-instance host report, not a transcript
    of input commands, an echoed source listing, or a report reconstructed from
    metadata/internal values. Spans are zero-based Unicode character offsets,
    end-exclusive, selecting the complete name and numeric value tokens on one
    report row. This keeps host presentation syntax out of the oracle while
    requiring every asserted value to be present in the captured report itself.
    All rows in the selected report must be described; repeated names are errors.
    Names may be instance-qualified; assertions use their final component.
    Numbers may use decimal scientific notation (e/E or d/D).

    State observations are actual simulator state immediately before requesting
    the reports and after the reports, at the same solved operating point.
    current_p_to_n is the physical terminal current, including the ordinary
    $mfactor contribution scaling. Reading these states supplements the report
    assertions; it never replaces them.

    The model_help scenario returns {"help_text": RAW_HOST_HELP}. It must invoke
    help for the setup's requested model independently, not return an all-model
    catalog or the source text. Both descriptions in the input are deliberately
    different so accidentally requesting the base module cannot satisfy the
    paramset test.

    The output_variable_reports scenario uses the existing declaration fixture
    and returns {"output_variable_report": REPORT} with the same raw-text/spans
    format. Request the host's automatically exported output-variable values,
    without adding internal/block-local variables to a user-selected watch list.
    The module-scope values must be accessible; attributes on block-local lv
    must not export it or attach its "block local" description to this report.
    """
    artifact = "report_observations"

    def operating_point(self):
        return self.observe("operating_point_reports", REPORT_SOURCE, {
            "module": "operating_point_report_attributes",
            "parameters": {"m": 4, "resistance_alias": 2000},
            "bias": {"p": 1, "n": 0},
            "reports": ["short", "full", "parameters"],
            "observe_state": ["before_reports", "after_reports"],
        })

    def assertNumber(self, actual, expected):
        self.assertTrue(type(actual) in (int, float), f"not a measured number: {actual!r}")
        self.assertTrue(math.isfinite(actual), f"nonfinite number: {actual!r}")
        self.assertTrue(math.isclose(actual, expected, rel_tol=1e-8, abs_tol=1e-30),
                        f"{actual!r} != {expected!r}")

    def assertReportValue(self, report, name, expected):
        rows = report_rows(report)
        self.assertIn(name, rows, f"{name!r} is absent from the actual report")
        # No omitted duplicate row may satisfy the unique-entry assertion.
        self.assertEqual(len(re.findall(
            rf"(?<![A-Za-z_0-9$]){re.escape(name)}(?![A-Za-z_0-9$])", report["text"]
        )), 1, f"{name!r} must occur once in the single-instance report")
        self.assertNumber(rows[name], expected)

    def test_operating_point_report_hides_values(self):
        observed = self.operating_point()
        short = observed["short_report"]
        self.assertReportValue(short, "resistance", 2000)
        assert_report_omits(self, short, "hidden")
        # The standard mandates omission only from the short report; it does
        # not require a host to expose this value in a full report. Observe
        # the real state to distinguish omission from deleting the variable.
        self.assertNumber(observed["state_before_reports"]["hidden"], 17)
        self.assertNumber(observed["state_after_reports"]["hidden"], 17)

    def test_operating_point_report_multiplicity(self):
        observed = self.operating_point()
        for kind in ("short_report", "full_report"):
            report = observed[kind]
            for name, expected in (("multiplied", 12), ("divided", 2), ("unchanged", 5)):
                self.assertReportValue(report, name, expected)
        # A report scaling implementation must not rewrite the model's
        # values, affect its current, or mutate state while producing a page.
        expected_state = {
            "mfactor": 4, "resistance": 2000, "voltage_pn": 1,
            "current_p_to_n": 0.002, "hidden": 17, "multiplied": 3,
            "divided": 8, "unchanged": 5,
        }
        for when in ("state_before_reports", "state_after_reports"):
            for name, expected in expected_state.items():
                self.assertNumber(observed[when][name], expected)

    def test_parameter_report_omits_alias(self):
        report = self.operating_point()["parameter_report"]
        self.assertReportValue(report, "resistance", 2000)
        assert_report_omits(self, report, "resistance_alias")

    def test_module_help_description(self):
        observed = self.observe("model_help", HELP_SOURCE, {"model": "help_base"})
        self.assertIsInstance(observed["help_text"], str)
        self.assertIn("Base resistor help", observed["help_text"])

    def test_paramset_help_description(self):
        observed = self.observe("model_help", HELP_SOURCE, {"model": "help_model"})
        self.assertIsInstance(observed["help_text"], str)
        self.assertIn("Paramset resistor help", observed["help_text"])

    def output_variables(self):
        return self.observe("output_variable_reports", OUTPUT_VARIABLE_SOURCE, {
            "module": "ch3_desc_units_output_variable_rows",
            "bias": {"p": 1, "n": 0},
            "report": "automatic_output_variables",
        })["output_variable_report"]

    def test_module_output_variable_values_are_accessible(self):
        report = self.output_variables()
        for name, expected in (("cgs", 4.21e-15), ("cdb", 3e-15), ("ids", 7)):
            self.assertReportValue(report, name, expected)

    def test_block_variable_attributes_are_ignored(self):
        report = self.output_variables()
        # This is the host's automatic output-variable list, not an optional
        # debugger report of every variable in the design.
        self.assertReportValue(report, "cgs", 4.21e-15)
        assert_report_omits(self, report, "lv")
        self.assertNotIn("block local", report["text"])

    def test_noise_summary_combines_same_instance_source_names(self):
        observed = self.observe(
            "noise_contribution_report",
            "tests/fixtures/ch04_expressions/noise_source_name.va",
            {"report": "single_instance_noise_contribution_summary",
             "analysis": "noise", "frequency_hz": 1000,
             "bias": {"p": 1, "n": 0},
             "output": "short_circuit_current_through_p_bias_source",
             "density_units": "A^2/Hz",
             "group_by": "instance_and_source_name"},
        )
        # Same raw report/spans contract as the operating-point tests. The
        # adapter must request the actual host summary, never combine emitted
        # source metadata itself. Separate source names must stay distinct.
        report = observed["noise_report"]
        self.assertReportValue(report, "thermal", 4e-18)
        self.assertReportValue(report, "excess", 5e-18)


# ---------------------------------------------------------------------------
# indirect_equation_observations: the §5.6.7:1002 equality-row tolerance.
# ---------------------------------------------------------------------------

INDIRECT_SOURCE = "tests/fixtures/ch05_analog_behavior/indirect_equation_lhs_tolerance.va"
TRIAL_RESIDUALS = (0.5e-9, -0.5e-9, 2e-9, -2e-9)


class IndirectEquationObservations(HostProfileCase):
    """Check an indirect equation's live residual gate and its solved circuit.

    Parsed nature attributes, emitted u_abstol, and final voltages alone cannot
    answer it. An adapter lacking a residual-tolerance observer must return
    status=unavailable with its reason.

    Scenario "indirect_equation_tolerance" requests an operating-point solve of
    the supplied model, with reltol zero to isolate the absolute tolerance.
    The response's observations object must contain:

      solver: {analysis: "op", converged: true, reltol: 0.0}
      solution: {"V(sense)": <solved voltage>, "V(drive)": <solved voltage>}
      equations: [{
          branch: "control", lhs: "V(sense)", tolerance_role: "equation_residual",
          residual_abstol: <absolute tolerance used by the solver for this row>,
          gate_checks: [{
              lhs_value: <requested trial voltage>,
              residual: <actual equality residual at that trial voltage>,
              accepted: <actual result of the solver's residual convergence gate>
          }, ...]
      }]

    Return one gate check for each requested lhs_value, in request order. Gate
    checks isolate this equation's residual gate with other stopping conditions
    satisfied; they must not use an unknown-update gate or a test-side comparison
    to a parsed tolerance. The independent positive/negative trial residuals
    distinguish the lhs's 1 nV tolerance from the controlling branch's 1 uV
    tolerance and the source-current unknown's 1 pA tolerance. These checks and
    the solved circuit must come from the host, not reconstructed observations.
    """

    def finite_number(self, value, label):
        self.assertIn(type(value), (int, float), f"{label} must be numeric")
        self.assertTrue(math.isfinite(value), f"{label} must be finite")
        return value

    def test_indirect_equation_lhs_tolerance(self):
        observed = self.observe(
            "indirect_equation_tolerance",
            INDIRECT_SOURCE,
            {
                "analysis": "op",
                "top": "indirect_equation_lhs_tolerance",
                "reltol": 0.0,
                "observe_equation": {"branch": "control", "lhs": "V(sense)"},
                "gate_lhs_values": [1.0 + residual for residual in TRIAL_RESIDUALS],
            },
        )
        solver = observed["solver"]
        self.assertEqual(solver["analysis"], "op")
        self.assertIs(solver["converged"], True)
        self.assertEqual(self.finite_number(solver["reltol"], "solver reltol"), 0.0)

        solution = observed["solution"]
        sense = self.finite_number(solution["V(sense)"], "solved V(sense)")
        drive = self.finite_number(solution["V(drive)"], "solved V(drive)")
        self.assertAlmostEqual(sense, 1.0, delta=1e-9)
        # Two 1 kohm resistors carry the same 1 mA; checking the drive
        # prevents a reported requested target from posing as a circuit solve.
        self.assertAlmostEqual(drive, 2.0, delta=2e-9)

        rows = observed["equations"]
        self.assertIsInstance(rows, list)
        matches = [
            row for row in rows
            if row.get("branch") == "control" and row.get("lhs") == "V(sense)"
        ]
        self.assertEqual(len(matches), 1, "observe the unique equality row, not its current unknown")
        row = matches[0]
        self.assertEqual(row["tolerance_role"], "equation_residual")
        abstol = self.finite_number(row["residual_abstol"], "equality residual abstol")
        self.assertAlmostEqual(abstol, 1e-9, delta=1e-21)

        checks = row["gate_checks"]
        self.assertIsInstance(checks, list)
        self.assertEqual(len(checks), len(TRIAL_RESIDUALS))
        for check, requested_residual in zip(checks, TRIAL_RESIDUALS):
            self.assertEqual(
                self.finite_number(check["lhs_value"], "gate lhs_value"),
                1.0 + requested_residual,
            )
            # Subtraction near 1.0 rounds at binary64 precision, well below
            # the distance of these probes from the 1 nV boundary.
            residual = self.finite_number(check["residual"], "observed equality residual")
            self.assertAlmostEqual(residual, requested_residual, delta=3e-16)
            self.assertIs(
                check["accepted"],
                abs(requested_residual) < 1e-9,
                f"wrong residual gate result at {requested_residual:g} V",
            )


# ---------------------------------------------------------------------------
# conditional_observations: requirements conditional on a documented host
# capability (a finite identifier limit, an irreversible input fault, an
# opaque driver). None is assumed for VerA; the adapter must establish it.
# ---------------------------------------------------------------------------

IDENTIFIER = FIXTURES / "ch02_lexical/identifier_length_limit.va.in"
INPUT = FIXTURES / "ch09_system_tasks/input_position_restore_failure.va"
DRIVER = FIXTURES / "ch09_system_tasks/driver_type_unavailable.va"


def compile_result(case, observation, accepted, diagnostic=None):
    case.assertIs(type(observation["exit_code"]), int)
    case.assertIsInstance(observation["stdout"], str)
    case.assertIsInstance(observation["stderr"], str)
    output = observation["stdout"] + observation["stderr"]
    records = observation["diagnostics"]
    case.assertIsInstance(records, list)
    for record in records:
        case.assertIsInstance(record, dict)
        case.assertIn(record["level"], ("error", "warning", "note"))
        case.assertIsInstance(record["code"], str)
    errors = [record["code"] for record in records if record["level"] == "error"]
    if accepted:
        case.assertEqual(observation["exit_code"], 0, output)
        case.assertEqual(errors, [], output)
    else:
        # Signals, allocation exhaustion, and unrelated parser errors cannot
        # stand in for the documented identifier-length diagnostic.
        case.assertGreater(observation["exit_code"], 0, output)
        case.assertEqual(set(errors), {diagnostic}, output)
        case.assertNotRegex(output, r"(?i)out.?of.?memory|allocation fail|memory exhausted")


class ConditionalObservations(HostProfileCase):
    """Exact assertions for requirements conditional on a documented host capability."""

    def test_identifier_length_limit(self):
        capability = self.observe("identifier_length_limit", IDENTIFIER, {"operation": "describe"})
        limit = capability["limit"]
        self.assertIs(type(limit), int)
        self.assertGreaterEqual(limit, 1024)
        self.assertIsInstance(capability["documentation"], str)
        self.assertTrue(capability["documentation"].strip())
        diagnostic = capability["diagnostic_code"]
        self.assertRegex(diagnostic, r"^E[0-9]{4}$")
        template = IDENTIFIER.read_text(encoding="utf-8")
        self.assertEqual(template.count("@IDENTIFIER@"), 2)
        with tempfile.TemporaryDirectory(prefix="vera-identifier-boundary-") as directory:
            for length, accepted in ((limit, True), (limit + 1, False)):
                source = Path(directory) / f"length_{length}.va"
                source.write_text(template.replace("@IDENTIFIER@", "a" * length))
                observed = self.observe("identifier_length_limit", source, {
                    "operation": "compile", "identifier_length": length,
                    "observe_structured_diagnostics": True,
                })
                compile_result(self, observed, accepted, diagnostic)

    def test_input_position_restore_failure(self):
        # Identical reads and rejected steps in both runs. The control proves
        # that rejection alone does not cause a fatal error.
        setup = {"input_bytes": "41 73\n", "accepted_time": 0, "trial_time": 1e-9,
                 "reject_trial": True, "operation": "restore"}
        control = self.observe("input_position_restore_failure", INPUT, dict(setup, inject_fault=False))
        self.assertEqual(control["trial_values"], [41])
        self.assertIs(control["iteration_rejected"], True)
        self.assertIs(control["restore_attempted"], True)
        self.assertIs(control["fatal"], False)
        self.assertIs(control["simulation_terminated"], False)
        self.assertIs(control["continued_after_restore"], True)
        self.assertEqual(control["retry_values"], [41])

        fault = self.observe("input_position_restore_failure", INPUT, dict(setup, inject_fault=True))
        self.assertEqual(fault["trial_values"], [41])
        self.assertIs(fault["iteration_rejected"], True)
        self.assertIs(fault["restore_attempted"], True)
        self.assertIs(fault["backing_position_restorable"], False)
        self.assertIs(fault["buffer_replay_available"], False)
        self.assertIs(fault["restore_failed"], True)
        self.assertIs(fault["fatal"], True)
        self.assertIs(fault["simulation_terminated"], True)
        self.assertIs(fault["continued_after_restore"], False)
        self.assertEqual(fault["retry_values"], [])
        self.assertIsInstance(fault["diagnostic"], str)
        self.assertRegex(fault["diagnostic"], r"(?i)\bfatal\b")
        self.assertRegex(fault["diagnostic"], r"(?i)restor|reset|rewind|position")

    def test_driver_type_unavailable(self):
        observed = self.observe("driver_type_unavailable", DRIVER, {
            "opaque_net": "driver_type_unavailable.opaque",
            "known_net": "driver_type_unavailable.known",
            "sample_time": 25e-9,
            "opaque_driver_count": 1,
        })
        # An invalid index, no driver, or an ordinary known driver does not
        # exercise the conditional rule.
        self.assertIsInstance(observed["unavailable_reason"], str)
        self.assertTrue(observed["unavailable_reason"].strip())
        self.assertIs(observed["opaque_type_available"], False)
        for name in ("opaque_driver_count", "opaque_driver_index", "opaque_driver_type",
                     "known_driver_count", "known_driver_type"):
            self.assertIs(type(observed[name]), int)
        self.assertEqual(observed["opaque_driver_count"], 1)
        self.assertEqual(observed["opaque_driver_index"], 0)
        self.assertEqual(observed["opaque_driver_type"], 0)
        self.assertEqual(observed["known_driver_count"], 1)
        self.assertIs(observed["known_type_available"], True)
        self.assertEqual(observed["known_driver_type"], 16)  # DRIVER_BEHAVIORAL
        self.assertEqual(observed["vpi_errors"], [])


# ---------------------------------------------------------------------------
# directive_documentation: AMS 10.5:4, a documentation requirement. Reading the
# compiler's macro table or compiling an `ifdef __VERA__ model cannot establish
# it; the manual chapters docs/SUMMARY.md links are read instead.
# ---------------------------------------------------------------------------

def language_manual_pages(docs):
    pages = []
    user_section = True
    for line in (docs / "SUMMARY.md").read_text(encoding="utf-8").splitlines():
        if line.startswith("# "):
            user_section = not re.search(r"developer|development|test catalog", line, re.I)
        if not user_section:
            continue
        for link in re.findall(r"\]\(([^)]+\.md)(?:#[^)]*)?\)", line):
            path = (docs / link).resolve()
            if (path.is_relative_to(docs.resolve()) and path.is_file()
                    and path.name != "conformance.md"):
                pages.append(path)
    return pages


def documents_tool_macro(text):
    # Require an explanatory paragraph, not a macro name in an unrelated
    # output listing. Inline code around the spelling is allowed.
    without_examples = re.sub(r"(?ms)^```.*?^```[^\n]*", "", text)
    heading = ""
    for paragraph in re.split(r"\n\s*\n", without_examples):
        if paragraph.startswith("#"):
            heading = paragraph
        if "__VERA__" not in paragraph:
            continue
        context = heading + "\n" + paragraph
        provider = re.search(r"\b(?:VerA|simulator|tool|compiler)\b", context, re.I)
        definition = re.search(
            r"\b(?:predefined|built[ -]in|(?:automatically|always) defined|"
            r"defined by|(?:compiler|tool|simulator)[ -]provided)\b",
            context, re.I,
        )
        if provider and definition:
            return True
    return False


class DirectiveDocumentationObservations(unittest.TestCase):
    """The tool-specific predefined macro is documented in the user manual."""

    def test_tool_macro_is_documented(self):
        pages = language_manual_pages(ROOT / "docs")
        self.assertTrue(pages, "no language or usage manual chapters were found")
        self.assertTrue(
            any(documents_tool_macro(path.read_text(encoding="utf-8")) for path in pages),
            "AMS 10.5:4 requires the Verilog-AMS user manual to document the "
            "tool-specific predefined __VERA__ macro; source/fixture comments "
            "and conditional-compilation success are not documentation.",
        )


# ---------------------------------------------------------------------------
# absdelta_rejection_observations: §8.4.7:1004, unconsumed absdelta events on
# a rejected step.
# ---------------------------------------------------------------------------

ABSDELTA_SOURCE = "tests/fixtures/ch08_scheduling/absdelta_unconsumed_events_rejected.va"


class AbsdeltaRejectionObservations(HostProfileCase):
    """Reject a real pending absdelta batch and compare the accepted control.

    The scenario "absdelta_unconsumed_events_rejected" pauses the digital kernel
    after consuming initialization, solves a tentative 12 ns analog endpoint,
    and observes the pending interpolated events before deciding its fate.

    Both accept and reject operations return an observations object containing:

      initial_event_count: 1
      trial: {id: <solution identity>, time: <seconds>, voltage: <V(p)>}
      pending_before_decision: [<pending event>, ...]
      delivered_before_decision: []
      rejected_solution_ids: [<identity>, ...]
      accepted_solution_times: [<seconds>, ...]
      delivered_after_decision: [<delivered event>, ...]
      hdl_event_count: <actual HDL counter after the run>
      final_voltage: <actual solved V(p)>

    Each event has a unique nonempty string id, a nonempty solution_id that
    identifies the actual generating trial, and its scheduled time in seconds.
    Delivered events additionally include the HDL-sampled voltage. A pending
    event must remain identifiable when delivered; adapters may assign stable
    opaque IDs to genuine observed events if the host does not publish IDs.

    For operation=reject, reject the trial while its events are still unconsumed,
    report pending_after_rejection immediately, then accept the requested retry
    and final points. For operation=accept, accept and consume the original
    trial's pending events. Do not manufacture a queue or rejection record from
    expected event times or a final waveform. Missing instrumentation or a host
    that cannot create this pending/rejected state must report unavailable.

    Two further scenarios use normal mixed-scheduler execution with a requested
    analog grid [0, 12 ns]. Adaptive error-control steps are allowed.
    "absdelta_does_not_force_timesteps" returns
    analog_solution_times (the complete actual accepted analog solve trace,
    including solver points introduced by events), delivered_events (including
    initialization, with time and voltage), and hdl_event_count. A paired run with
    monitor_enabled=0 removes the monitor by conditional generation, using identical
    solver settings. The actual trace must match this no-monitor control. The
    adapter must not constrain the solver to suppress event-created steps.
    "absdelta_zero_delta"
    returns the same fields after parameter overrides delta=0, time_tol=1 second,
    expr_tol=100 volts; it must deliver every changed analog endpoint with no
    interpolated events despite those much larger tolerances.

    "absdelta_d2a_discards_pending" uses the separate D2A fixture. It returns the
    same initial/trial/pending_before_decision/delivered_before_decision fields
    as the rejection scenario, then pending_before_d2a (after delivering the
    first delta event), d2a_time, rejected_solution_ids,
    discarded_pending_event_ids, pending_after_d2a, delivered_events (all
    non-initial events across the run), analog_solution_times, hdl_event_count,
    and final_voltage. The D2A at 4 ns must invalidate the genuine lookahead
    solution and its remaining queue entries. A scheduler unable to reach and
    observe that lookahead state must report unavailable.
    """

    def number(self, value, label):
        self.assertIn(type(value), (int, float), f"{label} must be numeric")
        self.assertTrue(math.isfinite(value), f"{label} must be finite")
        return value

    def event_ids(self, events):
        self.assertIsInstance(events, list)
        ids = []
        for event in events:
            self.assertIsInstance(event["id"], str)
            self.assertTrue(event["id"])
            self.assertIsInstance(event["solution_id"], str)
            self.assertTrue(event["solution_id"])
            ids.append(event["id"])
        self.assertEqual(len(ids), len(set(ids)), "duplicate event identity")
        return set(ids)

    def assert_event_times(self, events, expected_count):
        self.assertEqual(len(events), expected_count)
        for index, event in enumerate(events, 1):
            expected = index * 2.5e-9
            # Each event can spend a fresh expr_tol=1 uV, or 10 fs at
            # 0.1 V/ns. Its digital rounding adds at most half a 1 fs tick.
            self.assertAlmostEqual(
                self.number(event["time"], "event time"),
                expected, delta=index * 1e-14 + 0.5e-15,
            )
            if "voltage" in event:
                self.assertAlmostEqual(
                    self.number(event["voltage"], "HDL-sampled voltage"),
                    index * 0.25, delta=index * 1e-6 + 0.05e-6,
                )

    def assert_trial(self, observed):
        self.assertIs(type(observed["initial_event_count"]), int)
        self.assertEqual(observed["initial_event_count"], 1)
        trial = observed["trial"]
        self.assertIsInstance(trial["id"], str)
        self.assertTrue(trial["id"])
        self.assertAlmostEqual(self.number(trial["time"], "trial time"), 12e-9, delta=1e-21)
        self.assertAlmostEqual(self.number(trial["voltage"], "trial voltage"), 1.2, delta=1e-12)
        pending = observed["pending_before_decision"]
        ids = self.event_ids(pending)
        self.assert_event_times(pending, 4)
        self.assertEqual({event["solution_id"] for event in pending}, {trial["id"]})
        self.assertEqual(observed["delivered_before_decision"], [])
        return trial["id"], ids

    def test_absdelta_unconsumed_events_rejected(self):
        setup = {
            "top": "absdelta_unconsumed_events_rejected",
            "analysis": "tran",
            "initial_time": 0.0,
            "trial_time": 12e-9,
            "pause_digital_after_initialization": True,
            "observe_unconsumed_events_before_decision": True,
        }
        control = self.observe(
            "absdelta_unconsumed_events_rejected", ABSDELTA_SOURCE,
            dict(setup, operation="accept"),
        )
        control_trial, control_ids = self.assert_trial(control)
        self.assertEqual(control["rejected_solution_ids"], [])
        self.assertEqual(control["accepted_solution_times"], [0.0, 12e-9])
        delivered = control["delivered_after_decision"]
        self.assertEqual(self.event_ids(delivered), control_ids)
        self.assertEqual({event["solution_id"] for event in delivered}, {control_trial})
        self.assert_event_times(delivered, 4)
        self.assertTrue(all("voltage" in event for event in delivered))
        self.assertIs(type(control["hdl_event_count"]), int)
        self.assertEqual(control["hdl_event_count"], 5)
        self.assertAlmostEqual(self.number(control["final_voltage"], "control voltage"), 1.2, delta=1e-12)

        rejected = self.observe(
            "absdelta_unconsumed_events_rejected", ABSDELTA_SOURCE,
            dict(setup, operation="reject", retry_time=2e-9, final_time=4e-9),
        )
        rejected_trial, rejected_ids = self.assert_trial(rejected)
        self.assertEqual(rejected["rejected_solution_ids"], [rejected_trial])
        self.assertEqual(rejected["pending_after_rejection"], [])
        self.assertEqual(rejected["accepted_solution_times"], [0.0, 2e-9, 4e-9])
        delivered = rejected["delivered_after_decision"]
        new_ids = self.event_ids(delivered)
        self.assertTrue(new_ids.isdisjoint(rejected_ids), "a rejected event survived")
        self.assertNotIn(rejected_trial, {event["solution_id"] for event in delivered})
        self.assert_event_times(delivered, 1)
        self.assertTrue(all("voltage" in event for event in delivered))
        self.assertIs(type(rejected["hdl_event_count"]), int)
        self.assertEqual(rejected["hdl_event_count"], 2)
        self.assertAlmostEqual(self.number(rejected["final_voltage"], "retried voltage"), 0.4, delta=1e-12)

    def assert_initial_event(self, observed):
        events = observed["delivered_events"]
        self.event_ids(events)
        self.assertGreaterEqual(len(events), 1)
        self.assertEqual(self.number(events[0]["time"], "initial event time"), 0.0)
        self.assertEqual(self.number(events[0]["voltage"], "initial event voltage"), 0.0)
        self.assertIs(type(observed["hdl_event_count"]), int)
        self.assertEqual(observed["hdl_event_count"], len(events))
        return events[1:]

    def test_absdelta_does_not_force_timesteps(self):
        setup = {
            "top": "absdelta_unconsumed_events_rejected",
            "analysis": "tran", "requested_analog_times": [0.0, 12e-9],
            "observe_all_analog_solution_times": True,
            "normal_mixed_scheduler": True,
        }
        control = self.observe("absdelta_does_not_force_timesteps", ABSDELTA_SOURCE,
                               dict(setup, parameters={"monitor_enabled": 0}))
        self.assertEqual(control["delivered_events"], [])
        self.assertEqual(control["hdl_event_count"], 0)
        self.assert_solution_trace(control["analog_solution_times"])
        observed = self.observe("absdelta_does_not_force_timesteps", ABSDELTA_SOURCE, setup)
        self.assertEqual(observed["analog_solution_times"], control["analog_solution_times"])
        events = self.assert_initial_event(observed)
        self.assert_event_times(events, 4)
        self.assertTrue(all("voltage" in event for event in events))

    def test_absdelta_zero_delta_ignores_tolerances(self):
        setup = {
            "top": "absdelta_unconsumed_events_rejected",
            "analysis": "tran", "requested_analog_times": [0.0, 12e-9],
            "parameters": {"delta": 0.0, "time_tol": 1.0, "expr_tol": 100.0},
            "observe_all_analog_solution_times": True,
            "normal_mixed_scheduler": True,
        }
        control_setup = dict(setup, parameters=dict(setup["parameters"], monitor_enabled=0))
        control = self.observe("absdelta_zero_delta", ABSDELTA_SOURCE, control_setup)
        self.assertEqual(control["delivered_events"], [])
        self.assertEqual(control["hdl_event_count"], 0)
        self.assert_solution_trace(control["analog_solution_times"])
        observed = self.observe("absdelta_zero_delta", ABSDELTA_SOURCE, setup)
        self.assertEqual(observed["analog_solution_times"], control["analog_solution_times"])
        self.assert_initial_event(observed)
        events = observed["delivered_events"]
        self.assertEqual(len(events), len(control["analog_solution_times"]),
                         "zero delta delivers each changed endpoint and no interpolated events")
        for event, analog_time in zip(events, control["analog_solution_times"]):
            time = self.number(event["time"], "changed endpoint digital time")
            self.assertAlmostEqual(time, analog_time, delta=0.5e-15)
            self.assertAlmostEqual(self.number(event["voltage"], "changed endpoint voltage"),
                                   time * 1.0e8, delta=1e-12)

    def assert_solution_trace(self, times):
        self.assertIsInstance(times, list)
        self.assertGreaterEqual(len(times), 2)
        for time in times:
            self.number(time, "actual analog solution time")
        self.assertEqual(times[0], 0.0)
        self.assertEqual(times[-1], 12e-9)
        self.assertTrue(all(a < b for a, b in zip(times, times[1:])))

    def test_absdelta_d2a_discards_pending(self):
        observed = self.observe(
            "absdelta_d2a_discards_pending",
            "tests/fixtures/ch08_scheduling/absdelta_d2a_discards_pending.va",
            {"top": "absdelta_d2a_discards_pending", "analysis": "tran",
             "initial_time": 0.0, "lookahead_time": 12e-9,
             "pause_digital_after_initialization": True,
             "observe_pending_events_before_d2a": True},
        )
        trial, pending_ids = self.assert_trial(observed)
        before = observed["pending_before_d2a"]
        self.assertEqual(self.event_ids(before), pending_ids - {observed["pending_before_decision"][0]["id"]})
        self.assertEqual(before, observed["pending_before_decision"][1:])
        self.assertEqual(self.number(observed["d2a_time"], "D2A time"), 4e-9)
        self.assertEqual(observed["rejected_solution_ids"], [trial])
        self.assertEqual(set(observed["discarded_pending_event_ids"]), self.event_ids(before))
        self.assertEqual(observed["pending_after_d2a"], [])
        delivered = observed["delivered_events"]
        self.assertEqual(len(delivered), 1)
        self.assertEqual(self.event_ids(delivered), {observed["pending_before_decision"][0]["id"]})
        self.assert_event_times(delivered, 1)
        self.assertTrue(all("voltage" in event for event in delivered))
        self.assertIn(4e-9, observed["analog_solution_times"], "D2A must cause an analog solution")
        self.assertIs(type(observed["hdl_event_count"]), int)
        self.assertEqual(observed["hdl_event_count"], 2)
        self.assertAlmostEqual(self.number(observed["final_voltage"], "clamped voltage"), 0.4, delta=1e-12)


# ---------------------------------------------------------------------------
# scheduling_observations: mixed-kernel timing.
# ---------------------------------------------------------------------------

CROSS = "tests/fixtures/ch08_scheduling/cross_pending_host_observations.va"


class SchedulingObservations(HostProfileCase):
    """Actual mixed-kernel observations for timing requirements.

    Unavailable instrumentation or an unreachable scenario is a skip;
    substituted expected traces are forbidden.

    cross_pending_rejection pauses before consuming a real pending cross event.
    The analog solver locates the crossing while attempting the requested 6 ns
    endpoint. Return trial_id, trial_time, pending (one event with id, solution_id,
    analog_time and digital_time, all times in seconds), delivered_before_decision,
    rejected_solution_ids, pending_after_rejection for the reject operation, and
    delivered (same fields plus voltage), hdl_event_count, sampled_voltage after
    completion. "accept" consumes that event; "reject" invalidates its solution,
    accepts a clean 4 ns retry, then advances toward 6 ns to produce a new event.

    cross_digital_time_is_monotonic uses the real host interface to establish the
    digital kernel at 6 ns before it consumes the crossing found at about 5.2 ns.
    Return previous_digital_time, current_digital_time_before_enqueue,
    analog_event_time, nearest_tick_time, queued_time, delivered_time and
    hdl_event_count. Only report available if this is a real reachable host state;
    do not inject a fabricated event or bypass the scheduler being tested.

    continuous_variable_interpolation pauses the actual digital read at 15 ns
    while the analog kernel has reached its accepted 18 ns solution. Return
    analog_time_at_read, digital_time_at_read, bracket_times, free_endpoint_values,
    held_endpoint_values, sampled_free and sampled_held. These are actual kernel
    state and HDL read results, not inferred timestamps from a waveform.
    """

    def close(self, value, expected, delta=1e-21):
        self.assertIn(type(value), (int, float))
        self.assertTrue(math.isfinite(value))
        self.assertAlmostEqual(value, expected, delta=delta)

    def pending_cross(self, observed):
        self.assertIsInstance(observed["trial_id"], str)
        self.assertTrue(observed["trial_id"])
        self.close(observed["trial_time"], 5.2e-9, 1e-12)
        self.assertEqual(observed["delivered_before_decision"], [])
        self.assertEqual(len(observed["pending"]), 1)
        event = observed["pending"][0]
        self.assertIsInstance(event["id"], str)
        self.assertTrue(event["id"])
        self.assertEqual(event["solution_id"], observed["trial_id"])
        self.close(event["analog_time"], observed["trial_time"])
        self.close(event["digital_time"], 5e-9)
        return event

    def delivered_cross(self, observed):
        self.assertEqual(len(observed["delivered"]), 1)
        event = observed["delivered"][0]
        self.assertIsInstance(event["id"], str)
        self.assertTrue(event["id"])
        self.assertIsInstance(event["solution_id"], str)
        self.assertTrue(event["solution_id"])
        self.close(event["analog_time"], 5.2e-9, 1e-12)
        self.close(event["digital_time"], 5e-9)
        self.close(event["voltage"], 0.5, 1e-12)
        self.assertIs(type(observed["hdl_event_count"]), int)
        self.assertEqual(observed["hdl_event_count"], 1)
        self.close(observed["sampled_voltage"], 0.5, 1e-12)
        return event

    def test_cross_pending_event_rejected_with_solution(self):
        setup = {"top": "cross_pending_host_observations", "analysis": "tran",
                 "initial_time": 0.0, "requested_endpoint": 6e-9,
                 "pause_before_cross_delivery": True}
        accepted = self.observe("cross_pending_rejection", CROSS, dict(setup, operation="accept"))
        pending = self.pending_cross(accepted)
        delivered = self.delivered_cross(accepted)
        self.assertEqual(accepted["rejected_solution_ids"], [])
        self.assertEqual(delivered["id"], pending["id"])
        self.assertEqual(delivered["solution_id"], pending["solution_id"])
        rejected = self.observe("cross_pending_rejection", CROSS,
                                dict(setup, operation="reject", retry_time=4e-9))
        pending = self.pending_cross(rejected)
        self.assertEqual(rejected["rejected_solution_ids"], [rejected["trial_id"]])
        self.assertEqual(rejected["pending_after_rejection"], [])
        delivered = self.delivered_cross(rejected)
        self.assertNotEqual(delivered["id"], pending["id"])
        self.assertNotEqual(delivered["solution_id"], pending["solution_id"])

    def test_cross_digital_time_never_moves_backwards(self):
        observed = self.observe("cross_digital_time_is_monotonic", CROSS, {
            "top": "cross_pending_host_observations", "analysis": "tran",
            "digital_time_before_enqueue": 6e-9, "analog_crossing": 5.2e-9,
        })
        self.close(observed["previous_digital_time"], 6e-9)
        self.close(observed["current_digital_time_before_enqueue"], 6e-9)
        self.close(observed["analog_event_time"], 5.2e-9, 1e-12)
        self.close(observed["nearest_tick_time"], 5e-9)
        self.close(observed["queued_time"], 6e-9)
        self.close(observed["delivered_time"], 6e-9)
        self.assertIs(type(observed["hdl_event_count"]), int)
        self.assertEqual(observed["hdl_event_count"], 1)

    def test_continuous_variable_interpolates_unless_event_assigned(self):
        observed = self.observe("continuous_variable_interpolation",
            "tests/fixtures/ch08_scheduling/continuous_variable_interpolation_host.va",
            {"top": "continuous_variable_interpolation_host", "analysis": "tran",
             "accepted_analog_times": [0.0, 10e-9, 18e-9],
             "digital_read_time": 15e-9, "observe_kernel_times_at_read": True})
        self.close(observed["analog_time_at_read"], 18e-9)
        self.close(observed["digital_time_at_read"], 15e-9)
        self.assertEqual(observed["bracket_times"], [10e-9, 18e-9])
        self.assertEqual(len(observed["free_endpoint_values"]), 2)
        self.assertEqual(len(observed["held_endpoint_values"]), 2)
        self.close(observed["free_endpoint_values"][0], 1.0, 1e-12)
        self.close(observed["free_endpoint_values"][1], 1.8, 1e-12)
        self.close(observed["held_endpoint_values"][0], 1.0, 1e-12)
        self.close(observed["held_endpoint_values"][1], 1.0, 1e-12)
        self.close(observed["sampled_free"], 1.5, 1e-12)
        self.close(observed["sampled_held"], 1.0, 1e-12)


# ---------------------------------------------------------------------------
# language_semantics_observations: resolved language objects and live solver
# state. The host-only models (no `//!` directive, so the suite never collects
# them) sit in the chapter directories of the clauses they observe.
# ---------------------------------------------------------------------------

LANGUAGE_FIXTURES = "tests/fixtures/ch03_data_types/"
MODELS = {name: f"tests/fixtures/{chapter}/{name}.va" for chapter, names in (
    ("ch03_data_types", ("operator_equation_tolerances", "structural_unknown_domain")),
    ("ch04_expressions", ("transition_resolution", "transition_simulator_default", "slew_small_signal")),
) for name in names}


class LanguageSemanticsObservations(HostProfileCase):
    """Observe resolved semantic bindings, residual tolerances and corner steps.

    Each scenario must query the elaborated language objects or live solver named
    in setup. Returning parsed declarations, requested values, or a reconstructed
    answer is not an observation. Missing semantic/solver/step instrumentation is
    status=unavailable, hence a recorded skip; no adapter also skips.

    resolved_nature_links: observations.links is {nature: {idt_nature,ddt_nature}}.
    discipline_user_attribute: observations.attributes contains actual retained
    attributes of the named elaborated discipline.
    structural_unknown_domain: observations.net is {name,domain,discipline}.
    operator_equation_tolerances: observations.solver contains analysis,converged,
    reltol; equation_count is the actual live residual-equation count. equations
    lists every unique id with tolerance_role="equation_residual", finite positive
    abstol and live gate_checks (zero, half tolerance, twice tolerance, both signs).
    operator_equation_ids maps ddt/idt to nonempty subsets of these live ids.

    transition_corner_resolution: observations.analysis="tran", accepted_times is
    the actual accepted step sequence (no output resampling). filters maps omitted,
    zero and explicit_tol to {effective_time_tol,corners}, where each corner is
    {requested_time,accepted_time,value}; these are live filter breakpoints and
    accepted solution values. The host starts with maxstep100ns and no requested
    sample grid; external source events alone must not supply the delayed corners.
    Effective tolerance is positive and smaller than the 4ns shortest transition;
    each observed corner must be reached within that tolerance. This tests corner
    resolution directly, not waveform equality under a test-supplied time grid.

    transition_simulator_default: observations.default_policy is the host's
    documented policy with documentation,rise_time,fall_time. observations.runs
    contains independent rising/falling transitions from settled0/1 at time0,
    each with duration, initial_value, samples[{time,value}], final_value.
    Samples are actual transient observations at quarter/half/three-quarter
    durations. A documented host default is a prerequisite, not an invented
    universal default duration.
    """

    def number(self, value):
        self.assertIn(type(value), (int, float))
        self.assertTrue(math.isfinite(value))
        return value

    def assert_links(self, source, operator, expected):
        observed = self.observe("resolved_nature_links", LANGUAGE_FIXTURES + source,
                                {"operator": operator, "natures": list(expected),
                                 "observer": "resolved elaborated nature links"})
        for nature, target in expected.items():
            self.assertEqual(observed["links"][nature][operator], target)

    def test_idt_nature_defaults_self_and_related_overrides(self):
        self.assert_links("idt_nature_self_reference.va", "idt_nature",
                          {"ch3_idt_self": "ch3_idt_self",
                           "ch3_idt_self_flow": "ch3_idt_self_flow"})
        self.assert_links("idt_nature_related_overrides.va", "idt_nature",
                          {"b1_volt": "b1_flux", "b1_volt_child": "b1_flux_fine",
                           "b1_amp": "b1_amp", "b1_amp_child": "b1_amp_fine"})

    def test_ddt_nature_defaults_self_and_related_overrides(self):
        self.assert_links("ddt_nature_names_and_overrides.va", "ddt_nature",
                          {"b1_dchg": "b1_dcur", "b1_dself": "b1_dself",
                           "b1_dchg_child": "b1_dcur_fine",
                           "b1_dvolt": "b1_dvolt",
                           "b1_dvolt_child": "b1_dvolt_fine"})

    def test_discipline_retains_its_user_attribute(self):
        observed = self.observe("discipline_user_attribute",
                                LANGUAGE_FIXTURES + "discipline_user_attributes.va",
                                {"discipline": "ch3267_with_attr",
                                 "observer": "elaborated discipline attributes"})
        self.assertEqual(self.number(observed["attributes"]["max_voltage"]), 48.0)

    def test_structural_disciplineless_wire_keeps_unknown_domain(self):
        observed = self.observe("structural_unknown_domain",
                                MODELS["structural_unknown_domain"],
                                {"top": "structural_unknown_domain", "net": "link",
                                 "observer": "final resolved net domain"})
        self.assertEqual(observed["net"],
                         {"name": "link", "domain": "unknown", "discipline": None})

    def test_every_live_operator_equation_has_residual_tolerance(self):
        observed = self.observe("operator_equation_tolerances",
                                MODELS["operator_equation_tolerances"],
                                {"analysis": "tran", "reltol": 0.0,
                                 "input": "V(in)=time in seconds", "stop": 1e-6,
                                 "observe": "all live solver equation residual gates",
                                 "gate_multipliers": [0, 0.5, -0.5, 2, -2]})
        self.assertEqual(observed["solver"]["analysis"], "tran")
        self.assertIs(observed["solver"]["converged"], True)
        self.assertEqual(self.number(observed["solver"]["reltol"]), 0.0)
        rows = observed["equations"]
        self.assertGreater(len(rows), 0)
        self.assertEqual(type(observed["equation_count"]), int)
        self.assertEqual(observed["equation_count"], len(rows))
        ids = [row["id"] for row in rows]
        self.assertEqual(len(ids), len(set(ids)))
        for operator in ("ddt", "idt"):
            selected = observed["operator_equation_ids"][operator]
            self.assertGreater(len(selected), 0)
            self.assertTrue(set(selected) <= set(ids))
        for row in rows:
            self.assertEqual(row["tolerance_role"], "equation_residual")
            tolerance = self.number(row["abstol"])
            self.assertGreater(tolerance, 0.0)
            self.assertEqual(len(row["gate_checks"]), 5)
            for gate, multiplier in zip(row["gate_checks"], (0, .5, -.5, 2, -2)):
                self.assertAlmostEqual(self.number(gate["residual"]),
                                       multiplier * tolerance, delta=tolerance * 1e-6)
                self.assertIs(gate["accepted"], abs(multiplier) <= 1)

    def test_ddt_derivative_and_explicit_output_tolerance(self):
        """Observe actual derivative values and the operator's live output gate."""
        observed = self.observe("ddt_derivative_output_tolerance",
                                MODELS["operator_equation_tolerances"],
                                {"analysis": "tran", "input": "V(in)=time in seconds",
                                 "sample_times": [0.1, 0.5, 1.0],
                                 "maxstep": 1e-4, "reltol": 0.0,
                                 "observe_operator": "ddt(V(in),Rate)",
                                 "gate_output_errors": [0.5e-6, -0.5e-6, 2e-6, -2e-6],
                                 "prerequisite": "live ddt output-error tolerance gate"})
        self.assertEqual(self.number(observed["dc_derivative"]), 0.0)
        self.assertEqual(len(observed["samples"]), 3)
        for row, time in zip(observed["samples"], (.1, .5, 1.0)):
            self.assertAlmostEqual(self.number(row["time"]), time, delta=1e-12)
            self.assertAlmostEqual(self.number(row["derivative"]), 1.0, delta=1e-6)
        gate = observed["operator_gate"]
        self.assertEqual(gate["signal_role"], "output")
        self.assertEqual(self.number(gate["reltol"]), 0.0)
        self.assertAlmostEqual(self.number(gate["abstol"]), 1e-6, delta=1e-18)
        self.assertEqual(len(gate["checks"]), 4)
        for row, error in zip(gate["checks"], (.5e-6, -.5e-6, 2e-6, -2e-6)):
            self.assertAlmostEqual(self.number(row["output_error"]), error, delta=1e-15)
            self.assertIs(row["accepted"], abs(error) < 1e-6)

    def test_slew_small_signal_transfer_in_active_and_settled_states(self):
        """Measure complex transfer, using actual frozen transient states."""
        observed = self.observe("slew_small_signal_transfer",
                                MODELS["slew_small_signal"],
                                {"initial_input": 0.0, "input_edges": [[1e-9, 1.0]],
                                 "state_times": [0.0, 2e-9, 5e-9],
                                 "frequency": 1e6, "ac_input": 1.0,
                                 "prerequisite": "small-signal solve at frozen transient states"})
        rows = observed["states"]
        self.assertEqual(len(rows), 3)
        for row, time, output, gain in zip(rows, (0, 2e-9, 5e-9), (0, .3, 1), (1, 0, 1)):
            self.assertAlmostEqual(self.number(row["time"]), time, delta=1e-21)
            self.assertAlmostEqual(self.number(row["large_signal_output"]), output, delta=1e-6)
            self.assertEqual(self.number(row["frequency"]), 1e6)
            self.assertAlmostEqual(self.number(row["transfer_real"]), gain, delta=1e-12)
            self.assertAlmostEqual(self.number(row["transfer_imag"]), 0, delta=1e-12)

    def test_transition_omitted_and_zero_tolerance_place_corners(self):
        observed = self.observe("transition_corner_resolution",
                                MODELS["transition_resolution"],
                                {"analysis": "tran", "maxstep": 100e-9,
                                 "stop": 25e-9, "requested_output_times": [],
                                 "input_edges": [[1e-9, 1.0], [12e-9, 0.0]],
                                 "initial_input": 0.0,
                                 "observer": "live breakpoints and accepted steps"})
        self.assertEqual(observed["analysis"], "tran")
        times = [self.number(t) for t in observed["accepted_times"]]
        self.assertGreater(len(times), 4)
        self.assertEqual(times, sorted(set(times)))
        for name in ("omitted", "zero", "explicit_tol"):
            filter_observation = observed["filters"][name]
            tolerance = self.number(filter_observation["effective_time_tol"])
            self.assertGreater(tolerance, 0.0)
            self.assertLess(tolerance, 4e-9)
            if name == "explicit_tol":
                self.assertAlmostEqual(tolerance, 1e-12, delta=1e-24)
            corners = filter_observation["corners"]
            self.assertEqual(len(corners), 4)
            for corner, requested, value in zip(corners, (3e-9, 7e-9, 14e-9, 22e-9), (0, 1, 1, 0)):
                self.assertAlmostEqual(self.number(corner["requested_time"]), requested, delta=1e-21)
                accepted = self.number(corner["accepted_time"])
                self.assertIn(accepted, times)
                self.assertAlmostEqual(accepted, requested, delta=tolerance)
                # A corner shifted within time_tol changes value by at most
                # time_tol / shortest ramp duration.
                self.assertAlmostEqual(self.number(corner["value"]), value,
                                       delta=tolerance / 4e-9 + 1e-6)

    def test_transition_without_directive_uses_documented_host_default(self):
        observed = self.observe("transition_simulator_default",
                                MODELS["transition_simulator_default"],
                                {"analysis": "tran", "directions": ["rise", "fall"],
                                 "sample_fractions": [.25, .5, .75],
                                 "prerequisite": "documented finite positive default durations"})
        policy = observed["default_policy"]
        self.assertIsInstance(policy["documentation"], str)
        self.assertTrue(policy["documentation"].strip())
        for direction in ("rise", "fall"):
            duration = self.number(policy[direction + "_time"])
            self.assertGreater(duration, 0.0)
            run = observed["runs"][direction]
            self.assertEqual(self.number(run["duration"]), duration)
            self.assertEqual(self.number(run["initial_value"]), 0 if direction == "rise" else 1)
            self.assertEqual(len(run["samples"]), 3)
            for sample, fraction in zip(run["samples"], (.25, .5, .75)):
                self.assertAlmostEqual(self.number(sample["time"]), fraction * duration,
                                       delta=duration * 1e-9)
                self.assertAlmostEqual(self.number(sample["value"]),
                                       fraction if direction == "rise" else 1 - fraction,
                                       delta=1e-5)
            self.assertAlmostEqual(self.number(run["final_value"]),
                                   1 if direction == "rise" else 0, delta=1e-8)


# ---------------------------------------------------------------------------
# compact_modeling_observations: `__VAMS_COMPACT_MODELING__` against an
# independently observed capability set.
# ---------------------------------------------------------------------------

COMPACT_SOURCE = "tests/fixtures/ch10_directives/compact_modeling_macro.va"

# Each row of Annex G.3 is represented, including all subfeatures in compound
# entries. Related capabilities are reused by repeated change-history
# descriptions. Editorial cross-references and repeated entries are
# accounted for; row 26 is the macro under test and cannot be used as its
# own premise. G.3 has no row 13. The table's "$R" text refers to the %R
# format specifier in Table 9-23.
G3 = {
    1: ("attribute_syntax",),
    2: ("output_variables",),
    3: ("parameter_units", "parameter_descriptions", "localparam",
        "aliasparam", "string_parameters"),
    4: ("net_description_attributes",),
    5: ("bitwise_xnor_operators",),
    6: ("standard_function_domains", "transcendental_function_domains"),
    7: (),  # Editorial access-function examples, no additional construct.
    8: ("symbolic_ddx",),
    9: (),  # Editorial cross-reference to the limiting feature in row24.
    10: ("above_event", "symbolic_ddx", "limit"),
    11: ("dc_sweep_analysis", "dc_sweep_initial_step", "dc_sweep_final_step"),
    12: ("analog_function_output_arguments", "analog_function_inout_arguments"),
    14: ("above_event",),
    15: ("module_description_attributes",),
    16: ("module_item_attributes",),
    17: ("param_given", "port_connected"),
    18: ("mfactor", "xposition", "yposition", "angle", "hflip", "vflip"),
    19: ("paramsets",),
    20: ("simparam",),
    21: ("monte_carlo_random", "monte_carlo_rdist", "random_argument_semantics"),
    22: ("debug_task",),
    23: ("format_r", "format_R"),
    24: ("limit", "discontinuity_minus_one"),
    25: ("table_model",),
    26: (),  # The observed conclusion, not a capability premise.
    27: ("keyword_above", "keyword_aliasparam", "keyword_ddx",
         "keyword_endparamset", "keyword_localparam", "keyword_paramset",
         "keyword_string"),
    28: ("constant_M_TWO_PI", "constant_P_H", "constant_P_K", "constant_P_U0"),
}
FEATURES = tuple(sorted({feature for row in G3.values() for feature in row}))
STATUS = {
    "supported": True, "true": True, "yes": True, "1": True,
    "unsupported": False, "false": False, "no": False, "0": False,
}


def capability_support(report):
    """Read each status from native evidence rather than normalized booleans."""
    if not isinstance(report, dict):
        raise AssertionError("capability report must be an object")
    interface, text, rows = (report.get(key) for key in ("interface", "text", "rows"))
    if not isinstance(interface, str) or not interface.strip():
        raise AssertionError("actual capability introspection interface is required")
    if not isinstance(text, str) or not text.strip() or not isinstance(rows, list):
        raise AssertionError("actual capability export and row spans are required")
    found, occupied = {}, []
    for row in rows:
        if not isinstance(row, dict) or row.get("feature") not in FEATURES:
            raise AssertionError("unknown or malformed capability row")
        feature = row["feature"]
        if feature in found:
            raise AssertionError(f"duplicate capability: {feature}")
        tokens = {}
        for key in ("name_span", "support_span"):
            span = row.get(key)
            if (not isinstance(span, list) or len(span) != 2
                    or any(type(n) is not int for n in span)
                    or not 0 <= span[0] < span[1] <= len(text)):
                raise AssertionError(f"invalid {key} for {feature}")
            start, end = span
            if any(start < old_end and old_start < end for old_start, old_end in occupied):
                raise AssertionError("capability evidence spans must not overlap")
            occupied.append((start, end))
            token = text[start:end]
            if not token.strip():
                raise AssertionError("capability evidence token is empty")
            for boundary in (start - 1, end):
                if 0 <= boundary < len(text) and re.match(r"[\w.-]", text[boundary]):
                    raise AssertionError("capability span selected only part of a token")
            tokens[key] = token
        status = tokens["support_span"].casefold()
        if status not in STATUS:
            raise AssertionError(f"unknown capability status for {feature}: {status!r}")
        found[feature] = STATUS[status]
    if set(found) != set(FEATURES):
        raise AssertionError(f"incomplete capability evidence: {set(FEATURES) - set(found)}")
    return found


class CompactModelingObservations(HostProfileCase):
    """The predefined compact-modeling macro is true iff every extension works.

    The compact_modeling_capabilities scenario runs the supplied macro probe and
    obtains a native capability export for the same host version/configuration.
    It returns:
      probe_completed: true
      probe_stdout: actual simulation stdout
      capability_report: {
        interface: actual introspection command/API name,
        text: unmodified native capability export,
        rows: [{feature, name_span: [start,end], support_span: [start,end]}, ...]
      }

    The adapter maps native names to the requested feature IDs, preserving spans
    in the actual export. Each feature's status must describe its complete
    semantics, not mere parser recognition. Supported/unsupported, true/false,
    yes/no and 1/0 are accepted native status tokens. Partial support is false.
    The export must be independent of the macro value: inferring every feature
    from __VAMS_COMPACT_MODELING__, a version number, or the suite's expected
    results would make this circular. Neither fixture declarations nor a list
    of feature names is capability evidence. Missing complete introspection
    must return unavailable, including an export with unknown feature support.
    No claim that the tested host supports every extension is built into this
    test. A partial host passes precisely when it leaves the macro undefined.
    """

    def test_compact_modeling_macro_matches_complete_capability_set(self):
        observed = self.observe("compact_modeling_capabilities", COMPACT_SOURCE, {
            "top": "compact_modeling_macro",
            "features": list(FEATURES),
            "annex_g3_rows": {str(row): list(features) for row, features in G3.items()},
            "capability_evidence": "independent native host introspection",
            "same_host_configuration_for_probe_and_capabilities": True,
        })
        self.assertIs(observed["probe_completed"], True)
        self.assertIsInstance(observed["probe_stdout"], str)
        macro = re.findall(r"^compact_macro_defined=([01])\r?$",
                           observed["probe_stdout"], flags=re.MULTILINE)
        self.assertEqual(len(macro), 1, "exactly one actual probe verdict is required")
        support = capability_support(observed["capability_report"])
        self.assertEqual(
            macro[0] == "1", all(support.values()),
            f"macro must reflect the full extension set; unsupported: "
            f"{sorted(feature for feature, supported in support.items() if not supported)}",
        )


# The profile runners, by artifact name (`zig build test`).
PROFILES = {
    "report_observations": ReportObservations,
    "indirect_equation_observations": IndirectEquationObservations,
    "conditional_observations": ConditionalObservations,
    "absdelta_rejection_observations": AbsdeltaRejectionObservations,
    "scheduling_observations": SchedulingObservations,
    "language_semantics_observations": LanguageSemanticsObservations,
    "compact_modeling_observations": CompactModelingObservations,
    "directive_documentation": DirectiveDocumentationObservations,
}


# ===========================================================================
# selftest: the oracles fed wrong observations. Synthetic pages and responses
# are never host evidence; these only check that the assertions refuse them.
# ===========================================================================

class ProfileProtocolTests(unittest.TestCase):
    def test_missing_adapter_records_skip_not_pass(self):
        class Case(HostProfileCase):
            def test_observation(self):
                self.observe("missing", __file__, {})
        with patch.object(sys.modules[__name__], "ADAPTER", None):
            result = unittest.TextTestRunner(stream=io.StringIO(), resultclass=EvidenceResult).run(
                unittest.defaultTestLoader.loadTestsFromTestCase(Case)
            )
        self.assertEqual(result.rows, {"profile_observations.test.test_observation": "skip"})

    def test_explicit_unavailability_requires_a_reason(self):
        with self.assertRaises(unittest.SkipTest):
            decode_response(json.dumps({
                "schema_version": 1, "status": "unavailable", "reason": "no finite documented identifier limit",
            }))
        for response in (
            {}, {"schema_version": True, "status": "ok", "observations": {}},
            {"schema_version": 1, "status": "unavailable"},
            {"schema_version": 1, "status": "ok", "observations": "pass"},
            {"schema_version": 1, "status": "pass", "observations": {}},
        ):
            with self.subTest(response=response), self.assertRaises(ValueError):
                decode_response(json.dumps(response))

    def test_broken_adapter_is_a_failure_not_a_capability_skip(self):
        class Case(HostProfileCase):
            def test_observation(self):
                self.observe("broken", __file__, {})
        with patch.object(sys.modules[__name__], "ADAPTER", Path("/adapter")), patch.object(subprocess, "run") as run:
            run.return_value.returncode = 1
            run.return_value.stdout = ""
            run.return_value.stderr = "host crashed"
            result = unittest.TextTestRunner(stream=io.StringIO(), resultclass=EvidenceResult).run(
                unittest.defaultTestLoader.loadTestsFromTestCase(Case)
            )
        self.assertEqual(result.rows, {"profile_observations.test.test_observation": "fail"})

    def test_valid_response_returns_observations_without_awarding_credit(self):
        self.assertEqual(decode_response(json.dumps({
            "schema_version": 1, "status": "ok", "observations": {"value": 999},
        })), {"value": 999})


class ConditionalOracleTests(unittest.TestCase):
    def case(self, name):
        return ConditionalObservations(name)

    def test_length_boundary_is_generated_from_documented_limit(self):
        case = self.case("test_identifier_length_limit")
        lengths = []

        def observe(scenario, source, setup):
            if setup["operation"] == "describe":
                return {"limit": 1024, "documentation": "test host's declared limit", "diagnostic_code": "E0199"}
            text = Path(source).read_text(encoding="utf-8")
            name = text.split("parameter real ", 1)[1].split(" =", 1)[0]
            lengths.append(len(name))
            self.assertEqual(text.count(name), 2)
            return {"exit_code": 0 if len(name) == 1024 else 1, "stdout": "",
                    "stderr": "" if len(name) == 1024 else "error E0199: identifier exceeds declared limit",
                    "diagnostics": [] if len(name) == 1024 else [{"level": "error", "code": "E0199"}]}
        case.observe = observe
        case.test_identifier_length_limit()
        self.assertEqual(lengths, [1024, 1025])

    def test_length_rejection_cannot_be_crash_oom_or_an_unrelated_error(self):
        for status, text in (
            (-9, "E0199"), (0, "E0199"), (1, "E0200"), (1, "E0199 E0200"),
            (1, "E0199 OutOfMemory"),
        ):
            with self.subTest(status=status, text=text), self.assertRaises(AssertionError):
                records = [{"level": "error", "code": code} for code in re.findall(r"E[0-9]{4}", text)]
                compile_result(self, {
                    "exit_code": status, "stdout": "", "stderr": text, "diagnostics": records,
                }, False, "E0199")

    def test_length_diagnostic_quoted_in_a_warning_is_not_an_error(self):
        with self.assertRaises(AssertionError):
            compile_result(self, {
                "exit_code": 1, "stdout": "", "stderr": "warning: E0199 mentioned in source",
                "diagnostics": [{"level": "warning", "code": "E0199"}],
            }, False, "E0199")

    def restore_responses(self):
        return [
            {"trial_values": [41], "iteration_rejected": True, "restore_attempted": True,
             "fatal": False, "retry_values": [41], "simulation_terminated": False, "continued_after_restore": True},
            {"trial_values": [41], "iteration_rejected": True, "restore_attempted": True,
             "backing_position_restorable": False, "buffer_replay_available": False,
             "restore_failed": True, "fatal": True, "retry_values": [],
             "simulation_terminated": True, "continued_after_restore": False,
             "diagnostic": "fatal: cannot restore input position"},
        ]

    def test_irrecoverable_input_oracle_requires_both_the_control_and_real_fault(self):
        case = self.case("test_input_position_restore_failure")
        with patch.object(case, "observe", side_effect=self.restore_responses()):
            case.test_input_position_restore_failure()
        mutations = [
            (0, "retry_values", [73]), (0, "fatal", True), (1, "trial_values", []),
            (1, "iteration_rejected", False), (1, "restore_attempted", False),
            (1, "backing_position_restorable", True), (1, "buffer_replay_available", True),
            (1, "restore_failed", False), (1, "fatal", False), (1, "retry_values", [73]),
            (1, "simulation_terminated", False), (1, "continued_after_restore", True),
            (1, "diagnostic", "fatal: unrelated error"),
        ]
        for index, key, value in mutations:
            data = self.restore_responses()
            data[index][key] = value
            with self.subTest(key=key), patch.object(case, "observe", side_effect=data), self.assertRaises(AssertionError):
                case.test_input_position_restore_failure()

    def test_unknown_driver_oracle_rejects_missing_or_known_drivers(self):
        case = self.case("test_driver_type_unavailable")
        valid = {
            "unavailable_reason": "host opaque foreign driver cannot expose its type",
            "opaque_type_available": False, "opaque_driver_count": 1, "opaque_driver_index": 0,
            "opaque_driver_type": 0, "known_driver_count": 1, "known_type_available": True,
            "known_driver_type": 16, "vpi_errors": [],
        }
        with patch.object(case, "observe", return_value=valid):
            case.test_driver_type_unavailable()
        for key, value in (
            ("opaque_type_available", True), ("opaque_driver_count", 0),
            ("opaque_driver_index", 1), ("opaque_driver_type", 16),
            ("known_driver_type", 0), ("known_type_available", False),
            ("vpi_errors", ["invalid index"]), ("unavailable_reason", ""),
            ("opaque_driver_count", True), ("opaque_driver_index", False), ("known_driver_type", False),
        ):
            with self.subTest(key=key), patch.object(case, "observe", return_value=dict(valid, **{key: value})):
                with self.assertRaises(AssertionError):
                    case.test_driver_type_unavailable()


def report_page(**values):
    text, rows = "", []
    for name, value in values.items():
        ns = len(text)
        text += name
        ne = len(text)
        text += " = "
        vs = len(text)
        text += str(value)
        ve = len(text)
        text += "\n"
        rows.append({"name_span": [ns, ne], "value_span": [vs, ve]})
    return {"text": text, "rows": rows}


def valid_report():
    state = {
        "mfactor": 4, "resistance": 2000, "voltage_pn": 1,
        "current_p_to_n": 0.002, "hidden": 17,
        "multiplied": 3, "divided": 8, "unchanged": 5,
    }
    return {
        "short_report": report_page(resistance=2000, multiplied=12, divided=2, unchanged=5),
        "full_report": report_page(resistance=2000, hidden=17, multiplied=12, divided=2, unchanged=5),
        "parameter_report": report_page(resistance=2000),
        "state_before_reports": state.copy(),
        "state_after_reports": state.copy(),
    }


class ReportOracleTests(unittest.TestCase):
    def case(self, method, output):
        case = ReportObservations(method)
        case.observe = Mock(return_value=output)
        return case

    def check(self, method, output):
        case = self.case(method, output)
        getattr(case, method)()
        return case

    def test_report_positive_oracles(self):
        for method in (
            "test_operating_point_report_hides_values",
            "test_operating_point_report_multiplicity",
            "test_parameter_report_omits_alias",
        ):
            self.check(method, valid_report())

    def test_empty_short_report_cannot_prove_hiding(self):
        observed = valid_report()
        observed["short_report"] = report_page()
        with self.assertRaises(AssertionError):
            self.check("test_operating_point_report_hides_values", observed)

    def test_hidden_text_cannot_be_concealed_by_omitting_its_row_span(self):
        observed = valid_report()
        observed["short_report"]["text"] += "hidden = 17\n"
        with self.assertRaises(AssertionError):
            self.check("test_operating_point_report_hides_values", observed)

    def test_hiding_does_not_require_hidden_in_the_full_report(self):
        observed = valid_report()
        observed["full_report"] = observed["short_report"]
        self.check("test_operating_point_report_hides_values", observed)

    def test_hiding_requires_the_real_hidden_variable_to_survive(self):
        for when in ("state_before_reports", "state_after_reports"):
            observed = valid_report()
            observed[when]["hidden"] = 0
            with self.assertRaises(AssertionError):
                self.check("test_operating_point_report_hides_values", observed)

    def test_each_reported_scaling_value_must_be_correct(self):
        for kind in ("short_report", "full_report"):
            for name, wrong in (("multiplied", 3), ("divided", 8), ("unchanged", 20)):
                with self.subTest(kind=kind, name=name):
                    observed = valid_report()
                    values = report_rows(observed[kind])
                    values[name] = wrong
                    observed[kind] = report_page(**values)
                    with self.assertRaises(AssertionError):
                        self.check("test_operating_point_report_multiplicity", observed)

    def test_reporting_must_not_mutate_internal_values_or_circuit_current(self):
        for when in ("state_before_reports", "state_after_reports"):
            for name, wrong in (("multiplied", 12), ("divided", 2), ("unchanged", 20),
                                ("current_p_to_n", 0.003125), ("mfactor", 1)):
                with self.subTest(when=when, name=name):
                    observed = valid_report()
                    observed[when][name] = wrong
                    with self.assertRaises(AssertionError):
                        self.check("test_operating_point_report_multiplicity", observed)

    def test_parameter_alias_must_not_replace_or_duplicate_original(self):
        for page in (report_page(resistance_alias=2000),
                     report_page(resistance=2000, resistance_alias=2000),
                     report_page(resistance=1000)):
            observed = valid_report()
            observed["parameter_report"] = page
            with self.assertRaises(AssertionError):
                self.check("test_parameter_report_omits_alias", observed)

    def test_alias_text_cannot_be_concealed_by_omitting_its_row_span(self):
        observed = valid_report()
        observed["parameter_report"]["text"] += "resistance_alias = 2000\n"
        with self.assertRaises(AssertionError):
            self.check("test_parameter_report_omits_alias", observed)

    def test_duplicate_original_cannot_be_concealed_by_omitting_its_span(self):
        observed = valid_report()
        observed["parameter_report"]["text"] += "resistance = 2000\n"
        with self.assertRaises(AssertionError):
            self.check("test_parameter_report_omits_alias", observed)

    def test_module_and_paramset_help_are_requested_independently(self):
        for method, model, text in (
            ("test_module_help_description", "help_base", "Base resistor help"),
            ("test_paramset_help_description", "help_model", "Paramset resistor help"),
        ):
            case = self.check(method, {"help_text": text})
            case.observe.assert_called_once_with("model_help", HELP_SOURCE, {"model": model})

    def test_base_help_cannot_satisfy_paramset_help(self):
        with self.assertRaises(AssertionError):
            self.check("test_paramset_help_description", {"help_text": "Base resistor help"})
        with self.assertRaises(AssertionError):
            self.check("test_module_help_description", {"help_text": "Paramset resistor help"})

    def test_output_values_are_observed_in_the_host_report(self):
        observed = {"output_variable_report": report_page(cgs=4.21e-15, cdb=3e-15, ids=7)}
        self.check("test_module_output_variable_values_are_accessible", observed)
        self.check("test_block_variable_attributes_are_ignored", observed)
        for name in ("cgs", "cdb", "ids"):
            values = {"cgs": 4.21e-15, "cdb": 3e-15, "ids": 7}
            values[name] = 0
            with self.assertRaises(AssertionError):
                self.check("test_module_output_variable_values_are_accessible",
                           {"output_variable_report": report_page(**values)})

    def test_block_attributes_cannot_export_a_local_variable(self):
        observed = {"output_variable_report": report_page(cgs=4.21e-15, lv=0.5)}
        with self.assertRaises(AssertionError):
            self.check("test_block_variable_attributes_are_ignored", observed)
        observed = {"output_variable_report": report_page(cgs=4.21e-15)}
        observed["output_variable_report"]["text"] += "block local\n"
        with self.assertRaises(AssertionError):
            self.check("test_block_variable_attributes_are_ignored", observed)

    def test_raw_report_must_contain_the_asserted_values(self):
        page = report_page(multiplied="1.2D+1")
        self.assertEqual(report_rows(page), {"multiplied": 12})
        # A separate expected-value field is irrelevant to the raw text.
        page["rows"][0]["value"] = 12
        page["text"] = page["text"].replace("1.2D+1", "1.2D+2")
        self.assertEqual(report_rows(page), {"multiplied": 120})

    def test_qualified_names_and_system_parameters_remain_host_tokens(self):
        page = report_page(**{"dut.resistance": 2000, "dut.$mfactor": 4})
        self.assertEqual(report_rows(page), {"resistance": 2000, "$mfactor": 4})

    def test_spans_cannot_select_a_substring_or_another_rows_value(self):
        for page, key, changed in (
            (report_page(resistance_alias=2000), "name_span", [0, 10]),
            (report_page(multiplied=120), "value_span", [13, 15]),
            (report_page(multiplied=0, hidden=12), "value_span", [24, 26]),
        ):
            page["rows"][0][key] = changed
            with self.assertRaises(AssertionError):
                report_rows(page)

    def test_invalid_rows_and_nonfinite_numbers_are_refused(self):
        base = report_page(multiplied=12)
        for invalid in (None, [], ["0", 1], [True, 1], [-1, 5], [0, 999], [2, 1]):
            page = copy.deepcopy(base)
            page["rows"][0]["name_span"] = invalid
            with self.assertRaises(AssertionError):
                report_rows(page)
        for number in ("NaN", "Inf", "1e999"):
            with self.assertRaises(AssertionError):
                report_rows(report_page(multiplied=number))

    def test_duplicate_rows_are_refused(self):
        first = report_page(resistance=2000)
        second = report_page(resistance=2000)
        offset = len(first["text"])
        for row in second["rows"]:
            for key in ("name_span", "value_span"):
                row[key] = [value + offset for value in row[key]]
        first["text"] += second["text"]
        first["rows"] += second["rows"]
        with self.assertRaises(AssertionError):
            report_rows(first)


def valid_indirect():
    """A synthetic adapter response used only to test the assertion itself."""
    return {
        "solver": {"analysis": "op", "converged": True, "reltol": 0.0},
        "solution": {"V(sense)": 1.0, "V(drive)": 2.0},
        "equations": [{
            "branch": "control",
            "lhs": "V(sense)",
            "tolerance_role": "equation_residual",
            "residual_abstol": 1e-9,
            "gate_checks": [{
                "lhs_value": 1.0 + residual,
                "residual": (1.0 + residual) - 1.0,
                "accepted": abs(residual) < 1e-9,
            } for residual in TRIAL_RESIDUALS],
        }],
    }


class IndirectEquationOracleTests(unittest.TestCase):
    """Check that the host assertion rejects plausible but incorrect evidence."""

    def check_response(self, response):
        case = IndirectEquationObservations("test_indirect_equation_lhs_tolerance")
        case.observe = lambda scenario, source, setup: response
        result = unittest.TestResult()
        case.run(result)
        return result

    def assert_rejected(self, response):
        result = self.check_response(response)
        self.assertEqual(result.testsRun, 1)
        self.assertFalse(result.wasSuccessful())
        self.assertEqual(result.skipped, [])
        self.assertEqual(result.expectedFailures, [])

    def test_complete_residual_observation_is_accepted(self):
        self.assertTrue(self.check_response(valid_indirect()).wasSuccessful())

    def test_control_branch_and_current_unknown_tolerances_are_rejected(self):
        for tolerance in (1e-6, 1e-12):
            response = valid_indirect()
            response["equations"][0]["residual_abstol"] = tolerance
            self.assert_rejected(response)

    def test_unknown_metadata_with_the_right_number_is_still_rejected(self):
        response = valid_indirect()
        response["equations"][0]["tolerance_role"] = "unknown_update"
        self.assert_rejected(response)

    def test_correct_metadata_does_not_mask_a_wrong_live_gate(self):
        # A host using the loose controlling-branch voltage tolerance could
        # publish the right lhs metadata but accept these oversized residuals.
        response = valid_indirect()
        for check in response["equations"][0]["gate_checks"]:
            check["accepted"] = True
        self.assert_rejected(response)

    def test_current_unknown_gate_rejecting_small_residuals_is_rejected(self):
        response = valid_indirect()
        for check in response["equations"][0]["gate_checks"]:
            check["accepted"] = False
        self.assert_rejected(response)

    def test_one_sided_signed_gate_cannot_pass_negative_probe(self):
        response = valid_indirect()
        response["equations"][0]["gate_checks"][-1]["accepted"] = True
        self.assert_rejected(response)

    def test_final_solution_and_unknown_metadata_cannot_replace_equation_observation(self):
        response = valid_indirect()
        response["u_abstol"] = {"sense": 1e-9}
        del response["equations"]
        self.assert_rejected(response)

    def test_solver_must_have_converged_at_the_actual_circuit_solution(self):
        response = valid_indirect()
        response["solver"]["converged"] = False
        self.assert_rejected(response)
        response = valid_indirect()
        response["solution"]["V(drive)"] = 1.0
        self.assert_rejected(response)

    def test_duplicate_equations_and_nonfinite_values_are_rejected(self):
        response = valid_indirect()
        response["equations"].append(copy.deepcopy(response["equations"][0]))
        self.assert_rejected(response)
        for value in (float("nan"), float("inf"), True):
            response = valid_indirect()
            response["equations"][0]["residual_abstol"] = value
            self.assert_rejected(response)


def process(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(["vera"], returncode, stdout, stderr)


def diagnostic(code, level="error", **extra):
    return json.dumps({"code": code, "level": level, **extra}) + "\n"


class PairedCompilerOracleTests(unittest.TestCase):
    """Adversarial checks for the paired compiler evidence oracle; no VerA needed."""

    def test_named_error_may_repeat_without_an_unrelated_error(self):
        assert_exclusive_refusal(
            process(1, stderr=diagnostic("E0337") * 2 + diagnostic("W0601", "warning")),
            "E0337",
        )

    def test_quoted_expected_code_is_not_the_diagnostic_code(self):
        result = process(1, stderr=diagnostic("E0240", message="source says reject-only E0337"))
        with self.assertRaises(AssertionError):
            assert_exclusive_refusal(result, "E0337")

    def test_second_error_or_warning_only_cannot_satisfy_refusal(self):
        for stderr in (
            diagnostic("E0337") + diagnostic("E0240"),
            diagnostic("E0337", "warning"),
            "",
            "error[E0337]: text diagnostics were not requested\n",
        ):
            with self.subTest(stderr=stderr), self.assertRaises(AssertionError):
                assert_exclusive_refusal(process(1, stderr=stderr), "E0337")

    def test_acceptance_usage_error_and_crash_are_not_refusals(self):
        for status in (0, 2, -11):
            with self.subTest(status=status), self.assertRaises(AssertionError):
                assert_exclusive_refusal(process(status, stderr=diagnostic("E0361")), "E0361")

    def test_complete_numeric_control_accepts_both_streams(self):
        assert_numeric_control(
            process(stdout="=== top ===\nfirst got=2 want=2 ok=1\n",
                    stderr="second got=0.25 want=2.5e-1 ok=1\n"),
            {"first": (2.0, 0.0), "second": (0.25, 0.0)},
        )

    def test_successful_exit_with_missing_or_wrong_checks_is_no_evidence(self):
        for stdout in (
            "",
            "selected got=1 want=2 ok=1\n",
            "selected got=2 want=1 ok=1\n",
            "selected got=2 want=2 ok=0\n",
            "selected got=2 want=2 ok=10\n",
            "selected got=nan want=2 ok=1\n",
            "selected got=2 want=nan ok=1\n",
            "selected got=2 want=2 ok=1\n" * 2,
            "other got=2 want=2 ok=1\n",
            "selected got=2 want=2 ok=1\nextra got=2 want=2 ok=1\n",
            "selected got=2 want=2 ok=1\nFAIL: solver failed\n",
            "selected got=2 want=2 ok=1\nerror[E0337]: no discipline\n",
        ):
            with self.subTest(stdout=stdout), self.assertRaises(AssertionError):
                assert_numeric_control(process(stdout=stdout), {"selected": (2.0, 0.0)})

    def test_positive_control_compile_failure_is_not_hidden_by_checks(self):
        with self.assertRaises(AssertionError):
            assert_numeric_control(
                process(1, stdout="selected got=2 want=2 ok=1\n"), {"selected": (2.0, 0.0)}
            )

    def test_missing_executable_and_assertion_failure_record_failure(self):
        class Cases(unittest.TestCase):
            def test_missing_executable(self):
                raise FileNotFoundError("vera")

            def test_wrong_selection(self):
                self.fail("wrong member selected")

            def test_success(self):
                pass

        result = unittest.TextTestRunner(
            stream=io.StringIO(), resultclass=evidence_result("paired_compiler_observations")
        ).run(unittest.defaultTestLoader.loadTestsFromTestCase(Cases))
        self.assertFalse(result.wasSuccessful())
        self.assertEqual(result.rows, {
            "paired_compiler_observations.test.test_missing_executable": "fail",
            "paired_compiler_observations.test.test_wrong_selection": "fail",
            "paired_compiler_observations.test.test_success": "pass",
        })


class DiagnosticOracleTests(unittest.TestCase):
    def test_runner_time_labels_cannot_satisfy_task_time_requirement(self):
        output = "=== m ===\n--- point 1 ---\n  t = 2.000000e-9  dt = 2.000000e-9\nINFO: observe-info\n"
        self.assertEqual(diagnostic_text(output), "INFO: observe-info")

    def test_actual_task_diagnostics_are_retained(self):
        output = "=== m ===\n--- point 1 ---\n$finish: t=0.000000002 (m)\n"
        self.assertEqual(diagnostic_text(output), "$finish: t=0.000000002 (m)")

    def test_setup_failures_are_not_expected_failures_and_xpass_fails(self):
        class Cases(unittest.TestCase):
            def setUp(self):
                if self._testMethodName == "test_setup":
                    self.fail("compiler failed before the observation")

            @unittest.expectedFailure
            def test_setup(self):
                self.fail("must not reach this")

            @unittest.expectedFailure
            def test_xpass(self):
                pass

        result = unittest.TextTestRunner(stream=io.StringIO(), resultclass=EvidenceResult).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(Cases)
        )
        self.assertFalse(result.wasSuccessful())
        self.assertEqual(list(result.rows.values()), ["fail", "fail"])
        self.assertEqual(result.expectedFailures, [])


class DirectiveDocumentationOracleTests(unittest.TestCase):
    def test_only_published_language_manual_chapters_are_searched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "SUMMARY.md").write_text(
                "# Learn Verilog-AMS\n- [Language](language.md)\n"
                "# Developer notes\n- [Implementation](developer.md)\n"
                "# Using VerA\n- [Usage](usage.md)\n"
                "# Language appendices\n- [Preprocessor](preprocessor.md)\n"
            )
            for name in ("language.md", "developer.md", "usage.md", "unpublished.md", "preprocessor.md"):
                (root / name).write_text("text")
            self.assertEqual(
                {p.name for p in language_manual_pages(root)},
                {"language.md", "usage.md", "preprocessor.md"},
            )

    def test_macro_requires_an_explanation_in_prose(self):
        self.assertTrue(documents_tool_macro(
            "VerA provides the predefined macro `__VERA__` for simulator-specific source."
        ))
        self.assertTrue(documents_tool_macro(
            "`__VERA__` is defined by the compiler for conditional compilation."
        ))
        self.assertTrue(documents_tool_macro(
            "# Built-in macros of VerA\n\n`__VERA__` identifies this compiler."
        ))
        for text in (
            "The model contains __VERA__.",
            "```\n// The predefined macro __VERA__ identifies VerA\n```",
            "VerA provides a predefined macro.\n\nUnrelated output: __VERA__",
        ):
            with self.subTest(text=text):
                self.assertFalse(documents_tool_macro(text))


def compact_observation(macro, unsupported=()):
    text, rows = "", []
    for feature in FEATURES:
        start = len(text)
        text += feature
        end = len(text)
        text += ": "
        status_start = len(text)
        text += "unsupported" if feature in unsupported else "supported"
        status_end = len(text)
        text += "\n"
        rows.append({"feature": feature, "name_span": [start, end],
                     "support_span": [status_start, status_end]})
    return {"probe_completed": True, "probe_stdout": f"compact_macro_defined={int(macro)}\n",
            "capability_report": {"interface": "synthetic-oracle-only", "text": text, "rows": rows}}


class CompactOracleTests(unittest.TestCase):
    def check(self, observed):
        name = "test_compact_modeling_macro_matches_complete_capability_set"
        case = CompactModelingObservations(name)
        case.observe = Mock(return_value=observed)
        getattr(case, name)()

    def test_both_valid_directions(self):
        self.check(compact_observation(True))
        self.check(compact_observation(False, ("symbolic_ddx",)))

    def test_missing_macro_with_complete_support_fails(self):
        with self.assertRaises(AssertionError):
            self.check(compact_observation(False))

    def test_each_unsupported_feature_invalidates_defined_macro(self):
        for feature in FEATURES:
            with self.subTest(feature=feature), self.assertRaises(AssertionError):
                self.check(compact_observation(True, (feature,)))

    def test_missing_capability_evidence_fails(self):
        observed = compact_observation(True)
        observed["capability_report"]["rows"].pop()
        with self.assertRaises(AssertionError):
            self.check(observed)

    def test_selecting_supported_inside_unsupported_fails(self):
        observed = compact_observation(False, ("symbolic_ddx",))
        row = next(row for row in observed["capability_report"]["rows"]
                   if row["feature"] == "symbolic_ddx")
        row["support_span"][0] += 2
        with self.assertRaises(AssertionError):
            self.check(observed)

    def test_source_echo_cannot_supply_probe_result(self):
        observed = compact_observation(True)
        observed["probe_stdout"] = '$display("compact_macro_defined=1");\n'
        with self.assertRaises(AssertionError):
            self.check(observed)

    def test_duplicate_probe_or_capability_fails(self):
        observed = compact_observation(True)
        observed["probe_stdout"] *= 2
        with self.assertRaises(AssertionError):
            self.check(observed)
        observed = compact_observation(True)
        observed["capability_report"]["rows"].append(observed["capability_report"]["rows"][0])
        with self.assertRaises(AssertionError):
            self.check(observed)


SELFTESTS = (ProfileProtocolTests, ConditionalOracleTests, ReportOracleTests, IndirectEquationOracleTests,
             PairedCompilerOracleTests, DiagnosticOracleTests, DirectiveDocumentationOracleTests, CompactOracleTests)


def selftest(argv):
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(c) for c in SELFTESTS)
    result = unittest.TextTestRunner(verbosity=2 if "-v" in argv else 1).run(suite)
    return int(not result.wasSuccessful())


def main(argv):
    name, rest = (argv[0] if argv else ""), argv[1:]
    if name == "selftest":
        return selftest(rest)
    if name == "diagnostic_observations":
        return run_vera_cases(DiagnosticObservations, name, rest)
    if name == "paired_compiler_observations":
        return run_vera_cases(PairedCompilerObservations, name, rest)
    if name in PROFILES:
        return run_cases(PROFILES[name], name, rest)
    runners = ", ".join(["diagnostic_observations", "paired_compiler_observations", *PROFILES, "selftest"])
    print(f"usage: host.py <runner> [options]\nrunners: {runners}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
