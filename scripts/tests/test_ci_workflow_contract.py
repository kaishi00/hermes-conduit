"""Contract tests: the workflow must invoke the tooling CLIs correctly.

These tests pin the workflow/script interface so it cannot silently diverge
again (e.g. passing observation files positionally when the script requires
--observations).
"""

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

from _util import SCRIPTS_DIR

REPO_ROOT = os.path.dirname(SCRIPTS_DIR)
WORKFLOW = os.path.join(REPO_ROOT, ".github", "workflows", "ci.yml")


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        if not os.path.exists(WORKFLOW):
            self.skipTest("ci.yml not present")

    def _workflow_text(self):
        with open(WORKFLOW, encoding="utf-8") as fh:
            return fh.read()

    def test_timing_update_uses_observations_flag(self):
        text = self._workflow_text()
        self.assertIn("update-timing-history.py", text)
        # The invocation must pass observations via --observations, not
        # positionally (positional args are rejected by argparse).
        self.assertIn("--observations", text)

    def test_timing_update_guards_missing_plan(self):
        text = self._workflow_text()
        self.assertIn("plan artifact missing", text)

    def test_ci_gate_job_present_and_required_shape(self):
        text = self._workflow_text()
        self.assertIn("CI Gate", text)
        self.assertNotIn("Build & Test", text)

    def test_ci_gate_script_verdict_matches_spec_examples(self):
        spec = {
            ("success", "success", "success", "success"): True,
            ("success", "success", "success", "skipped"): True,
            ("success", "success", "failure", "success"): False,
            ("success", "failure", "skipped", "skipped"): False,
            ("cancelled", "success", "success", "success"): False,
            ("success", "success", "cancelled", "success"): False,
        }
        for (plan, build, unit, ui), expected in spec.items():
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "ci-gate.py"),
                 "--plan", plan, "--build", build,
                 "--unit", unit, "--ui", ui],
                capture_output=True, text=True)
            self.assertEqual(
                proc.returncode == 0, expected,
                f"gate({plan},{build},{unit},{ui}) -> {proc.stdout}")


class TimingUpdateCliShapeTests(unittest.TestCase):
    """Exercise update-timing-history.py with the EXACT argument shape the
    main-only workflow job uses: multiple --observations files, --inventory,
    optional --history, --out."""

    def _run(self, tmp, with_history):
        observations = []
        for i, classes in enumerate(
                [{"AlphaTests": 21.0, "BetaTests": 4.0},
                 {"GammaTests": 9.5}]):
            path = os.path.join(tmp, f"obs{i}.json")
            with open(path, "w", encoding="utf-8") as fh:
                json.dump({"schema_version": 1, "classes": classes}, fh)
            observations.append(path)
        plan = os.path.join(tmp, "plan.json")
        with open(plan, "w", encoding="utf-8") as fh:
            json.dump({"inventory": {"unit": ["AlphaTests", "BetaTests", "GammaTests"],
                                     "ui": []}}, fh)
        out = os.path.join(tmp, "ci-timing", "timing-history.json")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        args = [sys.executable,
                os.path.join(SCRIPTS_DIR, "update-timing-history.py")]
        # Exactly like the workflow: --observations before the file list.
        args += ["--observations"] + observations
        args += ["--inventory", plan]
        if with_history:
            hist = os.path.join(tmp, "history.json")
            with open(hist, "w", encoding="utf-8") as fh:
                json.dump({"schema_version": 1,
                           "classes": {"AlphaTests": 30.0}}, fh)
            args += ["--history", hist]
        args += ["--out", out]
        proc = subprocess.run(args, capture_output=True, text=True)
        return proc, out

    def test_workflow_shape_first_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, out = self._run(tmp, with_history=False)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            with open(out, encoding="utf-8") as fh:
                doc = json.load(fh)
            self.assertEqual(sorted(doc["classes"]),
                             ["AlphaTests", "BetaTests", "GammaTests"])

    def test_workflow_shape_with_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = os.path.join(tmp, "plan.json")
            with open(inv, "w", encoding="utf-8") as fh:
                json.dump({"inventory": {"unit": ["AlphaTests"], "ui": []}}, fh)
            obs = os.path.join(tmp, "obs.json")
            with open(obs, "w", encoding="utf-8") as fh:
                json.dump({"schema_version": 1,
                           "classes": {"AlphaTests": 20.0}}, fh)
            hist = os.path.join(tmp, "history.json")
            with open(hist, "w", encoding="utf-8") as fh:
                json.dump({"schema_version": 1,
                           "classes": {"AlphaTests": 10.0}}, fh)
            out = os.path.join(tmp, "out.json")
            proc = subprocess.run(
                [sys.executable,
                 os.path.join(SCRIPTS_DIR, "update-timing-history.py"),
                 "--observations", obs,
                 "--inventory", inv,
                 "--history", hist,
                 "--out", out],
                capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            with open(out, encoding="utf-8") as fh:
                doc = json.load(fh)
            self.assertAlmostEqual(doc["classes"]["AlphaTests"], 12.5)


if __name__ == "__main__":
    unittest.main()
