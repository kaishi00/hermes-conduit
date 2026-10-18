"""Regression coverage for scripts/check-plugin-version.py."""

import os
import tempfile
import unittest

from _util import SCRIPTS_DIR, load_module

check = load_module("check_plugin_version", "check-plugin-version.py")

SWIFT = 'struct S {\n    static let recommendedVersion = "{0}"\n}\n'


class CheckPluginVersionTests(unittest.TestCase):
    def run_check(self, recommended, plugin_yaml):
        with tempfile.TemporaryDirectory() as root:
            swift = os.path.join(root, check.SWIFT_FILE)
            os.makedirs(os.path.dirname(swift))
            with open(swift, "w", encoding="utf-8") as fh:
                fh.write(SWIFT.replace("{0}", recommended))
            yaml_path = os.path.join(root, "plugin.yaml")
            with open(yaml_path, "w", encoding="utf-8") as fh:
                fh.write(plugin_yaml)
            return check.main(["--repo-root", root, "--plugin-yaml", yaml_path])

    def test_matching_versions_pass(self):
        self.assertEqual(self.run_check("0.41.0", "name: conduit_push\nversion: 0.41.0\n"), 0)

    def test_a_recommended_version_behind_the_plugin_passes(self):
        # Conduit offers the plugin's own latest version; this is only the floor.
        self.assertEqual(self.run_check("0.29.0", "version: 0.41.0\n"), 0)

    def test_recommended_ahead_of_the_plugin_fails(self):
        self.assertEqual(self.run_check("0.42.0", "version: 0.41.0\n"), 1)

    def test_compare_is_numeric_and_says_which_way(self):
        self.assertIsNone(check.compare("0.10.0", "0.10.0"))
        self.assertIn("behind", check.compare("0.9.0", "0.10.0"))
        self.assertIn("ahead of", check.compare("0.10.0", "0.9.0"))

    def test_missing_trailing_parts_count_as_zero(self):
        self.assertIsNone(check.compare("0.41", "0.41.0"))
        self.assertIn("behind", check.compare("0.41", "0.41.1"))

    def test_unreadable_versions_fail_cleanly(self):
        self.assertIn("Can't compare", check.compare("0.41.x", "0.41.0"))
        self.assertEqual(self.run_check("junk", "version: 0.41.0\n"), 1)
        # An unreadable version whose message happens to say "behind" still fails.
        self.assertEqual(self.run_check("behind", "version: 0.41.0\n"), 1)

    def test_reads_quoted_yaml_versions(self):
        self.assertEqual(check.plugin_version('manifest_version: 1\nversion: "0.41.0"\n'), "0.41.0")
        self.assertIsNone(check.plugin_version("manifest_version: 1\n"))

    def test_reads_the_real_swift_constant(self):
        root = os.path.dirname(SCRIPTS_DIR)
        with open(os.path.join(root, check.SWIFT_FILE), encoding="utf-8") as fh:
            self.assertIsNotNone(check.recommended_version(fh.read()))


if __name__ == "__main__":
    unittest.main()
