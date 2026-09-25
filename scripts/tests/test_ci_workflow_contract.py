"""Contract tests: the hosted workflow must invoke the tooling CLIs correctly.

These tests pin the workflow/script interface so it cannot silently diverge
again (e.g. passing observation files positionally when the script requires
--observations).

CI v3 shape (docs/CI.md): GitHub-hosted CI is a broad SMOKE gate - it compiles
everything, runs the cheap Linux validation, and runs the curated smoke
selection from scripts/smoke-suite.json (validated against the discovered
inventory). The exhaustive suites, the timing/performance/dormancy families and
all repeat/recovery policy belong to the Mac local gate
(scripts/local-ci-gate.sh), so the workflow must contain NO lane matrix, NO
timing-history job and NO native flake retry that would re-run a genuine
assertion until it agrees.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

from _util import SCRIPTS_DIR

REPO_ROOT = os.path.dirname(SCRIPTS_DIR)
WORKFLOW = os.path.join(REPO_ROOT, ".github", "workflows", "ci.yml")
SMOKE_SUITE = os.path.join(SCRIPTS_DIR, "smoke-suite.json")


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        if not os.path.exists(WORKFLOW):
            self.skipTest("ci.yml not present")

    def _workflow_text(self):
        with open(WORKFLOW, encoding="utf-8") as fh:
            return fh.read()

    def test_ci_gate_job_present_and_required_shape(self):
        text = self._workflow_text()
        self.assertIn("CI Gate", text)
        self.assertNotIn("Build & Test", text)

    def _job_text(self, job_key):
        """Extract one job's text block (stdlib-only YAML slicing). Job keys
        sit at exactly two spaces of indentation; their bodies are deeper."""
        lines = self._workflow_text().splitlines()
        start = None
        for i, line in enumerate(lines):
            if line.startswith("  ") and line.strip() == "{0}:".format(job_key):
                start = i
                break
        if start is None:
            self.fail("job {0!r} not found in ci.yml".format(job_key))
        out = [lines[start]]
        for line in lines[start + 1:]:
            if line.startswith("  ") and line[2:3] not in ("", " ", "\t"):
                break  # next sibling job key
            out.append(line)
        return "\n".join(out)

    # --- the smoke selection is the workflow's only test-to-run mapping -----

    def test_plan_job_selects_the_smoke_suite(self):
        plan = self._job_text("plan")
        self.assertIn("plan-tests.py smoke", plan,
                      "the plan job owns the smoke selection")
        self.assertIn("--suite scripts/smoke-suite.json", plan)
        self.assertIn("unit-csv", plan)
        self.assertIn("ui-csv", plan)
        self.assertIn("smoke-summary.py", plan,
                      "the run summary must state the hosted/delegated split")

    def test_unit_smoke_job_runs_the_curated_classes(self):
        unit = self._job_text("unit-smoke")
        self.assertIn("needs: [plan, build]", unit,
                      "the smoke job must consume the SHARED build products")
        self.assertIn("name: build-products", unit,
                      "test-without-building needs the uploaded products")
        self.assertIn('UNIT_CLASSES: "${{ needs.plan.outputs.unit-csv }}"', unit)
        self.assertIn("-only-testing:ConduitTests/", unit)
        # A genuine assertion must FAIL the run: no Xcode-native retry, and no
        # job-level retry either - the unit classes are deterministic.
        self.assertNotIn("-test-iterations", unit)
        self.assertNotIn("-retry-tests-on-failure", unit)
        self.assertNotIn("targeted retry", unit)

    def test_the_build_job_does_not_serialize_behind_the_plan_job(self):
        """Wall clock is a budget the gate spends on every PR.

        The build job compiles the tree and audits the .xctestrun; it consumes
        NOTHING the plan job produces, and making it wait put a serial 1m45s in
        front of every run. The verdict is still gated on the plan job -
        `ci-gate` requires it and both smoke jobs require both - so a broken
        selection still cannot produce a green gate.
        """
        build = self._job_text("build")
        for line in build.splitlines():
            self.assertFalse(line.lstrip().startswith("needs:"),
                             "the build job must not wait for the plan job")
        plan = self._job_text("plan")
        self.assertIn("plan-tests.py smoke", plan,
                      "the plan job still owns the smoke selection")
        for job in ("unit-smoke", "ui-smoke"):
            self.assertIn("needs: [plan, build]", self._job_text(job),
                          "{0} must still need the selection AND the products"
                          .format(job))

    def test_ui_smoke_job_runs_the_curated_classes(self):
        ui = self._job_text("ui-smoke")
        self.assertIn("needs: [plan, build]", ui)
        self.assertIn("name: build-products", ui)
        self.assertIn('UI_CLASSES: "${{ needs.plan.outputs.ui-csv }}"', ui)
        self.assertIn("-only-testing:ConduitUITests/", ui)
        # Both jobs must fail on a genuine assertion rather than retry it with
        # Xcode's own flags; the UI job additionally carries the lane runner's
        # single targeted retry, which reports the flake it absorbs.
        self.assertNotIn("-test-iterations", ui)
        self.assertNotIn("-retry-tests-on-failure", ui)
        self.assertIn("one targeted retry", ui,
                      "UI smoke absorbs exactly one runner-level flake, visibly")

    def test_smoke_jobs_fail_closed_on_an_empty_selection(self):
        # With no -only-testing filter, xcodebuild runs the WHOLE suite, so an
        # emptied selection must stop the job instead of silently turning the
        # smoke gate into the exhaustive one.
        for job in ("unit-smoke", "ui-smoke"):
            self.assertIn("refusing to run unfiltered", self._job_text(job),
                          f"{job} must refuse an empty selection")

    def test_unit_smoke_runs_in_bounded_sequential_batches(self):
        # Large single invocations repeatedly watchdog-stalled on hosted
        # macos-26 (docs/CI.md, "Sequential unit batches").
        self.assertIn("SMOKE_BATCH_SIZE", self._job_text("unit-smoke"))

    def test_smoke_jobs_pin_the_simulator_destination(self):
        # A name-only destination lets xcodebuild pick the first of several
        # devices with that name, and a fresh runner can reach the test step
        # before CoreSimulator has settled its device pairs - the repo's shared
        # ci-lib.sh helpers exist for exactly that, and the build job uses them.
        for job in ("unit-smoke", "ui-smoke"):
            text = self._job_text(job)
            self.assertIn("source scripts/ci-lib.sh", text, job)
            self.assertIn("wait_for_destination_device", text, job)
            self.assertIn("build_destination", text, job)
            self.assertIn("reset_and_boot_simulator", text, job)
            self.assertIn("LOG_DIR=", text,
                          f"{job} must ASSIGN ci-lib.sh's LOG_DIR before probing")
            self.assertIn("export LOG_DIR", text, f"{job} must export LOG_DIR")
            self.assertIn('-destination "$DESTINATION"', text, job)
            self.assertNotIn("platform=iOS Simulator,name=", text,
                             f"{job} must not hand xcodebuild an unpinned destination")

    def test_no_write_only_build_metadata_artifact(self):
        self.assertNotIn("name: build-meta", self._workflow_text(),
                         "nothing consumes build-meta once the report job is gone")

    def test_no_lane_matrix_or_timing_history_machinery_remains(self):
        text = self._workflow_text()
        self.assertNotIn("fromJSON(needs.plan.outputs.matrix)", text)
        self.assertNotIn("fromJSON(needs.plan.outputs.ui-matrix)", text)
        self.assertNotIn("actions/cache/restore", text,
                         "the timing-history cache is gone with its job")
        for obsolete in ("unit:", "ui:", "report:", "timing-history-update:"):
            self.assertFalse(
                any(line.startswith("  ") and line.strip() == obsolete
                    for line in text.splitlines()),
                f"obsolete job {obsolete!r} still present in ci.yml")

    def test_ci_gate_script_verdict_matches_spec_examples(self):
        spec = {
            ("success", "success", "success", "success", "success"): True,
            # No hosted job is ever legitimately skipped: the plan job fails
            # closed on an empty curated selection, so a skipped smoke job is
            # always an upstream failure cascade - and fails the gate.
            ("success", "success", "success", "skipped", "success"): False,
            ("success", "success", "failure", "success", "success"): False,
            ("success", "success", "success", "failure", "success"): False,
            ("success", "success", "timed_out", "success", "success"): False,
            ("success", "success", "success", "timed_out", "success"): False,
            ("success", "success", "success", "success", "failure"): False,
            ("success", "failure", "skipped", "skipped", "skipped"): False,
            ("cancelled", "success", "success", "success", "success"): False,
            ("success", "success", "cancelled", "success", "success"): False,
        }
        for (plan, build, unit, ui, self_test), expected in spec.items():
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "ci-gate.py"),
                 "--plan", plan, "--build", build,
                 "--unit-smoke", unit, "--ui-smoke", ui,
                 "--self-test", self_test],
                capture_output=True, text=True)
            self.assertEqual(
                proc.returncode == 0, expected,
                f"gate({plan},{build},{unit},{ui},{self_test}) -> {proc.stdout}")

    def test_ci_gate_documents_the_mac_gate_it_does_not_replace(self):
        with open(os.path.join(SCRIPTS_DIR, "ci-gate.py"), encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("Mac local exhaustive gate", text,
                      "the verdict must say the hosted gate is not the "
                      "exhaustive one")


class SmokeSelectionTests(unittest.TestCase):
    """The hosted suite selection is a checked-in list, so its integrity is a
    contract: every class must exist, and the split must be visible."""

    def _run_smoke(self, suite_path, out_path=None):
        args = [sys.executable, os.path.join(SCRIPTS_DIR, "plan-tests.py"),
                "smoke", "--repo-root", REPO_ROOT, "--suite", suite_path]
        if out_path:
            args += ["--out", out_path]
        return subprocess.run(args, capture_output=True, text=True)

    def test_shipped_smoke_suite_validates_against_the_inventory(self):
        self.assertTrue(os.path.exists(SMOKE_SUITE), "smoke-suite.json missing")
        proc = self._run_smoke(SMOKE_SUITE)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("smoke selection OK", proc.stdout)
        self.assertIn("delegated to the Mac local gate", proc.stdout)

    def test_shipped_smoke_suite_never_names_a_mac_gate_family(self):
        with open(SMOKE_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        # The families the Mac exhaustive gate owns (docs/CI.md): hosting them
        # in the smoke gate would re-litigate timing-sensitive suites on a
        # shared runner.
        mac_gate_families = {
            "TranscriptPerformanceFixtureTests",
            "TranscriptPerfLedgerContractTests",
            "LongContextScalingFixtureTests",
            "SettledMessageIsolationTests",
            "MarkdownRichContentHostedTests",
        }
        self.assertFalse(
            mac_gate_families & set(suite.get("unit") or []),
            "a Mac-gate-owned timing family must not be in the hosted smoke set")
        self.assertFalse(mac_gate_families & set(suite.get("ui") or []))

    def test_a_nonexistent_class_fails_the_selection(self):
        with open(SMOKE_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        suite["unit"] = list(suite["unit"]) + ["NoSuchTestsHere"]
        with tempfile.TemporaryDirectory() as tmp:
            bogus = os.path.join(tmp, "suite.json")
            with open(bogus, "w", encoding="utf-8") as fh:
                json.dump(suite, fh)
            proc = self._run_smoke(bogus)
        self.assertNotEqual(proc.returncode, 0,
                            "a renamed/deleted class must fail the plan job")
        self.assertIn("NoSuchTestsHere", proc.stdout)

    def test_a_duplicated_class_fails_the_selection(self):
        with open(SMOKE_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        suite["unit"] = list(suite["unit"]) + [suite["unit"][0]]
        with tempfile.TemporaryDirectory() as tmp:
            bogus = os.path.join(tmp, "suite.json")
            with open(bogus, "w", encoding="utf-8") as fh:
                json.dump(suite, fh)
            proc = self._run_smoke(bogus)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("twice", proc.stdout)

    def _run_smoke_with(self, mutate):
        """Run `smoke` against a copy of the shipped suite after `mutate`."""
        with open(SMOKE_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        mutate(suite)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "suite.json")
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(suite, fh)
            return self._run_smoke(path)

    def test_a_class_in_the_wrong_target_fails_the_selection(self):
        # Validating against the union of both inventories would let a class
        # moved between ConduitTests/ and ConduitUITests/ through, and the smoke
        # job would then filter it against the wrong bundle - running zero tests
        # for it while the plan job reported success.
        def mutate(suite):
            suite["unit"] = list(suite["unit"]) + ["ConnectionSetupUITests"]

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("it is not a unit test class", proc.stdout)

    def test_a_missing_target_key_fails_the_selection(self):
        def mutate(suite):
            suite.pop("ui")

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("must declare", proc.stdout)

    def test_an_empty_target_list_fails_the_selection(self):
        def mutate(suite):
            suite["ui"] = []

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)

    def test_a_non_class_name_entry_fails_the_selection(self):
        def mutate(suite):
            suite["unit"] = list(suite["unit"]) + ["Not A Class"]

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)

    def test_a_failing_selection_writes_no_output_file(self):
        # The plan job's `jq -r '.unit_csv' smoke.json` must never read a stale
        # or partially written selection: a failed validation writes nothing.
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "smoke.json")
            with open(SMOKE_SUITE, encoding="utf-8") as fh:
                suite = json.load(fh)
            suite.pop("ui")
            bogus = os.path.join(tmp, "suite.json")
            with open(bogus, "w", encoding="utf-8") as fh:
                json.dump(suite, fh)
            proc = self._run_smoke(bogus, out_path=out)
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse(os.path.exists(out),
                             "a failed selection must not leave a selection file")

    def test_selection_output_feeds_the_smoke_jobs(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "smoke.json")
            proc = self._run_smoke(SMOKE_SUITE, out_path=out)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            with open(out, encoding="utf-8") as fh:
                doc = json.load(fh)
            self.assertTrue(doc["unit_csv"])
            self.assertEqual(doc["unit_csv"].split(","), doc["unit"])
            self.assertEqual(doc["ui_csv"].split(","), doc["ui"])
            self.assertEqual(doc["delegated_unit"] + len(doc["unit"]),
                             doc["inventory_unit"])
            summary = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "smoke-summary.py"),
                 "--selection", out],
                capture_output=True, text=True)
        self.assertEqual(summary.returncode, 0, summary.stderr)
        self.assertIn("Hosted smoke gate", summary.stdout)
        self.assertIn("Mac local gate", summary.stdout)

    def test_smoke_summary_rejects_an_empty_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            empty = os.path.join(tmp, "empty.json")
            with open(empty, "w", encoding="utf-8") as fh:
                json.dump({"unit": [], "ui": [], "inventory_unit": 3,
                           "inventory_ui": 0}, fh)
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "smoke-summary.py"),
                 "--selection", empty],
                capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0,
                            "a smoke gate with no unit classes must not pass "
                            "silently")

    def test_smoke_summary_rejects_an_empty_ui_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            doc = os.path.join(tmp, "no-ui.json")
            with open(doc, "w", encoding="utf-8") as fh:
                json.dump({"unit": ["SomeExistingTests"], "ui": [],
                           "inventory_unit": 3, "inventory_ui": 0}, fh)
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "smoke-summary.py"),
                 "--selection", doc],
                capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0,
                            "a smoke gate with no UI classes must not pass "
                            "silently")

    def test_smoke_summary_tolerates_absent_counts(self):
        # Hand-built fixture: the summary must render, not print "None".
        with tempfile.TemporaryDirectory() as tmp:
            doc = os.path.join(tmp, "min.json")
            with open(doc, "w", encoding="utf-8") as fh:
                json.dump({"unit": ["SomeExistingTests"], "ui": ["OtherUITests"]}, fh)
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "smoke-summary.py"),
                 "--selection", doc],
                capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("None", proc.stdout)


if __name__ == "__main__":
    unittest.main()
