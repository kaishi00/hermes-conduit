"""Regression coverage for scripts/check-l10n-coverage.py (catalog guard)."""

import importlib.util
import os
import unittest

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location(
    "check_l10n_coverage", os.path.join(SCRIPTS_DIR, "check-l10n-coverage.py"))
check_l10n_coverage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_l10n_coverage)

parse = check_l10n_coverage.parse_swift_string_literal
extract = check_l10n_coverage.extract_sites


class StringLiteralParsingTests(unittest.TestCase):
    def test_plain_literal(self):
        self.assertEqual(parse('"Hello"', 0), ("Hello", 7, False))

    def test_escaped_quote_and_backslash(self):
        self.assertEqual(parse('"a\\"b\\\\"', 0), ('a"b\\', 8, False))

    def test_escapes_are_decoded_for_key_matching(self):
        self.assertEqual(parse('"line\\nbreak"', 0), ("line\nbreak", 13, False))

    def test_interpolation_becomes_placeholder(self):
        skeleton, end, has_interp = parse('"prefix \\(value) suffix"', 0)
        self.assertEqual(skeleton, "prefix %@ suffix")
        self.assertTrue(has_interp)
        self.assertEqual(end, len('"prefix \\(value) suffix"'))

    def test_interpolation_with_nested_string_and_parens(self):
        source = r'"a \(f("x", (1 + 2))) b"'
        skeleton, _end, has_interp = parse(source, 0)
        self.assertEqual(skeleton, "a %@ b")
        self.assertTrue(has_interp)

    def test_unterminated_returns_none(self):
        self.assertIsNone(parse('"no close', 0))


class ExtractSiteTests(unittest.TestCase):
    def test_string_localized_call_is_found(self):
        source = 'return String(localized: "Hello \\(name)!")'
        sites = list(extract(source))
        self.assertEqual(len(sites), 1)
        self.assertEqual(sites[0][0], "Hello %@!")

    def test_swiftui_initializer_literal_is_found(self):
        source = 'Text("Welcome back")'
        sites = list(extract(source))
        self.assertEqual(sites[0][0], "Welcome back")

    def test_swiftui_variable_argument_is_skipped(self):
        source = "Text(message)\nLabel(title, systemImage: \"star\")"
        self.assertEqual(list(extract(source)), [])

    def test_non_localized_string_is_skipped(self):
        source = 'let url = URL(string: "https://example.com")'
        self.assertEqual(list(extract(source)), [])


class CatalogHasTests(unittest.TestCase):
    def test_static_key_requires_exact_match(self):
        keys = {"Hello"}
        self.assertTrue(check_l10n_coverage.catalog_has(keys, "Hello"))
        self.assertFalse(check_l10n_coverage.catalog_has(keys, "Hello!"))

    def test_interpolated_key_accepts_placeholder_variants(self):
        keys = {"%lld tokens"}
        self.assertTrue(check_l10n_coverage.catalog_has(keys, "%@ tokens"))
        self.assertFalse(check_l10n_coverage.catalog_has(keys, "%@ of %@"))


class CheckIntegrationTests(unittest.TestCase):
    def test_repo_catalog_covers_every_call_site(self):
        checked, missing = check_l10n_coverage.check(
            os.path.dirname(SCRIPTS_DIR))
        self.assertEqual(
            missing, {},
            f"localizable keys missing from the catalog: {sorted(missing)}")
        self.assertGreater(checked, 1000)


if __name__ == "__main__":
    unittest.main()
