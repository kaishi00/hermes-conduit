"""Contracts for the CI-only Xcode scheme used by build-for-testing."""

import os
import unittest

from _util import SCRIPTS_DIR

REPO_ROOT = os.path.dirname(SCRIPTS_DIR)
PROJECT_SPEC = os.path.join(REPO_ROOT, "project.yml")
BUILD_SCRIPT = os.path.join(SCRIPTS_DIR, "ci-build-for-testing.sh")


class CISchemeContractTests(unittest.TestCase):
    def test_ci_scheme_disables_test_debugger_without_changing_local_scheme(self):
        with open(PROJECT_SPEC, encoding="utf-8") as fh:
            text = fh.read()

        marker = "  ConduitCI:\n"
        self.assertIn(marker, text)
        ci_scheme = text.split(marker, 1)[1]
        self.assertIn("    test:\n", ci_scheme)
        self.assertIn("      debugEnabled: false\n", ci_scheme)
        self.assertIn("        - ConduitTests\n", ci_scheme)
        self.assertIn("        - ConduitUITests\n", ci_scheme)

        # The normal local scheme remains XcodeGen's target-generated default;
        # CI gets a separate explicit scheme instead of changing developer
        # Cmd+U/debugger behavior globally.
        self.assertNotIn("  Conduit:\n    test:\n", text)

    def test_build_for_testing_defaults_to_ci_scheme_but_can_be_overridden(self):
        with open(BUILD_SCRIPT, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn('SCHEME="${SCHEME:-ConduitCI}"', text)
        self.assertIn('-scheme "$SCHEME"', text)


if __name__ == "__main__":
    unittest.main()
