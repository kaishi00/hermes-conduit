"""Runner for the local-gate shell integration suite.

The assertions live in scripts/tests/test_local_ci_gate.sh; this wrapper makes
them part of the standard unittest discovery run. The suite drives the real
scripts/local-ci-gate.sh against stub xcodegen/xcodebuild/xcrun binaries in a
throwaway repository, so it needs no Xcode and no macOS - it runs on the Linux
CI job too.

Measured cost: minutes, not seconds - ~28 stubbed gate runs, each paying git
worktree and subprocess overhead even with GATE_SLEEP_SCALE=0 (the suite sets
it, so the gate's wedge-mitigation sleeps collapse; the synthetic hang cases
use Python time.sleep inside a fake script and are unaffected). It grew from
~200s to ~330s on our Mac when the gate gained its two-worker, mode and
per-worker-evidence cases - the coverage is the point, so the cap and the job
ceiling moved rather than the cases. The suite honours
CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS (the plan job sets it: this suite must never
delay planning or risk the plan job's 10-minute ceiling) and runs in the
dedicated self-test job instead.

The subprocess cap below must stay larger than the measured runtime but
SMALLER than what the self-test job's own GitHub ceiling leaves after the other
meta-suites (~4.0 minutes): suites < this cap < job timeout, so this suite can
always report its own failure before GitHub kills the job.
"""

import os
import shutil
import subprocess
import unittest

from _util import SCRIPTS_DIR

SCRIPT = os.path.join(SCRIPTS_DIR, "tests", "test_local_ci_gate.sh")


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"),
                     "bash is required to exercise the gate script")
@unittest.skipUnless(shutil.which("git"), "git is required by the gate")
@unittest.skipIf(os.environ.get("CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS") == "1",
                 "bash meta-suites run in the dedicated self-test job")
class LocalGateScriptTests(unittest.TestCase):
    def test_local_gate_integration_suite(self):
        proc = subprocess.run(["bash", SCRIPT], capture_output=True,
                              text=True, timeout=600)
        if proc.returncode != 0:
            self.fail("local-gate integration suite failed:\n"
                      + proc.stdout[-6000:] + proc.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
