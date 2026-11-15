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

    def test_job_only_runs_on_a_failed_nightly_run_before_its_third_attempt(self):
        with open(RERUN, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("(github.event.workflow_run.event == 'schedule' || "
                      "github.event.workflow_run.display_title == 'Nightly (overnight)')", text)
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


TIMER_DIR = os.path.join(SCRIPTS_DIR, "nightly-timer")
BACKUP_STEP = "Skip the backup cron when the overnight run happened"

# `gh api <runs url> --jq <count>` prints how many other runs the fixture has.
STUB_GH_RUNS = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$STUB_LOG"
[ "$STUB_OTHERS" = fail ] && exit 1
echo "$STUB_OTHERS"
"""


class NightlyOvernightTests(unittest.TestCase):
    """The overnight timer starts Nightly; the cron only backs it up."""

    def _nightly(self):
        with open(NIGHTLY, encoding="utf-8") as fh:
            return fh.read()

    def _backup(self, others):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        bin_dir = os.path.join(tmp, "bin")
        os.mkdir(bin_dir)
        gh = os.path.join(bin_dir, "gh")
        with open(gh, "w") as fh:
            fh.write(STUB_GH_RUNS)
        os.chmod(gh, 0o755)
        out = os.path.join(tmp, "output")
        env = dict(os.environ, PATH=bin_dir + os.pathsep + os.environ["PATH"],
                   STUB_LOG=os.path.join(tmp, "gh.log"), STUB_OTHERS=str(others),
                   GITHUB_OUTPUT=out, REPO="kaishi00/hermes-conduit",
                   RUN_ID="43608496756", GH_TOKEN="stub")
        result = subprocess.run(["bash", "-c", workflow_step_script(NIGHTLY, BACKUP_STEP)],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with open(env["STUB_LOG"]) as fh:
            query = fh.read()
        self.assertIn("branch=main", query)
        self.assertIn('select(.id != 43608496756 and .event != "schedule")', query)
        with open(out) as fh:
            return fh.read().strip(), result.stdout

    def test_backup_cron_skips_after_another_run_on_main(self):
        skip, _ = self._backup(1)
        self.assertEqual(skip, "skip=true")

    def test_backup_cron_runs_and_warns_when_the_timer_missed(self):
        skip, stdout = self._backup(0)
        self.assertEqual(skip, "skip=false")
        self.assertIn("::warning::", stdout)

    def test_backup_cron_runs_when_the_lookup_fails(self):
        skip, stdout = self._backup("fail")
        self.assertEqual(skip, "skip=false")
        self.assertIn("Couldn't list Nightly runs", stdout)
        self.assertNotIn("timer on the Hermes host missed", stdout)

    def test_skip_gates_every_macos_job_and_only_the_cron_checks(self):
        nightly = self._nightly()
        self.assertEqual(nightly.count("    needs: plan\n"),
                         nightly.count("    needs: plan\n    if: needs.plan.outputs.skip != 'true'\n"))
        self.assertIn("if: github.event_name == 'schedule'", nightly)
        self.assertIn('skip: "${{ steps.backup.outputs.skip }}"', nightly)

    def test_overnight_dispatch_is_titled_for_the_rerun(self):
        nightly = self._nightly()
        self.assertIn("run-name: \"${{ inputs.nightly && 'Nightly (overnight)' || 'Nightly' }}\"", nightly)
        with open(os.path.join(TIMER_DIR, "conduit-nightly-dispatch.sh"), encoding="utf-8") as fh:
            script = fh.read()
        self.assertIn('{"ref":"main","inputs":{"nightly":true}}', script)
        self.assertIn("/actions/workflows/nightly.yml/dispatches", script)

    def test_cron_comes_after_the_timer_in_both_eastern_offsets(self):
        # The timer fires at 3:17 AM America/New_York: 07:17 UTC in EDT,
        # 08:17 UTC in EST. The backup cron must come after both.
        with open(os.path.join(TIMER_DIR, "conduit-nightly.timer"), encoding="utf-8") as fh:
            self.assertIn("OnCalendar=*-*-* 03:17:00 America/New_York", fh.read())
        import re
        m = re.search(r'- cron: "(\d+) (\d+) \* \* \*"', self._nightly())
        self.assertIsNotNone(m)
        self.assertGreater(int(m.group(2)) * 60 + int(m.group(1)), 8 * 60 + 17)


# Records curl's argv and stdin, and answers like GitHub's dispatch route.
FAKE_CURL = """#!/usr/bin/env bash
printf '%s\\n' "$@" > "$FAKE_DIR/argv"
cat > "$FAKE_DIR/stdin"
out=""
while [ $# -gt 0 ]; do
  [ "$1" = "-o" ] && { out="$2"; shift; }
  shift
done
printf '%s' "$out" > "$FAKE_DIR/out_path"
if [ -n "$FAKE_FAIL" ]; then printf '000'; exit 7; fi
printf '204'
"""


class NightlyDispatchScriptTests(unittest.TestCase):
    def _run(self, **extra):
        """Runs the script against the fake curl and a no-op sleep."""
        tmp = self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        bin_dir = os.path.join(tmp, "bin")
        os.mkdir(bin_dir)
        curl = os.path.join(bin_dir, "curl")
        with open(curl, "w") as fh:
            fh.write(FAKE_CURL)
        os.chmod(curl, 0o755)
        sleep = os.path.join(bin_dir, "sleep")
        with open(sleep, "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(sleep, 0o755)
        token = os.path.join(tmp, "token")
        with open(token, "w") as fh:
            fh.write("github_pat_fake123")
        env = dict(os.environ, PATH=bin_dir + os.pathsep + os.environ["PATH"],
                   FAKE_DIR=tmp, CONDUIT_NIGHTLY_TOKEN_FILE=token, TMPDIR=tmp, **extra)
        return subprocess.run(
            ["sh", os.path.join(TIMER_DIR, "conduit-nightly-dispatch.sh")],
            env=env, capture_output=True, text=True, timeout=30)

    def test_a_curl_failure_reports_one_000_per_attempt_and_gives_up(self):
        result = self._run(FAKE_FAIL="1")
        self.assertEqual(result.returncode, 1)
        failures = [line for line in result.stderr.splitlines() if "failed:" in line]
        self.assertEqual(len(failures), 4, result.stderr)
        for line in failures:
            self.assertEqual(line.count("000"), 1, line)

    def test_token_goes_to_curl_on_stdin_and_the_response_file_is_removed(self):
        result = self._run()
        tmp = self.tmp
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("HTTP 204", result.stdout)
        with open(os.path.join(tmp, "argv")) as fh:
            argv = fh.read()
        with open(os.path.join(tmp, "stdin")) as fh:
            stdin = fh.read()
        with open(os.path.join(tmp, "out_path")) as fh:
            out_path = fh.read()
        self.assertNotIn("github_pat_fake123", argv)
        self.assertIn("--config\n-\n", argv)
        self.assertIn('header = "Authorization: Bearer github_pat_fake123"', stdin)
        self.assertTrue(out_path)
        self.assertFalse(os.path.exists(out_path))


if __name__ == "__main__":
    unittest.main()
