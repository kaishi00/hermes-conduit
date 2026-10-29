"""Coverage for nightly-rerun.yml's decision to rerun a failed Nightly.

The workflow reruns a red Nightly only when every job that didn't pass was
cancelled before GitHub gave it a runner (macOS capacity). This runs the
step's `run:` body against a stub `gh` and fixture job lists, so a filter
that started retrying jobs that ran and failed fails the CI-tooling suite.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest

from _util import SCRIPTS_DIR, workflow_step_script

WORKFLOWS = os.path.join(os.path.dirname(SCRIPTS_DIR), ".github", "workflows")
RERUN = os.path.join(WORKFLOWS, "nightly-rerun.yml")
NIGHTLY = os.path.join(WORKFLOWS, "nightly.yml")
RERUN_STEP = "Rerun the jobs that never got a runner"

# `gh api <jobs url> --jq .jobs` prints the fixture; the POST is recorded.
STUB_GH = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$STUB_LOG"
case "$*" in
  *rerun-failed-jobs*) exit 0 ;;
  *) cat "$STUB_JOBS" ;;
esac
"""


def ran(name, conclusion):
    return {"name": name, "conclusion": conclusion, "runner_id": 1000051818,
            "steps": [{"name": "Set up job"}]}


def unacquired(name):
    return {"name": name, "conclusion": "cancelled", "runner_id": 0, "steps": []}


class NightlyRerunTests(unittest.TestCase):
    def setUp(self):
        if shutil.which("jq") is None:
            if os.environ.get("CI"):
                self.fail("jq is missing on CI, so the rerun decision went untested")
            self.skipTest("jq not installed")
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        bin_dir = os.path.join(self.tmp, "bin")
        os.mkdir(bin_dir)
        gh = os.path.join(bin_dir, "gh")
        with open(gh, "w") as fh:
            fh.write(STUB_GH)
        os.chmod(gh, 0o755)
        self.env = dict(os.environ, PATH=bin_dir + os.pathsep + os.environ["PATH"],
                        STUB_LOG=os.path.join(self.tmp, "gh.log"),
                        STUB_JOBS=os.path.join(self.tmp, "jobs.json"),
                        REPO="kaishi00/hermes-conduit", RUN_ID="40899668837",
                        ATTEMPT="1", GH_TOKEN="stub")

    def _reruns(self, jobs):
        with open(self.env["STUB_JOBS"], "w") as fh:
            json.dump(jobs, fh)
        result = subprocess.run(["bash", "-c", workflow_step_script(RERUN, RERUN_STEP)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with open(self.env["STUB_LOG"]) as fh:
            return any("rerun-failed-jobs" in line for line in fh)

    def test_reruns_when_every_lost_job_never_got_a_runner(self):
        # Nightly 2026-10-29: three jobs dropped, every job that ran passed.
        self.assertTrue(self._reruns([
            ran("Plan", "success"), ran("Unit suite (shard 2)", "success"),
            unacquired("Unit suite (shard 1)"), unacquired("UI suite (shard 2)"),
            unacquired("Timing families (repeat 1)")]))

    def test_leaves_a_job_that_ran_and_failed(self):
        self.assertFalse(self._reruns([
            ran("Unit suite (shard 1)", "failure"), unacquired("UI suite (shard 2)")]))

    def test_leaves_a_job_that_ran_and_timed_out(self):
        self.assertFalse(self._reruns([
            ran("UI suite (shard 1)", "timed_out"), unacquired("UI suite (shard 2)")]))

    def test_leaves_a_job_cancelled_after_it_started(self):
        self.assertFalse(self._reruns([ran("UI suite (shard 1)", "cancelled")]))

    def test_leaves_a_run_with_nothing_lost(self):
        self.assertFalse(self._reruns([ran("Plan", "success"), ran("UI", "skipped")]))

    def test_job_only_runs_on_a_failed_run_before_its_third_attempt(self):
        with open(RERUN, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("github.event.workflow_run.conclusion == 'failure'", text)
        self.assertIn("github.event.workflow_run.run_attempt < 3", text)

    def test_follows_the_nightly_workflow(self):
        # The trigger names Nightly by its `name:`, and a lost job can only
        # be told from a sibling's failure when no matrix cancels the rest.
        with open(RERUN, encoding="utf-8") as fh:
            self.assertIn("workflows: [Nightly]", fh.read())
        with open(NIGHTLY, encoding="utf-8") as fh:
            nightly = fh.read()
        self.assertTrue(nightly.startswith("name: Nightly\n"))
        self.assertEqual(nightly.count("strategy:"), nightly.count("fail-fast: false"))


if __name__ == "__main__":
    unittest.main()
