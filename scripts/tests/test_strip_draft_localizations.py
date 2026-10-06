"""Regression coverage for scripts/strip-draft-localizations.py (the Conduit
target's last build phase)."""

import importlib.util
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(SCRIPTS_DIR, "strip-draft-localizations.py")
SPEC = importlib.util.spec_from_file_location("strip_draft_localizations", SCRIPT)
strip_drafts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(strip_drafts)


class StripDraftLocalizationsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.bundle = os.path.join(self.directory.name, "Conduit.app")
        for name in ("Base.lproj", "en.lproj", "ja.lproj", "pt-BR.lproj",
                     "zh-Hans.lproj"):
            os.makedirs(os.path.join(self.bundle, name))
            with open(os.path.join(self.bundle, name, "Localizable.strings"), "w") as handle:
                handle.write('"Hello" = "Hello";\n')
        with open(os.path.join(self.bundle, "ja.json"), "w") as handle:
            handle.write("{}")

    def write_info_plist(self, info):
        path = os.path.join(self.directory.name, "Info.plist")
        with open(path, "wb") as handle:
            plistlib.dump(info, handle)
        return path

    def contents(self):
        return sorted(os.listdir(self.bundle))

    def test_only_draft_lprojs_are_removed(self):
        removed = strip_drafts.strip(self.bundle, ["ja", "pt_br"])
        self.assertEqual(removed, ["ja.lproj", "pt-BR.lproj"])
        self.assertEqual(self.contents(),
                         ["Base.lproj", "en.lproj", "ja.json", "zh-Hans.lproj"])

    def test_no_drafts_leaves_the_bundle_alone(self):
        self.assertEqual(strip_drafts.strip(self.bundle, []), [])
        self.assertEqual(len(self.contents()), 6)

    def test_drafts_are_read_from_info_plist(self):
        path = self.write_info_plist({"ConduitDraftLanguages": ["ja"]})
        self.assertEqual(strip_drafts.draft_languages(path), ["ja"])
        path = self.write_info_plist({})
        self.assertEqual(strip_drafts.draft_languages(path), [])

    def test_a_malformed_draft_list_is_rejected(self):
        path = self.write_info_plist({"ConduitDraftLanguages": ["ja", ""]})
        with self.assertRaises(ValueError):
            strip_drafts.draft_languages(path)

    def test_command_line_strips_and_reports(self):
        plist = self.write_info_plist({"ConduitDraftLanguages": ["ja"]})
        result = subprocess.run(
            [sys.executable, SCRIPT, "--info-plist", plist, "--bundle", self.bundle],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("removed draft localization ja.lproj", result.stdout)
        self.assertNotIn("ja.lproj", self.contents())

    def test_command_line_fails_the_build_on_a_missing_bundle(self):
        plist = self.write_info_plist({"ConduitDraftLanguages": ["ja"]})
        missing = os.path.join(self.directory.name, "Missing.app")
        result = subprocess.run(
            [sys.executable, SCRIPT, "--info-plist", plist, "--bundle", missing],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"error: {missing}:", result.stdout)
        self.assertNotIn("Traceback", result.stderr)

    def test_command_line_refuses_to_strip_the_development_language(self):
        plist = self.write_info_plist({"ConduitDraftLanguages": ["ja", "EN"]})
        result = subprocess.run(
            [sys.executable, SCRIPT, "--info-plist", plist, "--bundle", self.bundle,
             "--development-language", "en"],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("development language 'en'", result.stdout)
        self.assertEqual(len(self.contents()), 6, "nothing is stripped")

    def test_command_line_refuses_to_strip_base(self):
        plist = self.write_info_plist({"ConduitDraftLanguages": ["ja", "base"]})
        result = subprocess.run(
            [sys.executable, SCRIPT, "--info-plist", plist, "--bundle", self.bundle],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Base.lproj holds unlocalized resources", result.stdout)
        self.assertEqual(len(self.contents()), 6, "nothing is stripped")

    def test_command_line_fails_the_build_on_a_corrupt_plist(self):
        plist = os.path.join(self.directory.name, "Info.plist")
        with open(plist, "w") as handle:
            handle.write('<?xml version="1.0"?><plist><dict>')
        result = subprocess.run(
            [sys.executable, SCRIPT, "--info-plist", plist, "--bundle", self.bundle],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("error:", result.stdout)
        self.assertNotIn("Traceback", result.stderr)

    def test_command_line_fails_the_build_on_a_bad_plist(self):
        plist = os.path.join(self.directory.name, "missing.plist")
        result = subprocess.run(
            [sys.executable, SCRIPT, "--info-plist", plist, "--bundle", self.bundle],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("error:", result.stdout)


if __name__ == "__main__":
    unittest.main()
