"""Integration coverage for the hosted smoke jobs' bash run steps.

The smoke jobs' load-bearing behaviour - the empty-selection guard, the bounded
sequential batching, failing fast when a batch fails - exists only inside
`.github/workflows/ci.yml`. This module extracts those `run:` bodies from the
workflow and executes them against a stub `xcodebuild`, so a broken loop or a
guard that stopped guarding fails the CI-tooling suite instead of the first PR
that touches the workflow.

It is deliberately stdlib-only and YAML-library-free (the workflow is parsed by
indentation, like `test_ci_workflow_contract`), and it runs the script with
whatever `bash` is on PATH - bash 3.2 on macOS runners, where the local gate's
static phase runs this same suite.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from _util import SCRIPTS_DIR

REPO_ROOT = os.path.dirname(SCRIPTS_DIR)
WORKFLOW = os.path.join(REPO_ROOT, ".github", "workflows", "ci.yml")

UNIT_STEP = "Run this shard's unit classes"
UI_STEP = "Run the curated UI smoke suite"

# Records every invocation, and can be told to fail from the Nth one on.
STUB = """#!/usr/bin/env bash
printf 'INVOKE|%s\\n' "$*" >> "$STUB_LOG"
count=$(grep -c '^INVOKE|' "$STUB_LOG" 2>/dev/null || printf '1')
fail=0
if [ -n "${STUB_FAIL_AT:-}" ] && [ "$count" -ge "$STUB_FAIL_AT" ]; then
  fail=1
fi
if [ -n "${STUB_FAIL_FIRST_N:-}" ] && [ "$count" -le "$STUB_FAIL_FIRST_N" ]; then
  fail=1
fi
if [ "$fail" = "1" ]; then
  if [ "${STUB_SILENT_FAIL:-0}" != "1" ]; then
    printf "Test Suite '%s' failed\\n" "${STUB_FLAKE_CLASS:-StubFailingTests}"
  fi
  exit 1
fi
exit 0
"""

# Answers the device probes the prepare step makes through ci-lib.sh, so the
# step resolves a destination instead of waiting out its settle budget. The run
# steps' stub is separate: they are invoked through xcodebuild.
STUB_XCRUN = """#!/usr/bin/env bash
if [ "${1:-}" = "xcresulttool" ]; then
  printf '%s\\n' "${STUB_RESULT_DOC:-unreadable-result}"
  exit 0
fi
if [ "${1:-}" = "simctl" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "devices" ]; then
  printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"name":"%s","udid":"STUB-DEVICE-0000-0000","isAvailable":true}]}}\\n' "${SIMULATOR_NAME:-iPhone 17 Pro}"
fi
exit 0
"""


def _step_script(step_name):
    """Return the dedented `run:` block of the named workflow step."""
    with open(WORKFLOW, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip() == "- name: " + step_name:
            start = i
            break
    if start is None:
        raise AssertionError("step {0!r} not found in ci.yml".format(step_name))
    run_at = None
    for j in range(start + 1, len(lines)):
        if lines[j].strip().startswith("run:"):
            run_at = j
            break
    if run_at is None:
        raise AssertionError("step {0!r} has no run block".format(step_name))
    inline = lines[run_at].strip()[len("run:"):].strip()
    if inline != "|":
        return inline + "\n"
    run_indent = len(lines[run_at]) - len(lines[run_at].lstrip(" "))
    body = []
    for line in lines[run_at + 1:]:
        if not line.strip():
            body.append("")
            continue
        if len(line) - len(line.lstrip(" ")) <= run_indent:
            break
        body.append(line)
    widths = [len(l) - len(l.lstrip(" ")) for l in body if l.strip()]
    pad = min(widths) if widths else 0
    return "\n".join(l[pad:] if l.strip() else "" for l in body) + "\n"


class SmokeJobRunnerTests(unittest.TestCase):
    def setUp(self):
        if not os.path.exists(WORKFLOW):
            self.skipTest("ci.yml not present")
        self.bash = shutil.which("bash")
        if not self.bash:
            self.skipTest("bash not available")
        self.tmp = tempfile.mkdtemp(prefix="smoke-job-")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.log = os.path.join(self.tmp, "calls.log")
        for name, body in (("xcodebuild", STUB), ("xcrun", STUB_XCRUN),
                           ("defaults", "#!/usr/bin/env bash\nexit 0\n")):
            path = os.path.join(self.bin, name)
            with open(path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(body)
            os.chmod(path, 0o755)
        if not self._stub_runs():
            self.skipTest("cannot execute a stub executable in this environment")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _env(self, **extra):
        env = dict(os.environ)
        # Nothing from the developer's shell may leak into the step: the
        # "unset" case must actually be unset.
        for name in ("UNIT_BATCH_SIZE", "STUB_FAIL_AT", "STUB_FAIL_FIRST_N",
                     "STUB_FLAKE_CLASS", "STUB_SILENT_FAIL", "UNIT_CLASSES",
                     "UI_CLASSES", "STUB_RESULT_DOC"):
            env.pop(name, None)
        env["PATH"] = self.bin + os.pathsep + env.get("PATH", "")
        env["STUB_LOG"] = self.log
        env["XCRUN_FILE"] = os.path.join(self.tmp, "fake.xctestrun")
        env["SIMULATOR_NAME"] = "iPhone 17 Pro"
        # Exported by the "Prepare the pinned simulator destination" step, which
        # needs macOS-only machinery (ci-lib.sh job control) - its wiring is
        # pinned by WorkflowContractTests instead.
        env["DESTINATION"] = "platform=iOS Simulator,id=STUB-UDID,arch=arm64"
        env.update({k: str(v) for k, v in extra.items()})
        return env

    def _stub_runs(self):
        probe = os.path.join(self.tmp, "probe.sh")
        with open(probe, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("#!/usr/bin/env bash\nxcodebuild --probe || exit 1\n")
        proc = subprocess.run([self.bash, probe], env=self._env(),
                              capture_output=True, text=True)
        return proc.returncode == 0

    def _run_step(self, step_name, **env_extra):
        path = os.path.join(self.tmp, step_name.replace(" ", "_") + ".sh")
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(_step_script(step_name))
        with open(self.log, "w", encoding="utf-8"):
            pass
        return subprocess.run([self.bash, path], env=self._env(**env_extra),
                              capture_output=True, text=True)

    def _invocations(self):
        with open(self.log, encoding="utf-8") as fh:
            return [l for l in fh.read().splitlines() if l.startswith("INVOKE|")]

    @staticmethod
    def _classes(prefix, count):
        return ",".join("{0}{1}Tests".format(prefix, i) for i in range(count))

    # --- unit smoke: bounded sequential batches -----------------------------

    def test_unit_smoke_splits_into_batches_of_the_configured_size(self):
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES=self._classes("Unit", 32),
                              UNIT_BATCH_SIZE=8)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        invocations = self._invocations()
        self.assertEqual(len(invocations), 4, invocations)
        for invocation in invocations:
            self.assertEqual(invocation.count("-only-testing:ConduitTests/"), 8,
                             invocation)
        self.assertEqual(proc.stdout.count("::group::"), 4)
        self.assertEqual(proc.stdout.count("::group::"), proc.stdout.count("::endgroup::"))

    def test_unit_smoke_defaults_the_batch_size_when_unset(self):
        # The workflow always sets UNIT_BATCH_SIZE; the default exists so a
        # future edit that forgets it degrades to the shipped batch size,
        # not to `set -u` and not to an unbounded invocation.
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES=self._classes("Unit", 72))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(len(self._invocations()), 3, "72 classes / 35 per batch")
        self.assertIn("batches of at most 35", proc.stdout)

    def test_unit_smoke_keeps_the_remainder_batch(self):
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES=self._classes("Unit", 20),
                              UNIT_BATCH_SIZE=8)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        sized = [i.count("-only-testing:ConduitTests/") for i in self._invocations()]
        self.assertEqual(sized, [8, 8, 4], sized)

    def test_unit_smoke_runs_a_single_class_in_one_batch(self):
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES="OnlyOneTests",
                              UNIT_BATCH_SIZE=8)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(len(self._invocations()), 1)

    def test_unit_shard_runs_every_batch_and_fails_when_one_fails(self):
        # A failing batch must fail the job, but must not hide the batches
        # after it: the shard is the whole suite's coverage for its classes.
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES=self._classes("Unit", 20),
                              UNIT_BATCH_SIZE=8, STUB_FAIL_FIRST_N=2)
        self.assertNotEqual(proc.returncode, 0,
                            "a failing batch must fail the job")
        invocations = self._invocations()
        self.assertEqual(len(invocations), 3, invocations)
        self.assertIn("2 of 3 batch invocation(s) failed (batches 1 2)", proc.stdout)
        self.assertEqual(proc.stdout.count("::group::"), proc.stdout.count("::endgroup::"),
                         "every opened log group must be closed, including on failure")

    def test_unit_smoke_refuses_an_empty_selection(self):
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES="", UNIT_BATCH_SIZE=8)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self._invocations(), [],
                         "nothing may be invoked without a class filter")
        self.assertIn("refusing to run unfiltered", proc.stdout + proc.stderr)

    def test_unit_smoke_rejects_a_malformed_batch_size(self):
        for bad in ("", "0", "many", "00", " "):
            proc = self._run_step(UNIT_STEP, UNIT_CLASSES="SomeTests",
                                  UNIT_BATCH_SIZE=bad)
            self.assertNotEqual(proc.returncode, 0, "batch size {0!r}".format(bad))
            self.assertEqual(self._invocations(), [], "batch size {0!r}".format(bad))

    def test_unit_smoke_reads_a_leading_zero_batch_size_as_decimal(self):
        # `10#` is load-bearing: without it bash would read "08" as an invalid
        # octal and the step would die instead of batching.
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES=self._classes("Unit", 8),
                              UNIT_BATCH_SIZE="08")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(len(self._invocations()), 1)
        self.assertIn("batches of at most 8", proc.stdout)

    # --- UI smoke: one invocation, same guards ------------------------------

    def test_ui_smoke_runs_the_curated_classes_in_one_invocation(self):
        proc = self._run_step(UI_STEP,
                              UI_CLASSES="ConnectionSetupUITests,ProfilePickerUITests")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        invocations = self._invocations()
        self.assertEqual(len(invocations), 1, invocations)
        self.assertEqual(invocations[0].count("-only-testing:ConduitUITests/"), 2)

    def test_ui_smoke_absorbs_one_runner_flake_and_reports_it(self):
        # The lane runner's rule for a failing UI batch: one targeted retry,
        # with the class that failed reported as a runner-level flake.
        proc = self._run_step(UI_STEP,
                              UI_CLASSES="ConnectionSetupUITests,ProfilePickerUITests",
                              STUB_FAIL_FIRST_N=1,
                              STUB_FLAKE_CLASS="ConnectionSetupUITests")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(len(self._invocations()), 2, "exactly one retry")
        self.assertIn("runner-level flake absorbed", proc.stdout)
        self.assertIn("ConnectionSetupUITests", proc.stdout)

    @staticmethod
    def _result_doc(failed):
        return json.dumps({"testNodes": [{"children": [{"nodeType": "Test Bundle",
            "name": "ConduitUITests", "children": [
                {"nodeType": "Test Suite", "name": cls, "children": [
                    {"nodeType": "Test Case", "name": "testFixture()",
                     "result": "Failed" if cls in failed else "Passed"}]}
                for cls in ("ConnectionSetupUITests", "ProfilePickerUITests")]}]}]})

    def test_ui_retry_excludes_the_class_that_already_passed(self):
        proc = self._run_step(UI_STEP,
                              UI_CLASSES="ConnectionSetupUITests,ProfilePickerUITests",
                              STUB_FAIL_FIRST_N=1,
                              STUB_RESULT_DOC=self._result_doc(["ProfilePickerUITests"]))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        invocations = self._invocations()
        self.assertEqual(len(invocations), 2)
        self.assertIn("-only-testing:ConduitUITests/ConnectionSetupUITests", invocations[0])
        self.assertIn("-only-testing:ConduitUITests/ProfilePickerUITests", invocations[1])
        self.assertNotIn("-only-testing:ConduitUITests/ConnectionSetupUITests", invocations[1])

    def test_ui_retry_includes_multiple_failed_classes_once(self):
        proc = self._run_step(UI_STEP,
                              UI_CLASSES="ConnectionSetupUITests,ProfilePickerUITests",
                              STUB_FAIL_FIRST_N=1,
                              STUB_RESULT_DOC=self._result_doc(["ConnectionSetupUITests", "ProfilePickerUITests"]))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(len(self._invocations()), 2)
        self.assertEqual(self._invocations()[1].count("-only-testing:ConduitUITests/"), 2)

    def test_ui_assertion_metadata_retries_only_the_failed_class(self):
        doc = json.loads(self._result_doc(["ProfilePickerUITests"]))
        failed_case = doc["testNodes"][0]["children"][0]["children"][1]["children"][0]
        failed_case["children"] = [{"nodeType": "Failure Message", "name": "XCTAssertTrue failed",
                                    "sourceLocation": {"filePath": "ProfilePickerUITests.swift", "lineNumber": 115}}]
        proc = self._run_step(UI_STEP,
                              UI_CLASSES="ConnectionSetupUITests,ProfilePickerUITests",
                              STUB_FAIL_FIRST_N=1, STUB_RESULT_DOC=json.dumps(doc))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(len(self._invocations()), 2)
        self.assertIn("-only-testing:ConduitUITests/ProfilePickerUITests", self._invocations()[1])
        self.assertNotIn("-only-testing:ConduitUITests/ConnectionSetupUITests", self._invocations()[1])
        self.assertNotIn("retaining entire selection", proc.stderr)

    def test_lossy_extraction_retains_the_entire_retry_selection(self):
        for extra in (
            {"nodeType": "Test Case", "name": "System Failures", "result": "Failed"},
            {"nodeType": "Runner Failure", "name": "Unattributed", "result": "Failed"},
            {"nodeType": "Test Suite", "name": "System Failures", "result": "Failed", "children": []},
        ):
            doc = json.loads(self._result_doc(["ProfilePickerUITests"]))
            doc["testNodes"][0]["children"][0]["children"].append(extra)
            proc = self._run_step(UI_STEP,
                                  UI_CLASSES="ConnectionSetupUITests,ProfilePickerUITests",
                                  STUB_FAIL_FIRST_N=1, STUB_RESULT_DOC=json.dumps(doc))
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertEqual(self._invocations()[1].count("-only-testing:ConduitUITests/"), 2,
                             "unknown/orphan failures may not disappear into a narrowed retry")
            self.assertIn("retaining entire selection", proc.stderr)

    def test_ui_smoke_still_retries_when_no_class_level_line_was_logged(self):
        # The failure can happen before any suite finishes (the app dies at
        # launch). The step must still reach the retry and its diagnostic
        # instead of aborting on grep's non-zero status under `pipefail`.
        proc = self._run_step(UI_STEP,
                              UI_CLASSES="ConnectionSetupUITests,ProfilePickerUITests",
                              STUB_FAIL_FIRST_N=1, STUB_SILENT_FAIL=1)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(len(self._invocations()), 2, "the retry must still run")
        self.assertEqual(self._invocations()[1].count("-only-testing:ConduitUITests/"), 2)

    def test_ui_smoke_fails_when_the_targeted_retry_also_fails(self):
        proc = self._run_step(UI_STEP,
                              UI_CLASSES="ConnectionSetupUITests,ProfilePickerUITests",
                              STUB_FAIL_FIRST_N=99,
                              STUB_FLAKE_CLASS="ConnectionSetupUITests")
        self.assertNotEqual(proc.returncode, 0,
                            "a failure that survives the retry must fail the job")
        self.assertEqual(len(self._invocations()), 2,
                         "one retry only - never rerun-until-green")
        self.assertIn("failed again on the targeted retry",
                      proc.stdout + proc.stderr)

    def test_ui_smoke_refuses_an_empty_selection(self):
        proc = self._run_step(UI_STEP, UI_CLASSES="")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self._invocations(), [])
        self.assertIn("refusing to run unfiltered", proc.stdout + proc.stderr)

    # --- the extracted scripts must be the ones the workflow ships ----------

    def test_prepare_step_survives_without_a_ci_lib_environment(self):
        """The prepare step must set ci-lib.sh's LOG_DIR itself.

        `bounded_run` writes through `$LOG_DIR`; with it unset, every probe dies
        on an unbound variable, `wait_for_destination_device` then spins its full
        180s budget and both smoke jobs fail before running a single test - which
        is exactly what the first hosted run of this shape did.
        """
        path = os.path.join(self.tmp, "prepare.sh")
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("bash scripts/ci-prepare-smoke.sh\n")
        gh_env = os.path.join(self.tmp, "github_env")
        env = self._env(SIMULATOR_NAME="iPhone 17 Pro",
                        DESTINATION_SETTLE_TIMEOUT_S="5")
        env.pop("DESTINATION", None)
        env.pop("LOG_DIR", None)
        env["GITHUB_ENV"] = gh_env
        # The step resolves ci-lib.sh relative to the repo root, and writes its
        # probe logs under ci-lane/ (gitignored); leave the tree as we found it.
        lane_dir = os.path.join(REPO_ROOT, "ci-lane")
        pre_existing = os.path.isdir(lane_dir)
        try:
            proc = subprocess.run([self.bash, path], cwd=REPO_ROOT, env=env,
                                  capture_output=True, text=True)
        finally:
            if not pre_existing:
                shutil.rmtree(lane_dir, ignore_errors=True)
        output = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, output)
        self.assertNotIn("unbound variable", output)
        with open(gh_env, encoding="utf-8") as fh:
            self.assertIn("DESTINATION=", fh.read(),
                          "the step must export the destination the run steps use")

    def test_extracted_unit_step_reads_its_classes_from_the_plan_output(self):
        script = _step_script(UNIT_STEP)
        self.assertIn('"$UNIT_CLASSES"', script)
        self.assertIn("UNIT_BATCH_SIZE", script)
        self.assertIn('-destination "$DESTINATION"', script,
                      "the destination must be the one the prepare step pinned")
        self.assertNotIn("-test-iterations", script)
        self.assertNotIn("-retry-tests-on-failure", script,
                         "a genuine assertion must fail the job, not be retried")

    def test_shipped_smoke_selection_matches_the_documented_split(self):
        """The curated file and the plan output must agree, so the workflow's
        unit-csv/ui-csv outputs are the ones this suite exercises."""
        proc = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS_DIR, "plan-tests.py"),
             "smoke", "--repo-root", REPO_ROOT, "--suite",
             os.path.join(SCRIPTS_DIR, "smoke-suite.json"), "--out",
             os.path.join(self.tmp, "smoke.json")],
            capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        with open(os.path.join(self.tmp, "smoke.json"), encoding="utf-8") as fh:
            selection = json.load(fh)
        self.assertEqual(selection["unit_csv"].split(","), selection["unit"])
        self.assertEqual(selection["ui_csv"].split(","), selection["ui"])
        self.assertEqual(selection["unit_csv"].count(",") + 1, len(selection["unit"]))
        # Size is policy, not taste (docs/CI.md): seven unit classes is exactly
        # one 7-class invocation, and one test-host launch costs ~12 minutes on a
        # hosted runner, so an eighth class silently buys a whole invocation.
        self.assertEqual(
            len(selection["unit"]), 7,
            "the hosted selection is one class per risk area - growing it adds a "
            "whole xcodebuild invocation, not just one class")
        self.assertEqual(len(selection["ui"]), 2)


if __name__ == "__main__":
    unittest.main()
