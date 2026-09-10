"""Runner for the bash lane-runner state-machine tests.

The assertions live in scripts/tests/test_lane_runner.sh; this wrapper makes
them part of the standard unittest discovery run. Skipped on platforms
without bash, and when CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS=1 (the plan job
sets it: the state-machine suite is minutes-long, so it runs in the
dedicated self-test job instead of delaying planning and the macOS build).

Measured cost: ~3.5-4 minutes wall on macOS with the harness's 1s
xcodebuild poll cadence (124 assertions over 25 lane states, including
watchdog kills of synthetic hangs at 2-6s budgets); expect similar or a
little slower on hosted ubuntu. The subprocess cap below must stay larger
than that measured runtime but SMALLER than the self-test job's own GitHub
timeout, so this suite can always report its own failure before GitHub
kills the job: per-case watchdogs (<= 6s) < this cap < job timeout.
"""

import os
import subprocess
import shutil
import unittest

from _util import SCRIPTS_DIR

SCRIPT = os.path.join(SCRIPTS_DIR, "tests", "test_lane_runner.sh")


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "bash is required to exercise the lane runner")
@unittest.skipIf(os.environ.get("CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS") == "1",
                 "bash meta-suites run in the dedicated self-test job")
class LaneRunnerScriptTests(unittest.TestCase):
    def test_lane_runner_state_machine(self):
        proc = subprocess.run(["bash", SCRIPT], capture_output=True,
                              text=True, timeout=480)
        if proc.returncode != 0:
            self.fail("lane-runner state machine test failed:\n"
                      + proc.stdout[-4000:] + proc.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
