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

    def test_ui_job_is_a_dynamic_matrix_with_per_class_runner(self):
        text = self._workflow_text()
        ui = self._job_text("ui")
        # Matrix fanout comes from the planner, never a hard-coded class list,
        # and one hung shard must not cancel the others.
        self.assertIn("matrix: ${{ fromJSON(needs.plan.outputs.ui-matrix) }}", ui)
        self.assertIn("fail-fast: false", ui)
        self.assertIn('needs: [plan, build]', ui,
                      "UI shards must consume the SHARED build products")
        # Per-class runner invocation with planned watchdogs.
        self.assertIn("--kind ui", ui)
        self.assertIn("--class-timeouts", ui)
        self.assertIn('--classes "$LANE_CLASSES"', ui)
        self.assertNotIn(
            "--iterations", ui,
            "UI lanes must not use native multi-iteration retry; the runner "
            "retries exactly the failed class once")
        # The plan job must emit the UI matrix the job consumes.
        self.assertIn("--ui-matrix-out", text)
        self.assertIn('echo "ui-matrix=', text)

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
