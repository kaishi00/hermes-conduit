"""Contract for Conduit Dev (scripts/mac-dev-build.sh): the overlay keeps it a
separate, extension-free app that can't take the installed Conduit's data,
pushes or links, and the script, overlay and export options agree."""

import os
import plistlib
import unittest

from _util import SCRIPTS_DIR

REPO_ROOT = os.path.dirname(SCRIPTS_DIR)
MAC_DEV = os.path.join(SCRIPTS_DIR, "mac-dev")


def _read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


class MacDevBuildContractTests(unittest.TestCase):
    def test_overlay_is_a_separate_app_with_no_extensions(self):
        overlay = _read(os.path.join(MAC_DEV, "project.yml"))
        self.assertIn("- path: project.yml", overlay)
        self.assertIn("name: ConduitDev", overlay)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: com.milim.relay.dev", overlay)
        self.assertIn("CONDUIT_URL_SCHEME: conduit-dev", overlay)
        self.assertIn("CODE_SIGN_ENTITLEMENTS: scripts/mac-dev/ConduitDev.entitlements", overlay)
        self.assertIn("dependencies:REPLACE:", overlay)
        self.assertNotIn("- target:", overlay)

    def test_entitlements_are_empty(self):
        with open(os.path.join(MAC_DEV, "ConduitDev.entitlements"), "rb") as handle:
            self.assertEqual(plistlib.load(handle), {})

    def test_url_scheme_is_a_build_setting(self):
        self.assertIn("<string>$(CONDUIT_URL_SCHEME)</string>", _read(os.path.join(REPO_ROOT, "Conduit", "Info.plist")))
        self.assertIn("CONDUIT_URL_SCHEME: conduit\n", _read(os.path.join(REPO_ROOT, "project.yml")))

    def test_export_team_matches_the_project(self):
        with open(os.path.join(MAC_DEV, "ExportOptions.plist"), "rb") as handle:
            options = plistlib.load(handle)
        self.assertEqual(options["method"], "debugging")
        team = options["teamID"]
        self.assertIn(f"DEVELOPMENT_TEAM: {team}", _read(os.path.join(REPO_ROOT, "project.yml")))

    def test_script_uses_the_overlay_and_its_files(self):
        script = _read(os.path.join(SCRIPTS_DIR, "mac-dev-build.sh"))
        self.assertIn("--spec scripts/mac-dev/project.yml --project-root . --project .", script)
        self.assertIn("-project ConduitDev.xcodeproj", script)
        self.assertIn("-exportOptionsPlist scripts/mac-dev/ExportOptions.plist", script)
        self.assertIn('application id "com.milim.relay.dev"', script)


if __name__ == "__main__":
    unittest.main()
