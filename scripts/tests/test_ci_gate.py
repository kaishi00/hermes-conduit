"""Regression coverage for scripts/ci-gate.py (stable branch-protection check)."""

import importlib.util
import os
import subprocess
import sys
import unittest

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location(
    "ci_gate", os.path.join(SCRIPTS_DIR, "ci-gate.py"))
ci_gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci_gate)


class VerdictTests(unittest.TestCase):
    def test_all_success_passes(self):
        passed, _reason = ci_gate.verdict("success", "success", "success")
        self.assertTrue(passed)

    def test_required_jobs_are_plan_smoke_and_self_test(self):
        self.assertEqual(ci_gate.REQUIRED_SUCCESS, ("plan", "smoke", "self-test"))

    def test_smoke_skipped_fails_gate(self):
        # Unless the plan job says the change doesn't need it (below), a
        # skipped smoke job is a failure: the plan job fails closed
        # on an empty curated selection and every test step refuses to run
        # unfiltered, so a skipped smoke job is an upstream failure cascade.
        passed, reason = ci_gate.verdict("success", "skipped", "success")
        self.assertFalse(passed)
        self.assertIn("smoke", reason)

    def test_smoke_skipped_passes_when_the_plan_says_it_is_not_needed(self):
        # A PR that changes only docs and review config skips the smoke job.
        passed, _reason = ci_gate.verdict("success", "skipped", "success", "false")
        self.assertTrue(passed)

    def test_smoke_skipped_fails_when_the_plan_failed_or_said_needed(self):
        for plan, needed in (("failure", "false"), ("success", "true"), ("success", "")):
            passed, reason = ci_gate.verdict(plan, "skipped", "success", needed)
            self.assertFalse(passed, (plan, needed))
            self.assertIn("smoke", reason)

    def test_smoke_not_needed_still_fails_a_failed_smoke(self):
        passed, _reason = ci_gate.verdict("success", "failure", "success", "false")
        self.assertFalse(passed)

    def test_smoke_failure_fails_gate(self):
        # A failed unit smoke step or a failed UI smoke step both fail the job.
        passed, reason = ci_gate.verdict("success", "failure", "success")
        self.assertFalse(passed)
        self.assertIn("smoke", reason)

    def test_smoke_cancelled_fails_gate(self):
        passed, _reason = ci_gate.verdict("success", "cancelled", "success")
        self.assertFalse(passed)

    def test_plan_failure_fails_gate(self):
        passed, _reason = ci_gate.verdict("failure", "skipped", "skipped")
        self.assertFalse(passed)

    def test_plan_cancelled_fails_gate(self):
        passed, _reason = ci_gate.verdict("cancelled", "success", "success")
        self.assertFalse(passed)

    def test_self_test_failure_fails_gate(self):
        passed, reason = ci_gate.verdict("success", "success", "failure")
        self.assertFalse(passed)
        self.assertIn("self-test", reason)

    def test_self_test_cancelled_fails_gate(self):
        passed, _reason = ci_gate.verdict("success", "success", "cancelled")
        self.assertFalse(passed)

    def test_self_test_skipped_fails_gate(self):
        # The CI-tooling suites have no legitimate skip path: a skip means
        # an upstream failure suppressed them, which is not a success.
        passed, reason = ci_gate.verdict("success", "success", "skipped")
        self.assertFalse(passed)
        self.assertIn("self-test", reason)

    def test_every_violation_is_reported(self):
        passed, reason = ci_gate.verdict("failure", "skipped", "cancelled")
        self.assertFalse(passed)
        for name in ("plan", "smoke", "self-test"):
            self.assertIn(name, reason)


class CliTests(unittest.TestCase):
    def _run(self, plan, smoke, self_test="success"):
        return subprocess.run(
            [sys.executable, os.path.join(SCRIPTS_DIR, "ci-gate.py"),
             "--plan", plan, "--smoke", smoke, "--self-test", self_test],
            capture_output=True, text=True)

    def test_cli_exit_codes(self):
        self.assertEqual(self._run("success", "success").returncode, 0)
        self.assertNotEqual(
            self._run("success", "skipped").returncode, 0,
            "a skipped smoke job must not read as a passing gate")
        self.assertNotEqual(self._run("failure", "skipped").returncode, 0)
        self.assertNotEqual(self._run("success", "failure").returncode, 0)
        self.assertNotEqual(
            self._run("success", "success", self_test="failure").returncode, 0)

    def test_cli_rejects_the_retired_job_flags(self):
        # CI v4's --unit/--ui-smoke are gone with their jobs: a workflow that
        # still passes them must fail loudly, not be read as a pass.
        proc = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS_DIR, "ci-gate.py"),
             "--plan", "success", "--unit", "success", "--ui-smoke", "success",
             "--self-test", "success"],
            capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0)


if __name__ == "__main__":
    unittest.main()
