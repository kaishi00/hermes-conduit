"""Regression coverage for scripts/l10n.py (catalog worksheets)."""

import json
import os
import tempfile
import unittest

from _util import load_module

l10n = load_module("l10n_tool", "l10n.py")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


class WorksheetTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(lambda: setattr(l10n, "REPO_ROOT", self.saved_root))
        self.saved_root = l10n.REPO_ROOT
        l10n.REPO_ROOT = self.root
        os.makedirs(os.path.join(self.root, "Conduit"))
        self.catalog_path = os.path.join(self.root, "Conduit", "Localizable.xcstrings")
        self.write({
            "sourceLanguage": "en",
            "version": "1.0",
            "strings": {
                "Hello": {"localizations": {"ja": unit("こんにちは")}},
                "Goodbye": {"localizations": {}},
                "%lld files": {"localizations": {
                    "en": {"variations": {"plural": {
                        "one": unit("%lld file"), "other": unit("%lld files")}}},
                    "ja": unit("%lld 件")}},
            },
        })

    def write(self, catalog):
        l10n.save(self.catalog_path, catalog)

    def read(self):
        return l10n.load(self.catalog_path)

    def entries(self, worksheet):
        return {item["key"]: item for item in worksheet["entries"]}

    def test_export_lists_what_a_language_lacks(self):
        worksheet = l10n.export("ja", include_all=False)
        self.assertEqual(set(self.entries(worksheet)), {"Goodbye"})
        worksheet = l10n.export("ru", include_all=False)
        entries = self.entries(worksheet)
        self.assertEqual(set(entries), {"Hello", "Goodbye", "%lld files"})
        self.assertEqual(entries["%lld files"]["source"],
                         {"one": "%lld file", "other": "%lld files"})
        self.assertEqual(entries["%lld files"]["forms"], ["one", "few", "many", "other"])
        self.assertEqual(entries["Hello"]["source"], "Hello")
        self.assertIsNone(entries["Hello"]["translation"])

    def test_export_all_includes_current_translations(self):
        entries = self.entries(l10n.export("ja", include_all=True))
        self.assertEqual(entries["Hello"]["translation"], "こんにちは")
        self.assertEqual(entries["%lld files"]["translation"], "%lld 件")

    def test_import_writes_values_and_plurals_in_language_order(self):
        worksheet = {"language": "fr", "entries": [
            {"catalog": "Conduit/Localizable.xcstrings", "key": "Hello", "translation": "Bonjour"},
            {"catalog": "Conduit/Localizable.xcstrings", "key": "Goodbye", "translation": None},
            {"catalog": "Conduit/Localizable.xcstrings", "key": "%lld files", "translation": {
                "other": "%lld fichiers", "one": "%lld fichier", "many": "%lld de fichiers"}},
        ]}
        path = os.path.join(self.root, "fr.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(worksheet, handle)
        self.assertEqual(l10n.import_worksheets([path]), 2)
        strings = self.read()["strings"]
        self.assertEqual(list(strings["Hello"]["localizations"]), ["fr", "ja"])
        self.assertEqual(strings["Hello"]["localizations"]["fr"], unit("Bonjour"))
        self.assertEqual(strings["Goodbye"]["localizations"], {})
        forms = strings["%lld files"]["localizations"]["fr"]["variations"]["plural"]
        self.assertEqual(list(forms), ["one", "many", "other"])

    def test_saved_catalogs_use_xcode_layout(self):
        with open(self.catalog_path, encoding="utf-8") as handle:
            text = handle.read()
        self.assertTrue(text.endswith("}\n"))
        self.assertIn('"sourceLanguage" : "en"', text)
        self.assertIn("こんにちは", text)

    def test_rename_retypes_placeholders_and_keeps_position(self):
        catalog = self.read()
        catalog["strings"]["Show %lld of %lld"] = {"localizations": {
            "ja": unit("%2$lld件中%1$lld件"), "de": unit("%lld von %lld 100%ig")}}
        self.write(catalog)
        l10n.rename("Show %lld of %lld", "Show %lld of %@", "Conduit/Localizable.xcstrings")
        strings = self.read()["strings"]
        self.assertNotIn("Show %lld of %lld", strings)
        localizations = strings["Show %lld of %@"]["localizations"]
        self.assertEqual(localizations["ja"], unit("%2$@件中%1$lld件"))
        self.assertEqual(localizations["de"], unit("%lld von %@ 100%ig"))

    def test_rename_refuses_a_different_argument_count(self):
        with self.assertRaises(ValueError):
            l10n.rename("%lld files", "%lld files in %@", "Conduit/Localizable.xcstrings")

    def test_remove_deletes_keys(self):
        l10n.remove(["Goodbye"], "Conduit/Localizable.xcstrings")
        self.assertNotIn("Goodbye", self.read()["strings"])
        with self.assertRaises(KeyError):
            l10n.remove(["Goodbye"], "Conduit/Localizable.xcstrings")


if __name__ == "__main__":
    unittest.main()
