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
        passed, _reason = ci_gate.verdict("success", "success", "success", "success")
        self.assertTrue(passed)

    def test_ui_skipped_passes(self):
        passed, _reason = ci_gate.verdict("success", "success", "success", "skipped")
        self.assertTrue(passed)

    def test_unit_failure_fails_gate(self):
        passed, reason = ci_gate.verdict("success", "success", "failure", "success")
        self.assertFalse(passed)
        self.assertIn("unit", reason)

    def test_build_failure_fails_gate(self):
        passed, _reason = ci_gate.verdict("success", "failure", "skipped", "skipped")
        self.assertFalse(passed)

    def test_plan_failure_fails_gate(self):
        passed, _reason = ci_gate.verdict("failure", "skipped", "skipped", "skipped")
        self.assertFalse(passed)

    def test_plan_cancelled_fails_gate(self):
        passed, _reason = ci_gate.verdict("cancelled", "success", "success", "success")
        self.assertFalse(passed)

    def test_unit_cancelled_fails_gate(self):
        passed, _reason = ci_gate.verdict("success", "success", "cancelled", "success")
        self.assertFalse(passed)

    def test_ui_cancelled_fails_gate(self):
        passed, _reason = ci_gate.verdict("success", "success", "success", "cancelled")
        self.assertFalse(passed)

    def test_missing_upstream_results_fail_gate(self):
        # A skip because an upstream job failed is still not a success.
        passed, _reason = ci_gate.verdict("success", "success", "skipped", "skipped")
        self.assertFalse(passed)


class CliTests(unittest.TestCase):
    def _run(self, plan, build, unit, ui):
        return subprocess.run(
            [sys.executable, os.path.join(SCRIPTS_DIR, "ci-gate.py"),
             "--plan", plan, "--build", build,
             "--unit", unit, "--ui", ui],
            capture_output=True, text=True)

    def test_cli_exit_codes(self):
        self.assertEqual(self._run("success", "success", "success", "success").returncode, 0)
        self.assertEqual(self._run("success", "success", "success", "skipped").returncode, 0)
        self.assertNotEqual(self._run("success", "failure", "skipped", "skipped").returncode, 0)
        self.assertNotEqual(self._run("success", "success", "failure", "success").returncode, 0)


if __name__ == "__main__":
    unittest.main()
