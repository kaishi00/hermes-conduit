"""Runner for the bash destination-readiness lookup tests.

The assertions live in scripts/tests/test_simulator_destination.sh; this
wrapper makes them part of the standard unittest discovery run (ubuntu CI
plan job and macOS). Skipped on platforms without bash.

The harness exercises scripts/ci-lib.sh's OS-qualified simulator lookup
(os_version_matches, simruntime_version, simulator_udid) against a fixture
`simctl list devices available -j` payload - no simulator, no real Xcode.
Its simulator_udid() fixture cases need jq and are skipped, not failed, on
hosts without it (the pure-bash matcher cases always run).
"""

import os
import subprocess
import shutil
import unittest

from _util import SCRIPTS_DIR

SCRIPT = os.path.join(SCRIPTS_DIR, "tests", "test_simulator_destination.sh")


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "bash is required to exercise the destination lookup")
@unittest.skipIf(os.environ.get("CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS") == "1",
                 "bash meta-suites run in the dedicated self-test job")
class SimulatorDestinationScriptTests(unittest.TestCase):
    def test_destination_lookup(self):
        proc = subprocess.run(["bash", SCRIPT], capture_output=True,
                              text=True, timeout=300)
        if proc.returncode != 0:
            self.fail("destination lookup test failed:\n"
                      + proc.stdout[-4000:] + proc.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
