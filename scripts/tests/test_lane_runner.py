"""Runner for the bash lane-runner state-machine tests.

The assertions live in scripts/tests/test_lane_runner.sh; this wrapper makes
them part of the standard unittest discovery run (ubuntu CI plan job and
macOS). Skipped on platforms without bash.
"""

import os
import subprocess
import shutil
import unittest

from _util import SCRIPTS_DIR

SCRIPT = os.path.join(SCRIPTS_DIR, "tests", "test_lane_runner.sh")


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "bash is required to exercise the lane runner")
class LaneRunnerScriptTests(unittest.TestCase):
    def test_lane_runner_state_machine(self):
        proc = subprocess.run(["bash", SCRIPT], capture_output=True,
                              text=True, timeout=300)
        if proc.returncode != 0:
            self.fail("lane-runner state machine test failed:\n"
                      + proc.stdout[-4000:] + proc.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
