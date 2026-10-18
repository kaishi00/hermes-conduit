"""Integration coverage for the hosted test jobs' bash run steps.

The test steps' load-bearing behaviour - the empty-selection guard, the
failure annotations, the UI smoke job's one targeted retry, and the nightly
unit shards' bounded sequential batching that runs every batch past a failed
one - exists only inside `.github/workflows/ci.yml` (the smoke job) and
`.github/workflows/nightly.yml` (the unit shards). This module extracts those
`run:` bodies from the workflows and executes them against a stub
`xcodebuild`, so a broken loop or a guard that stopped guarding fails the
CI-tooling suite instead of the first run that touches the workflow.

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
NIGHTLY = os.path.join(REPO_ROOT, ".github", "workflows", "nightly.yml")

# The nightly unit shards' batch runner (CI v4's PR unit shards).
UNIT_STEP = "Run this shard's unit classes"
# The smoke job's two test steps (ci.yml).
UNIT_SMOKE_STEP = "Run the curated unit smoke classes"
UI_STEP = "Run the curated UI smoke suite"

STEP_WORKFLOWS = {UNIT_STEP: NIGHTLY, UNIT_SMOKE_STEP: WORKFLOW, UI_STEP: WORKFLOW}

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
  if [ -n "${STUB_FAILURE_OUTPUT:-}" ]; then
    printf '%s\\n' "$STUB_FAILURE_OUTPUT"
  fi
  if [ "${STUB_SILENT_FAIL:-0}" != "1" ]; then
    printf "Test Suite '%s' failed\\n" "${STUB_FLAKE_CLASS:-StubFailingTests}"
  fi
  exit 1
fi
if [ -n "${STUB_SUCCESS_OUTPUT:-}" ]; then
  printf '%s\\n' "$STUB_SUCCESS_OUTPUT"
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
    workflow = STEP_WORKFLOWS[step_name]
    with open(workflow, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip() == "- name: " + step_name:
            start = i
            break
    if start is None:
        raise AssertionError("step {0!r} not found in {1}".format(
            step_name, os.path.basename(workflow)))
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
        if not os.path.exists(WORKFLOW) or not os.path.exists(NIGHTLY):
            self.skipTest("ci.yml or nightly.yml not present")
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
                     "UI_CLASSES", "STUB_RESULT_DOC", "STUB_FAILURE_OUTPUT",
                     "STUB_SUCCESS_OUTPUT", "UNIT_SMOKE_LOG",
                     "UNIT_TEST_ALLOWANCE_S"):
            env.pop(name, None)
        # The unit step keeps each batch's log under RUNNER_TEMP.
        env["RUNNER_TEMP"] = self.tmp
        # The unit smoke step's log (ci-lane/ in the workflow).
        env["UNIT_SMOKE_LOG"] = os.path.join(self.tmp, "lane", "unit-smoke.log")
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

    # --- smoke job: the curated unit classes, one invocation -----------------

    SMOKE_UNIT_CLASSES = ("AppStateForegroundLifecycleTests,ProfileDiscoveryTests,"
                          "BotModeTests,HermesClientTests,ComposerDraftStoreTests,"
                          "MarkdownLargeDocumentTests,NotificationDashboardOwnershipTests")

    def test_unit_smoke_runs_the_curated_classes_in_one_invocation(self):
        proc = self._run_step(UNIT_SMOKE_STEP, UNIT_CLASSES=self.SMOKE_UNIT_CLASSES)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        invocations = self._invocations()
        self.assertEqual(len(invocations), 1, invocations)
        self.assertEqual(invocations[0].count("-only-testing:ConduitTests/"), 7)
        for flag in ("test-without-building", "-parallel-testing-enabled NO",
                     "-collect-test-diagnostics never", "-test-timeouts-enabled YES",
                     "-default-test-execution-time-allowance 180",
                     "-destination platform=iOS Simulator,id=STUB-UDID,arch=arm64"):
            self.assertIn(flag, invocations[0])
        self.assertTrue(os.path.exists(os.path.join(self.tmp, "lane", "unit-smoke.log")),
                        "the invocation's output is kept for the diagnostics upload")

    def test_unit_smoke_failure_fails_once_without_retry_and_annotates(self):
        output = "\n".join([
            "Test Case '-[ConduitTests.BotModeTests testA]' started.",
            "/w/ConduitTests/BotModeTests.swift:12: error: -[ConduitTests.BotModeTests testA] :"
            " XCTAssertEqual failed: (\"100%\") is not equal to (\"0%\")",
            "Test Case '-[ConduitTests.BotModeTests testA]' failed (0.010 seconds).",
            "Failing tests:",
            "\tBotModeTests.testA()",
            "",
            "** TEST EXECUTE FAILED **",
        ])
        proc = self._run_step(UNIT_SMOKE_STEP, UNIT_CLASSES=self.SMOKE_UNIT_CLASSES,
                              STUB_FAIL_FIRST_N=1, STUB_FAILURE_OUTPUT=output)
        self.assertNotEqual(proc.returncode, 0, "a unit smoke failure must fail the step")
        self.assertEqual(len(self._invocations()), 1,
                         "a unit failure is a test bug: no retry of any kind")
        notes = [line for line in proc.stdout.splitlines()
                 if line.startswith("::error title=unit smoke failures::")]
        self.assertEqual(len(notes), 1, proc.stdout)
        self.assertEqual(notes[0].split("::", 2)[2].split("%0A"), [
            "Failing tests:",
            "\tBotModeTests.testA()",
            "/w/ConduitTests/BotModeTests.swift:12: error: -[ConduitTests.BotModeTests testA] :"
            " XCTAssertEqual failed: (\"100%25\") is not equal to (\"0%25\")",
            "Test Case '-[ConduitTests.BotModeTests testA]' failed (0.010 seconds).",
        ])
        self.assertRegex(proc.stdout, r"(?m)^::notice title=unit smoke took [0-9]+s::"
                         r"its output has no test totals$")

    def test_unit_smoke_failure_without_test_output_still_fails(self):
        proc = self._run_step(UNIT_SMOKE_STEP, UNIT_CLASSES=self.SMOKE_UNIT_CLASSES,
                              STUB_FAIL_FIRST_N=1, STUB_SILENT_FAIL=1)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("::error::unit smoke failed:", proc.stdout)

    def test_unit_smoke_posts_its_timing(self):
        output = "\n".join([
            "Test Suite 'Selected tests' passed at 2026-10-15 23:31:00.000.",
            "\t Executed 391 tests, with 0 failures (0 unexpected) in 96.728 (97.012) seconds",
            "** TEST EXECUTE SUCCEEDED **",
        ])
        proc = self._run_step(UNIT_SMOKE_STEP, UNIT_CLASSES=self.SMOKE_UNIT_CLASSES,
                              STUB_SUCCESS_OUTPUT=output)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertRegex(proc.stdout, r"(?m)^::notice title=unit smoke took [0-9]+s::"
                         r"391 tests ran for 97s of it$")

    def test_unit_smoke_refuses_an_empty_selection_or_destination(self):
        proc = self._run_step(UNIT_SMOKE_STEP, UNIT_CLASSES="")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self._invocations(), [],
                         "nothing may be invoked without a class filter")
        self.assertIn("refusing to run unfiltered", proc.stdout + proc.stderr)
        proc = self._run_step(UNIT_SMOKE_STEP, UNIT_CLASSES=self.SMOKE_UNIT_CLASSES,
                              DESTINATION="")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self._invocations(), [])
        self.assertIn("DESTINATION is empty", proc.stdout)

    # --- nightly unit shards: bounded sequential batches --------------------

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
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES=self._classes("Unit", 92))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(len(self._invocations()), 3, "92 classes / at most 45 per batch")
        self.assertIn("in 3 batch(es) of at most 31 (cap 45)", proc.stdout)

    def test_unit_smoke_splits_the_remainder_evenly(self):
        # Every invocation pays the same fixed cost, so the fewest batches the
        # cap allows, of even size, instead of full batches and a small rest.
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES=self._classes("Unit", 20),
                              UNIT_BATCH_SIZE=8)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        sized = [i.count("-only-testing:ConduitTests/") for i in self._invocations()]
        self.assertEqual(sized, [7, 7, 6], sized)

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

    def test_a_failed_unit_batch_annotates_its_failing_cases(self):
        # The job log API returns only a job's last 5,000 lines, which an early
        # batch's failures do not reach; its annotations always can be read.
        output = "\n".join([
            "Test Case '-[ConduitTests.Unit0Tests testA]' started.",
            "/w/ConduitTests/Unit0Tests.swift:12: error: -[ConduitTests.Unit0Tests testA] :"
            " XCTAssertEqual failed: (\"100%\") is not equal to (\"0%\")",
            "Test Case '-[ConduitTests.Unit0Tests testA]' failed (0.010 seconds).",
            "Test Case '-[ConduitTests.Unit0Tests testB]' passed (0.001 seconds).",
            "Failing tests:",
            "\tUnit0Tests.testA()",
            "",
            "** TEST EXECUTE FAILED **",
        ])
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES=self._classes("Unit", 4),
                              UNIT_BATCH_SIZE=2, STUB_FAIL_FIRST_N=1,
                              STUB_FAILURE_OUTPUT=output)
        self.assertNotEqual(proc.returncode, 0)
        notes = [line for line in proc.stdout.splitlines()
                 if line.startswith("::error title=unit batch 1 failures::")]
        self.assertEqual(len(notes), 1, proc.stdout)
        # xcodebuild's complete list first, then the messages.
        self.assertEqual(notes[0].split("::", 2)[2].split("%0A"), [
            "Failing tests:",
            "\tUnit0Tests.testA()",
            "/w/ConduitTests/Unit0Tests.swift:12: error: -[ConduitTests.Unit0Tests testA] :"
            " XCTAssertEqual failed: (\"100%25\") is not equal to (\"0%25\")",
            "Test Case '-[ConduitTests.Unit0Tests testA]' failed (0.010 seconds).",
        ])
        self.assertNotIn("unit batch 2 failures", proc.stdout)
        self.assertIn("Test Case '-[ConduitTests.Unit0Tests testB]' passed", proc.stdout,
                      "the batch's output still reaches the job log")

    def test_each_unit_batch_posts_its_timing(self):
        # The job log API cuts off an early batch's lines; its notice stays.
        output = "\n".join([
            "Test Suite 'Unit0Tests' passed at 2026-10-15 23:30:00.000.",
            "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.010 (0.020) seconds",
            "Test Suite 'Selected tests' passed at 2026-10-15 23:31:00.000.",
            "\t Executed 1140 tests, with 0 failures (0 unexpected) in 196.728 (197.012) seconds",
            "** TEST EXECUTE SUCCEEDED **",
        ])
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES=self._classes("Unit", 4),
                              UNIT_BATCH_SIZE=2, STUB_SUCCESS_OUTPUT=output)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        notes = [line for line in proc.stdout.splitlines()
                 if line.startswith("::notice title=unit batch ")]
        self.assertEqual(len(notes), 2, proc.stdout)
        for number, note in enumerate(notes, start=1):
            self.assertRegex(note, r"^::notice title=unit batch {0} took [0-9]+s::"
                             r"1140 tests ran for 197s of it$".format(number))

    def test_a_failed_unit_batch_posts_its_timing_too(self):
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES=self._classes("Unit", 2),
                              UNIT_BATCH_SIZE=2, STUB_FAIL_FIRST_N=1)
        self.assertNotEqual(proc.returncode, 0)
        self.assertRegex(proc.stdout, r"(?m)^::notice title=unit batch 1 took [0-9]+s::"
                         r"its output has no test totals$")

    def _failing_list_annotation(self, count):
        output = "\n".join(["Failing tests:"]
                           + ["\tUnit0Tests.test{0}()".format(n) for n in range(count)]
                           + ["", "** TEST EXECUTE FAILED **"])
        proc = self._run_step(UNIT_STEP, UNIT_CLASSES=self._classes("Unit", 2),
                              UNIT_BATCH_SIZE=2, STUB_FAIL_FIRST_N=1,
                              STUB_FAILURE_OUTPUT=output)
        notes = [line for line in proc.stdout.splitlines()
                 if line.startswith("::error title=unit batch 1 failures::")]
        self.assertEqual(len(notes), 1, proc.stdout)
        return notes[0].split("::", 2)[2].split("%0A")

    def test_a_long_failing_list_is_cut_with_a_marker(self):
        lines = self._failing_list_annotation(45)
        self.assertEqual(lines[:2], ["Failing tests:", "\tUnit0Tests.test0()"])
        self.assertEqual(len(lines), 41)
        self.assertEqual(lines[-1], "\t(more failing tests in the job log)")

    def test_a_failing_list_within_the_cap_is_whole(self):
        lines = self._failing_list_annotation(39)
        self.assertEqual(lines[-1], "\tUnit0Tests.test38()")
        self.assertEqual(len(lines), 40)

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
        self.assertIn("batch(es) of at most 8 (cap 8)", proc.stdout)

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

    def _retry_with_case_children(self, children, failed_class_children=True):
        """Fail ProfilePickerUITests and hang `children` under its case (or
        under ConnectionSetupUITests' passing case); return the step."""
        doc = json.loads(self._result_doc(["ProfilePickerUITests"]))
        suites = doc["testNodes"][0]["children"][0]["children"]
        target = suites[1] if failed_class_children else suites[0]
        target["children"][0]["children"] = children
        return self._run_step(UI_STEP,
                              UI_CLASSES="ConnectionSetupUITests,ProfilePickerUITests",
                              STUB_FAIL_FIRST_N=1, STUB_RESULT_DOC=json.dumps(doc))

    def test_ui_failure_diagnostics_still_retry_only_the_failed_class(self):
        # What a real failed UI case carries: the failure message (with its
        # own result and source reference) and the screenshot attachment.
        proc = self._retry_with_case_children([
            {"nodeType": "Failure Message", "name": "ProfilePickerUITests.swift:119: XCTAssertTrue failed",
             "result": "Failed",
             "children": [{"nodeType": "Source Code Reference", "name": "ProfilePickerUITests.swift:119"}]},
            {"nodeType": "Attachment", "name": "Screenshot at failure"},
            {"nodeType": "Runtime Warning", "name": "Publishing changes from background threads"},
        ])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        retry = self._invocations()[1]
        self.assertIn("-only-testing:ConduitUITests/ProfilePickerUITests", retry)
        self.assertNotIn("-only-testing:ConduitUITests/ConnectionSetupUITests", retry)
        self.assertNotIn("retaining entire selection", proc.stderr)

    def test_a_passing_case_may_carry_a_runtime_warning(self):
        proc = self._retry_with_case_children(
            [{"nodeType": "Runtime Warning", "name": "Main thread checker"}],
            failed_class_children=False)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn("-only-testing:ConduitUITests/ConnectionSetupUITests", self._invocations()[1])
        self.assertNotIn("retaining entire selection", proc.stderr)

    def test_unknown_or_inconsistent_case_children_retain_the_entire_selection(self):
        for children, on_failed_class in (
            ([{"nodeType": "Repetition", "name": "Repetition 1", "result": "Failed"}], True),
            ([{"nodeType": "Test Case", "name": "hidden()", "result": "Failed"}], True),
            ([{"nodeType": "Attachment", "name": "x",
               "children": [{"nodeType": "Test Case Run", "name": "run", "result": "Failed"}]}], True),
            ([{"nodeType": "Failure Message", "name": "XCTFail", "result": "Failed"}], False),
            ([{"nodeType": "Failure Message", "name": ""}], True),
            ([{"nodeType": "Attachment", "name": "x", "result": "Expected Failure"}], True),
        ):
            proc = self._retry_with_case_children(children, on_failed_class)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertEqual(self._invocations()[1].count("-only-testing:ConduitUITests/"), 2,
                             "children {!r} must keep the whole selection".format(children))
            self.assertIn("retaining entire selection", proc.stderr)

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
        for step in (UNIT_STEP, UNIT_SMOKE_STEP):
            script = _step_script(step)
            self.assertIn('"$UNIT_CLASSES"', script, step)
            self.assertIn('-destination "$DESTINATION"', script,
                          "the destination must be the one the prepare step pinned")
            self.assertNotIn("-test-iterations", script, step)
            self.assertNotIn("-retry-tests-on-failure", script,
                             "a genuine assertion must fail the job, not be retried")
        self.assertIn("UNIT_BATCH_SIZE", _step_script(UNIT_STEP))
        self.assertNotIn("smoke-retry-classes.py", _step_script(UNIT_SMOKE_STEP))

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
