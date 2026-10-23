"""Regression coverage for scripts/stamp-plugin-version.py (the Conduit
target's archive-time plugin version)."""

import io
import os
import plistlib
import tempfile
import unittest
from contextlib import redirect_stdout

from _util import load_module

stamp = load_module("stamp_plugin_version", "stamp-plugin-version.py")


class StampPluginVersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = os.path.join(self.directory.name, "Info.plist")

    def write(self, fmt):
        with open(self.path, "wb") as handle:
            plistlib.dump({"CFBundleVersion": "230"}, handle, fmt=fmt)

    def run_stamp(self, action, fetch):
        out = io.StringIO()
        with redirect_stdout(out):
            code = stamp.main(["--info-plist", self.path], environ={"ACTION": action}, fetch=fetch)
        self.assertEqual(code, 0)
        return out.getvalue()

    def read(self):
        with open(self.path, "rb") as handle:
            data = handle.read()
        return data, plistlib.loads(data)

    def test_an_archive_records_mains_version_in_the_plists_own_format(self):
        for fmt in (plistlib.FMT_BINARY, plistlib.FMT_XML):
            self.write(fmt)
            self.run_stamp("install", lambda: "name: conduit_push\nversion: 0.65.2  # bumped\n")
            data, info = self.read()
            self.assertEqual(info, {"CFBundleVersion": "230", stamp.KEY: "0.65.2"})
            self.assertEqual(data.startswith(b"bplist"), fmt == plistlib.FMT_BINARY)

    def test_the_version_reads_as_the_app_reads_it(self):
        self.assertEqual(stamp.plugin_version('  version: "0.65.2"\n'), "0.65.2")
        self.assertEqual(stamp.plugin_version("version: '0.7'  # note\n"), "0.7")

    def test_the_app_reads_the_key_this_writes(self):
        swift = os.path.join(os.path.dirname(stamp.__file__), "..", "Conduit", "Services",
                             "NotifierPluginStatus.swift")
        with open(swift, encoding="utf-8") as handle:
            self.assertIn(f'forInfoDictionaryKey: "{stamp.KEY}"', handle.read())

    def test_a_run_or_ci_build_is_left_alone(self):
        self.write(plistlib.FMT_XML)
        self.run_stamp("build", lambda: self.fail("a build must not ask GitHub"))
        self.assertNotIn(stamp.KEY, self.read()[1])

    def test_github_out_of_reach_warns_and_still_archives(self):
        self.write(plistlib.FMT_XML)

        def offline():
            raise OSError("no route")

        self.assertIn("warning:", self.run_stamp("install", offline))
        self.assertNotIn(stamp.KEY, self.read()[1])

    def test_an_unreadable_version_warns(self):
        self.write(plistlib.FMT_XML)
        self.assertIn("warning:", self.run_stamp("install", lambda: "version: next\n"))
        self.assertNotIn(stamp.KEY, self.read()[1])


if __name__ == "__main__":
    unittest.main()
