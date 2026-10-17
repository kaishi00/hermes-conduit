"""Regression coverage for scripts/check-card-schema.py."""

import os
import shutil
import tempfile
import unittest

from _util import SCRIPTS_DIR, load_module

check = load_module("check_card_schema", "check-card-schema.py")
ROOT = os.path.dirname(SCRIPTS_DIR)


class CheckCardSchemaTests(unittest.TestCase):
    def run_check(self, plugin_files):
        with tempfile.TemporaryDirectory() as plugin:
            for path, data in plugin_files.items():
                full = os.path.join(plugin, path)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                with open(full, "wb") as fh:
                    fh.write(data)
            return check.main(["--repo-root", ROOT, "--plugin-root", plugin])

    def copies(self):
        files = {}
        for name, plugin_path in check.COPIES.items():
            with open(os.path.join(ROOT, name), "rb") as fh:
                files[plugin_path] = fh.read()
        return files

    def test_identical_copies_pass(self):
        self.assertEqual(self.run_check(self.copies()), 0)

    def test_a_changed_schema_fails(self):
        files = self.copies()
        files["cards/card-schema.json"] += b" "
        self.assertEqual(self.run_check(files), 1)

    def test_a_file_missing_from_the_plugin_fails(self):
        files = self.copies()
        del files["cards/card-vectors.json"]
        self.assertEqual(self.run_check(files), 1)

    def test_compare_names_the_plugin_file(self):
        name = os.path.join("Conduit", "Cards", "card-schema.json")
        self.assertIsNone(check.compare(b"a", b"a", name))
        self.assertIn("cards/card-schema.json", check.compare(b"a", b"b", name))


if __name__ == "__main__":
    unittest.main()
