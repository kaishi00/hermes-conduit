"""Contract tests: the hosted workflow must invoke the tooling CLIs correctly.

These tests pin the workflow/script interface so it cannot silently diverge
again (e.g. passing observation files positionally when the script requires
--observations).

CI v4 shape (docs/CI.md): GitHub-hosted CI is the merge gate. It compiles
everything, runs the cheap Linux validation, every unit class except the
nightly-only timing families (scripts/hosted-suite.json, split into shards),
and the curated UI smoke selection (scripts/smoke-suite.json). The timing
families and the complete UI suite run in nightly.yml. There is NO lane
matrix, NO timing-history job and NO native flake retry that would re-run a
genuine assertion until it agrees.
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

    # --- the plan job owns every test-to-run mapping -----------------------

    def test_plan_job_selects_the_smoke_suite_and_the_unit_shards(self):
        plan = self._job_text("plan")
        self.assertIn("plan-tests.py smoke", plan,
                      "the plan job owns the UI smoke selection")
        self.assertIn("--suite scripts/smoke-suite.json", plan)
        self.assertIn("ui-csv", plan)
        self.assertIn("plan-tests.py hosted", plan,
                      "the plan job owns the unit shards")
        self.assertIn("--suite scripts/hosted-suite.json", plan)
        self.assertIn("unit-shards", plan)
        self.assertIn("smoke-summary.py", plan)

    def test_unit_job_runs_one_shard_per_matrix_entry(self):
        unit = self._job_text("unit")
        self.assertIn("needs: plan", unit)
        self.assertIn("fromJSON(needs.plan.outputs.unit-shards)", unit)
        self.assertIn("fail-fast: false", unit,
                      "one failing shard must not cancel the other")
        self.assertIn('UNIT_CLASSES: "${{ matrix.classes }}"', unit)
        self.assertIn("-only-testing:ConduitTests/", unit)
        # A genuine assertion must FAIL the run: no Xcode-native retry, and no
        # job-level retry either.
        self.assertNotIn("-test-iterations", unit)
        self.assertNotIn("-retry-tests-on-failure", unit)
        self.assertNotIn("targeted retry", unit)
        self.assertIn("-test-timeouts-enabled YES", unit,
                      "a hung unit test must be killed, not burn the job ceiling")

    def test_test_jobs_build_while_the_simulator_boots(self):
        """Each macOS test job builds its own products with the simulator
        booting in the background: no shared-artifact hop, and the boot hides
        behind the build."""
        for job in ("unit", "ui-smoke"):
            text = self._job_text(job)
            self.assertIn("bash scripts/ci-hosted-build.sh", text, job)
            self.assertIn("needs: plan", text, job)
            self.assertNotIn("build-products", text, job)
        with open(os.path.join(SCRIPTS_DIR, "ci-hosted-build.sh"), encoding="utf-8") as fh:
            build = fh.read()
        self.assertIn("ci-prepare-smoke.sh", build)
        self.assertIn("&\n", build, "preparation must run in the background")
        self.assertIn("ci-build-for-testing.sh", build)
        self.assertIn('wait "$prepare_pid"', build)
        self.assertIn("XCRUN_FILE=", build)

    def test_no_shared_build_job_remains(self):
        text = self._workflow_text()
        self.assertFalse(
            any(line.startswith("  ") and line.strip() == "build:"
                for line in text.splitlines()),
            "the shared build job is gone: each test job builds for itself")
        self.assertNotIn("upload-artifact@v4\n        with:\n          name: build-products", text)

    def test_ui_smoke_job_runs_the_curated_classes(self):
        ui = self._job_text("ui-smoke")
        self.assertIn('UI_CLASSES: "${{ needs.plan.outputs.ui-csv }}"', ui)
        self.assertIn("-only-testing:ConduitUITests/", ui)
        self.assertNotIn("-test-iterations", ui)
        self.assertNotIn("-retry-tests-on-failure", ui)
        self.assertIn("one targeted retry", ui,
                      "UI smoke absorbs exactly one runner-level flake, visibly")

    def test_test_jobs_fail_closed_on_an_empty_selection(self):
        # With no -only-testing filter, xcodebuild runs the WHOLE suite.
        for job in ("unit", "ui-smoke"):
            self.assertIn("refusing to run unfiltered", self._job_text(job),
                          f"{job} must refuse an empty selection")

    def test_unit_job_runs_in_bounded_sequential_batches(self):
        self.assertIn("UNIT_BATCH_SIZE", self._job_text("unit"))

    def test_test_jobs_pin_the_simulator_destination(self):
        # A name-only destination lets xcodebuild pick the first of several
        # devices with that name; the shared ci-lib.sh helpers pin the UDID.
        with open(os.path.join(SCRIPTS_DIR, "ci-prepare-smoke.sh"), encoding="utf-8") as fh:
            preparation = fh.read()
        for needle in ("ci-lib.sh", "wait_for_destination_device",
                       "build_destination", "shutdown_own_simulator",
                       "LOG_DIR=", "export LOG_DIR"):
            self.assertIn(needle, preparation)
        for job in ("unit", "ui-smoke"):
            text = self._job_text(job)
            self.assertIn('-destination "$DESTINATION"', text, job)
            self.assertNotIn("platform=iOS Simulator,name=", text,
                             f"{job} must not hand xcodebuild an unpinned destination")

    def test_all_self_test_groups_remain_required_and_run_after_a_failure(self):
        text = self._job_text("self-test")
        self.assertIn("group: [fast, lane, local-gate]", text)
        self.assertIn("fail-fast: false", text)
        self.assertIn('python3 scripts/ci-self-test.py --group "${{ matrix.group }}"', text)
        self.assertIn("self-test]", self._job_text("ci-gate"))
        self.assertIn('--self-test "${{ needs.self-test.result }}"', self._job_text("ci-gate"))

    def test_ci_gate_requires_every_test_job(self):
        gate = self._job_text("ci-gate")
        self.assertIn("needs: [plan, unit, ui-smoke, self-test]", gate)
        self.assertIn("if: always()", gate)
        self.assertIn("name: CI Gate", gate)

    def test_no_write_only_build_metadata_artifact(self):
        self.assertNotIn("name: build-meta", self._workflow_text(),
                         "nothing consumes build-meta once the report job is gone")

    def test_no_lane_matrix_or_timing_history_machinery_remains(self):
        text = self._workflow_text()
        self.assertNotIn("fromJSON(needs.plan.outputs.matrix)", text)
        self.assertNotIn("fromJSON(needs.plan.outputs.ui-matrix)", text)
        self.assertNotIn("actions/cache/restore", text,
                         "the timing-history cache is gone with its job")
        for obsolete in ("report:", "timing-history-update:", "unit-smoke:"):
            self.assertFalse(
                any(line.startswith("  ") and line.strip() == obsolete
                    for line in text.splitlines()),
                f"obsolete job {obsolete!r} still present in ci.yml")

    def test_ci_gate_script_verdict_matches_spec_examples(self):
        spec = {
            ("success", "success", "success", "success"): True,
            # No hosted job is ever legitimately skipped: a skip is always an
            # upstream failure cascade - and fails the gate.
            ("success", "success", "skipped", "success"): False,
            ("success", "failure", "success", "success"): False,
            ("success", "success", "failure", "success"): False,
            ("success", "timed_out", "success", "success"): False,
            ("success", "success", "timed_out", "success"): False,
            ("success", "success", "success", "failure"): False,
            ("failure", "skipped", "skipped", "skipped"): False,
            ("cancelled", "success", "success", "success"): False,
            ("success", "cancelled", "success", "success"): False,
        }
        for (plan, unit, ui, self_test), expected in spec.items():
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "ci-gate.py"),
                 "--plan", plan, "--unit", unit, "--ui-smoke", ui,
                 "--self-test", self_test],
                capture_output=True, text=True)
            self.assertEqual(
                proc.returncode == 0, expected,
                f"gate({plan},{unit},{ui},{self_test}) -> {proc.stdout}")


class NightlyWorkflowTests(unittest.TestCase):
    NIGHTLY = os.path.join(REPO_ROOT, ".github", "workflows", "nightly.yml")

    def setUp(self):
        if not os.path.exists(self.NIGHTLY):
            self.skipTest("nightly.yml not present")
        with open(self.NIGHTLY, encoding="utf-8") as fh:
            self.text = fh.read()

    def test_nightly_never_runs_on_pull_requests(self):
        self.assertIn("schedule:", self.text)
        self.assertIn("workflow_dispatch:", self.text)
        self.assertNotIn("pull_request", self.text)

    def test_nightly_runs_the_timing_families_and_the_whole_ui_suite(self):
        self.assertIn("plan-tests.py hosted", self.text)
        self.assertIn("nightly_unit_csv", self.text)
        self.assertIn("fromJSON(needs.plan.outputs.ui-shards)", self.text)
        self.assertIn("TIMING_REPEATS", self.text)
        self.assertIn("refusing to run unfiltered", self.text)
        self.assertNotIn("-retry-tests-on-failure", self.text)


class HostedSelectionTests(unittest.TestCase):
    """plan-tests.py hosted: every unit class lands in exactly one PR shard or
    the nightly list, and a stale nightly name fails the plan."""

    HOSTED_SUITE = os.path.join(SCRIPTS_DIR, "hosted-suite.json")

    def _run(self, suite_path, out_path=None):
        args = [sys.executable, os.path.join(SCRIPTS_DIR, "plan-tests.py"),
                "hosted", "--repo-root", REPO_ROOT, "--suite", suite_path]
        if out_path:
            args += ["--out", out_path]
        return subprocess.run(args, capture_output=True, text=True)

    def _write(self, tmp, doc):
        path = os.path.join(tmp, "hosted.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh)
        return path

    def test_shipped_suite_partitions_the_whole_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out.json")
            proc = self._run(self.HOSTED_SUITE, out)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            with open(out, encoding="utf-8") as fh:
                doc = json.load(fh)
        with open(self.HOSTED_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        shard_classes = [c for csv in doc["unit_shards"] for c in csv.split(",")]
        nightly = doc["nightly_unit_csv"].split(",")
        self.assertEqual(len(doc["unit_shards"]), suite["unit_shards"])
        self.assertEqual(len(shard_classes), len(set(shard_classes)))
        self.assertFalse(set(shard_classes) & set(nightly))
        self.assertEqual(len(shard_classes) + len(nightly), doc["inventory_unit"])
        ui_classes = [c for csv in doc["ui_shards"] for c in csv.split(",")]
        self.assertEqual(len(ui_classes), doc["inventory_ui"])

    def test_a_stale_nightly_class_fails_the_selection(self):
        with open(self.HOSTED_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        suite["nightly_only_unit"] = suite["nightly_only_unit"] + ["NoSuchClassTests"]
        with tempfile.TemporaryDirectory() as tmp:
            proc = self._run(self._write(tmp, suite))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("NoSuchClassTests", proc.stdout)

    def test_a_non_positive_shard_count_fails_the_selection(self):
        with open(self.HOSTED_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        for bad in (0, -1, "2", True):
            suite["unit_shards"] = bad
            with tempfile.TemporaryDirectory() as tmp:
                proc = self._run(self._write(tmp, suite))
            self.assertNotEqual(proc.returncode, 0, repr(bad))


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
        self.assertIn("not in the UI smoke set", proc.stdout)

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
        self.assertIn("Hosted CI selection", summary.stdout)
        self.assertIn("nightly workflow", summary.stdout)

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
