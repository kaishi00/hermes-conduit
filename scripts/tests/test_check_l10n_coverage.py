"""Regression coverage for scripts/check-l10n-coverage.py (catalog guard)."""

import importlib.util
import json
import os
import unittest

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location(
    "check_l10n_coverage", os.path.join(SCRIPTS_DIR, "check-l10n-coverage.py"))
check_l10n_coverage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_l10n_coverage)

parse = check_l10n_coverage.parse_swift_string_literal
parse_parts = check_l10n_coverage.parse_swift_literal_parts
typed_skeleton = check_l10n_coverage.typed_skeleton
is_int = check_l10n_coverage.is_int_interpolation
extract = check_l10n_coverage.extract_sites
specs = check_l10n_coverage.placeholder_specs
compatible = check_l10n_coverage.placeholders_compatible
problems_for = check_l10n_coverage.catalog_problems


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

    def test_interpolation_expressions_are_returned(self):
        skeleton, _end, exprs = parse_parts('"a \\(x) b \\(y.count)"', 0)
        self.assertEqual(exprs, ["x", "y.count"])
        self.assertEqual(skeleton, "a %@ b %@")

    def test_nested_string_and_parens(self):
        source = r'"a \(f("x", (1 + 2))) b"'
        skeleton, _end, has_interp = parse(source, 0)
        self.assertEqual(skeleton, "a %@ b")
        self.assertTrue(has_interp)

    def test_unterminated_returns_none(self):
        self.assertIsNone(parse('"no close', 0))


class InterpolationTypeTests(unittest.TestCase):
    def test_string_wrapper_requests_object(self):
        self.assertFalse(is_int("String(count)"))
        self.assertFalse(is_int("String(n)"))

    def test_count_shaped_expressions_request_int(self):
        self.assertTrue(is_int("items.count"))
        self.assertTrue(is_int("selection.count"))
        self.assertTrue(is_int("activeCount"))
        self.assertTrue(is_int("progress.total"))
        self.assertTrue(is_int("Int(percent.rounded())"))
        self.assertTrue(is_int("rows.count - renderedRowCount"))

    def test_unknown_identifiers_default_to_object(self):
        self.assertFalse(is_int("statusTitle"))
        self.assertFalse(is_int("error.localizedDescription"))
        self.assertFalse(is_int("title"))

    def test_typed_skeleton_mixed_placeholder_families(self):
        self.assertEqual(
            typed_skeleton("a %@ b %@", ["String(x)", "y.count"]),
            "a %@ b %lld")
        self.assertEqual(
            typed_skeleton("a %@ b %@", ["x", "y"]),
            "a %@ b %@")

    def test_typed_skeleton_ignores_non_placeholder_splits(self):
        # A literal containing a literal % (e.g. "100%") cannot be rebuilt
        # unambiguously and is returned untouched.
        self.assertEqual(typed_skeleton("100% of %@", ["x"]), "100% of %@")


class ExtractSiteTests(unittest.TestCase):
    def test_string_localized_call_is_found(self):
        source = 'return String(localized: "Hello \\(name)!")'
        sites = list(extract(source))
        self.assertEqual(len(sites), 1)
        self.assertEqual(sites[0][0], "Hello %@!")

    def test_app_localization_string_call_is_found(self):
        source = 'return AppLocalization.string("Hello \\(name)!")'
        sites = list(extract(source))
        self.assertEqual(len(sites), 1)
        self.assertEqual(sites[0][0], "Hello %@!")

    def test_int_interpolation_requests_lld_key(self):
        source = 'AppLocalization.string("\\(selection.count) selected")'
        sites = list(extract(source))
        self.assertEqual(sites[0][0], "%lld selected")

    def test_string_wrapped_interpolation_requests_object_key(self):
        source = 'AppLocalization.string("\\(String(selection.count)) selected")'
        sites = list(extract(source))
        self.assertEqual(sites[0][0], "%@ selected")

    def test_multiline_app_localization_call_is_found(self):
        source = 'return AppLocalization.string(\n    "Hello")'
        sites = list(extract(source))
        self.assertEqual([s[0] for s in sites], ["Hello"])

    def test_swiftui_initializer_literal_is_found(self):
        source = 'Text("Welcome back")'
        sites = list(extract(source))
        self.assertEqual(sites[0][0], "Welcome back")

    def test_extended_swiftui_initializers_are_found(self):
        source = ('ProgressView("Loading")\n'
                  'ContentUnavailableView("Empty", systemImage: "tray")\n'
                  'Section("Header") {}\n'
                  'Menu("Title") {}\n'
                  'GroupBox("Note") {}')
        skeletons = [s[0] for s in extract(source)]
        self.assertEqual(skeletons,
                         ["Loading", "Empty", "Header", "Title", "Note"])

    def test_alert_and_confirmation_dialog_literals_are_found(self):
        source = ('view.alert("Delete?", isPresented: $shown) {}\n'
                  'view.confirmationDialog("Archive 1 Task?", isPresented: $p) {}')
        skeletons = [s[0] for s in extract(source)]
        self.assertEqual(skeletons, ["Delete?", "Archive 1 Task?"])

    def test_localized_string_key_modifiers_are_found(self):
        source = ('.navigationTitle("Delegate agents")\n'
                  '.accessibilityLabel("Delete \\(session.title)")\n'
                  '.accessibilityHint("Starts a new conversation")\n'
                  '.accessibilityValue("50 percent")')
        skeletons = [s[0] for s in extract(source)]
        self.assertEqual(skeletons,
                         ["Delegate agents", "Delete %@",
                          "Starts a new conversation", "50 percent"])

    def test_raw_user_facing_assignment_patterns_are_found(self):
        source = ('errorMessage = "Failed to send: \\(error.localizedDescription)"\n'
                  'help: "Any custom port."\n'
                  'purposeText: "Close the Voice conversation completely."')
        skeletons = [s[0] for s in extract(source)]
        self.assertEqual(skeletons,
                         ["Failed to send: %@", "Any custom port.",
                          "Close the Voice conversation completely."])

    def test_wrapped_error_message_is_not_double_reported(self):
        source = 'errorMessage = AppLocalization.string("Failed to send: \\(error)")'
        skeletons = [s[0] for s in extract(source)]
        self.assertEqual(skeletons, ["Failed to send: %@"])

    def test_full_line_comments_are_skipped(self):
        source = '// Text("not a call site")\nText("real")'
        skeletons = [s[0] for s in extract(source)]
        self.assertEqual(skeletons, ["real"])

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

    def test_placeholder_type_families_are_never_normalized(self):
        keys = {"%lld tokens"}
        self.assertTrue(check_l10n_coverage.catalog_has(keys, "%lld tokens"))
        # source %@ against a %lld catalog key: the runtime lookup would
        # MISS (Delegate-agents class) and must fail the checker.
        self.assertFalse(check_l10n_coverage.catalog_has(keys, "%@ tokens"))
        keys2 = {"%@ tokens"}
        self.assertTrue(check_l10n_coverage.catalog_has(keys2, "%@ tokens"))
        self.assertFalse(check_l10n_coverage.catalog_has(keys2, "%lld tokens"))


class PlaceholderTests(unittest.TestCase):
    def test_printf_forms_are_typed(self):
        self.assertEqual(specs("%@"), [(None, "object")])
        self.assertEqual(specs("%lld"), [(None, "int")])
        self.assertEqual(specs("%d"), [(None, "int")])
        self.assertEqual(specs("%ld"), [(None, "int")])
        self.assertEqual(specs("%f"), [(None, "float")])
        self.assertEqual(specs("%%"), [])

    def test_positional_forms_keep_indices(self):
        self.assertEqual(specs("%1$@ and %2$@"),
                         [(1, "object"), (2, "object")])
        self.assertEqual(specs("%1$lld items"),
                         [(1, "int")])

    def test_width_and_precision_count_as_placeholders(self):
        self.assertEqual(specs("%.1f%%"), [(None, "float")])
        self.assertEqual(specs("%5lld of %-8@"), [(None, "int"), (None, "object")])
        self.assertEqual(specs("%2$.2f"), [(2, "float")])

    def test_zero_padded_positional_translation_is_compatible(self):
        key = specs("%1$02d %2$@ %3$d")
        self.assertEqual(key, [(1, "int"), (2, "object"), (3, "int")])
        self.assertTrue(compatible(key, specs("%3$d %2$@ %1$02d")))

    def test_percent_signs_in_prose_are_not_placeholders(self):
        self.assertEqual(specs("5% increase, 100% done"), [])

    def test_multiple_placeholders(self):
        self.assertEqual(specs("%@ of %lld (%@)"),
                         [(None, "object"), (None, "int"), (None, "object")])

    def test_type_family_matrix(self):
        # source %@ / translation %@  → pass
        self.assertTrue(compatible([(None, "object")], [(None, "object")]))
        # source %lld / translation %lld → pass
        self.assertTrue(compatible([(None, "int")], [(None, "int")]))
        # source %lld / translation %@ → fail
        self.assertFalse(compatible([(None, "int")], [(None, "object")]))
        # source %@ / translation %lld → fail
        self.assertFalse(compatible([(None, "object")], [(None, "int")]))

    def test_missing_placeholder_fails(self):
        self.assertFalse(compatible([(None, "object"), (None, "int")],
                                    [(None, "object")]))

    def test_extra_placeholder_fails(self):
        self.assertFalse(compatible([(None, "object")],
                                    [(None, "object"), (None, "int")]))

    def test_valid_positional_reordering_passes(self):
        key = [(None, "object"), (None, "int")]
        self.assertTrue(compatible(key, [(1, "object"), (2, "int")]))
        self.assertTrue(compatible(key, [(2, "int"), (1, "object")]))

    def test_invalid_positional_index_fails(self):
        key = [(None, "object"), (None, "int")]
        self.assertFalse(compatible(key, [(1, "object"), (3, "int")]))
        self.assertFalse(compatible(key, [(0, "object"), (1, "int")]))

    def test_non_positional_translation_must_keep_the_argument_order(self):
        # printf consumes non-positional arguments in order: "%lld and %@"
        # for "%@ and %lld" reads the string as an integer.
        key = [(None, "object"), (None, "int")]
        self.assertTrue(compatible(key, [(None, "object"), (None, "int")]))
        self.assertFalse(compatible(key, [(None, "int"), (None, "object")]))
        self.assertTrue(compatible([(1, "object"), (2, "int")],
                                   [(None, "object"), (None, "int")]))
        self.assertFalse(compatible([(2, "object"), (1, "int")],
                                    [(None, "object"), (None, "int")]))

    def test_positional_translation_must_name_matching_types(self):
        key = [(None, "object"), (None, "int")]
        self.assertTrue(compatible(key, [(2, "int"), (1, "object")]))
        self.assertFalse(compatible(key, [(2, "object"), (1, "int")]))

    def test_positional_translation_must_use_every_argument(self):
        key = [(None, "object"), (None, "object")]
        self.assertFalse(compatible(key, [(1, "object"), (1, "object")]))
        self.assertTrue(compatible(key, [(2, "object"), (1, "object")]))

    def test_mixed_positional_translation_fails(self):
        # "%1$@ and %lld": Foundation's numbering of the bare %lld is
        # ambiguous, so a translation uses one style throughout.
        key = [(None, "object"), (None, "int")]
        self.assertFalse(compatible(key, [(1, "object"), (None, "int")]))
        self.assertFalse(compatible(key, [(None, "object"), (2, "int")]))

    def test_positional_on_both_sides_must_match(self):
        self.assertTrue(compatible([(1, "object"), (2, "object")],
                                   [(1, "object"), (2, "object")]))
        self.assertTrue(compatible([(1, "object"), (2, "object")],
                                   [(2, "object"), (1, "object")]))
        self.assertFalse(compatible([(1, "object"), (2, "int")],
                                    [(2, "object"), (1, "int")]))


def catalog_with(key, value, state="translated", language="zh-Hans"):
    return {"strings": {key: {"localizations": {language: {
        "stringUnit": {"state": state, "value": value}}}}}}


def zh_catalog(key, value, state="translated"):
    return catalog_with(key, value, state)


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


class CatalogProblemTests(unittest.TestCase):
    def test_missing_shipped_language_is_reported(self):
        catalog = {"strings": {"Hello": {"localizations": {
            "en": unit("Hello")}}}}
        problems = problems_for(catalog, ["zh-Hans"])
        self.assertIn("Hello", problems)
        self.assertTrue(any("missing zh-Hans" in p for p in problems["Hello"]))

    def test_every_shipped_language_is_required(self):
        # Nothing is special about zh-Hans: each shipped language must
        # localize every key.
        catalog = {"strings": {"Hello": {"localizations": {
            "fr": unit("Bonjour")}}}}
        problems = problems_for(catalog, ["fr", "ja"])
        self.assertEqual(problems["Hello"], ["missing ja localization"])

    def test_a_localization_without_units_counts_as_missing(self):
        catalog = {"strings": {"Hello": {"localizations": {"fr": {}}}}}
        problems = problems_for(catalog, ["fr"])
        self.assertEqual(problems["Hello"], ["missing fr localization"])

    def test_no_language_is_required_by_default(self):
        catalog = {"strings": {"Hello": {"localizations": {}}}}
        self.assertEqual(problems_for(catalog), {})

    def test_empty_value_is_reported(self):
        problems = problems_for(zh_catalog("Hello", "  "), ["zh-Hans"])
        self.assertTrue(any("empty" in p for p in problems["Hello"]))

    def test_untranslated_state_is_reported(self):
        problems = problems_for(zh_catalog("Hello", "你好", state="new"), ["zh-Hans"])
        self.assertTrue(any("state is 'new'" in p for p in problems["Hello"]))

    def test_placeholder_type_mismatch_is_reported(self):
        problems = problems_for(zh_catalog("%lld files", "%@ 个文件"), ["zh-Hans"])
        self.assertTrue(any("placeholders" in p for p in problems["%lld files"]))

    def test_malformed_literal_unicode_escape_is_reported(self):
        problems = problems_for(zh_catalog("Rename conversation",
                                           "\\u91cd\\u547d\\u540d\\u5bf9\\u8bdd"),
                                ["zh-Hans"])
        self.assertTrue(any("Unicode escape" in p
                            for p in problems["Rename conversation"]))

    def test_real_chinese_characters_pass(self):
        self.assertEqual(problems_for(zh_catalog("Rename conversation", "重命名对话"),
                                      ["zh-Hans"]), {})

    def test_json_decoded_proper_unicode_passes(self):
        # A catalog authored with \uXXXX JSON escapes decodes to real
        # characters and must pass.
        import json as j
        raw = '{"strings": {"K": {"localizations": {"zh-Hans": {"stringUnit": ' \
              '{"state": "translated", "value": "\\u91cd\\u547d\\u540d"}}}}}}'
        problems = problems_for(j.loads(raw), ["zh-Hans"])
        self.assertEqual(problems, {})

    def test_positional_translation_is_accepted(self):
        catalog = {"strings": {"Move %@ selected %@": {"localizations": {
            "zh-Hans": {"stringUnit": {
                "state": "translated",
                "value": "移动所选 %1$@ 个 %2$@"}}}}}}
        self.assertEqual(problems_for(catalog, ["zh-Hans"]), {})

    def test_translated_direct_entry_passes(self):
        self.assertEqual(problems_for(zh_catalog("Hello", "你好"), ["zh-Hans"]), {})

    def test_any_language_is_checked_the_same_way(self):
        self.assertEqual(problems_for(catalog_with("Hello", "こんにちは", language="ja"),
                                      ["ja"]), {})
        problems = problems_for(catalog_with("%lld files", "%@ ファイル", language="ja"),
                                ["ja"])
        self.assertTrue(any("ja placeholders" in p for p in problems["%lld files"]))

    def test_variation_only_translation_passes(self):
        catalog = {"strings": {"%lld conversations": {"localizations": {
            "zh-Hans": {"variations": {"plural": {"other": {
                "stringUnit": {"state": "translated", "value": "%lld 个会话"}}}}}}}}}
        self.assertEqual(problems_for(catalog, ["zh-Hans"]), {})

    def test_variation_leaf_violation_is_reported(self):
        catalog = {"strings": {"%lld conversations": {"localizations": {
            "zh-Hans": {"variations": {"plural": {"other": {
                "stringUnit": {"state": "new", "value": "%lld 个会话"}}}}}}}}}
        problems = problems_for(catalog, ["zh-Hans"])
        self.assertTrue(any("state is 'new'" in p for p in problems["%lld conversations"]))

    def test_stale_en_unit_with_mismatched_placeholders_is_reported(self):
        # The KanbanSelectionLayout regression: a key renamed to %@ while its
        # en unit still read %lld misformatted English at runtime (garbage
        # integer from the NSString pointer). Every language must validate.
        catalog = {"strings": {"%@ tasks selected": {"localizations": {
            "en": {"stringUnit": {"state": "translated",
                                  "value": "%lld tasks selected"}},
            "zh-Hans": {"stringUnit": {"state": "translated",
                                       "value": "已选择 %@ 个任务"}}}}}}
        problems = problems_for(catalog, ["zh-Hans"])
        self.assertTrue(any("en placeholders" in p for p in problems["%@ tasks selected"]))

    def test_matching_en_unit_passes(self):
        catalog = {"strings": {"%lld conversations": {"localizations": {
            "en": {"variations": {"plural": {"one": {
                "stringUnit": {"state": "translated", "value": "%lld conversation"}},
                "other": {"stringUnit": {"state": "translated",
                                         "value": "%lld conversations"}}}}},
            "zh-Hans": {"variations": {"plural": {"other": {
                "stringUnit": {"state": "translated", "value": "%lld 个会话"}}}}}}}}}
        self.assertEqual(problems_for(catalog, ["zh-Hans"]), {})

    def test_exempt_keys_are_not_required(self):
        catalog = {"strings": {"Hermes": {"localizations": {}}}}
        self.assertEqual(problems_for(catalog, ["zh-Hans"]), {})

    def test_regression_keys_are_enforced(self):
        catalog = {"strings": {}}
        problems = check_l10n_coverage.required_key_problems(
            catalog, ["Missing regression key"])
        self.assertIn("Missing regression key", problems)


def plural(*categories, value="%lld x"):
    return {"variations": {"plural": {category: unit(value)
                                      for category in categories}}}


def plural_catalog(**localizations):
    localizations.setdefault("en", plural("one", "other"))
    return {"sourceLanguage": "en", "strings": {
        "%lld files": {"localizations": localizations}}}


class PluralCategoryTests(unittest.TestCase):
    """Where the source varies a key by plural, every shipped language must
    provide each category its own plural rules use."""

    def test_single_form_language_needs_only_other(self):
        catalog = plural_catalog(**{"zh-Hans": plural("other"), "ja": unit("%lld 件")})
        self.assertEqual(problems_for(catalog, ["zh-Hans", "ja"]), {})

    def test_missing_category_is_reported(self):
        catalog = plural_catalog(fr=plural("one", "other"))
        self.assertEqual(problems_for(catalog, ["fr"])["%lld files"],
                         ["fr plural lacks many (its plural rules use one, many, other)"])

    def test_a_plain_string_counts_as_other_only(self):
        catalog = plural_catalog(ru=unit("%lld файлов"))
        problems = problems_for(catalog, ["ru"])["%lld files"]
        self.assertEqual(problems, ["ru plural lacks one, few, many "
                                    "(its plural rules use one, few, many, other)"])

    def test_regional_and_script_variants_use_their_language_rules(self):
        catalog = plural_catalog(**{"pt-BR": plural("one", "many", "other"),
                                    "sr-Latn": plural("one", "few", "other")})
        self.assertEqual(problems_for(catalog, ["pt-BR", "sr-Latn"]), {})

    def test_extra_categories_are_allowed(self):
        catalog = plural_catalog(de=plural("zero", "one", "other"))
        self.assertEqual(problems_for(catalog, ["de"]), {})

    def test_an_unlisted_language_needs_only_other(self):
        catalog = plural_catalog(xx=plural("other"))
        self.assertEqual(problems_for(catalog, ["xx"]), {})

    def test_the_source_language_is_held_to_its_own_rules(self):
        catalog = plural_catalog(en=plural("other"), ja=plural("other"))
        problems = problems_for(catalog, ["ja"])["%lld files"]
        self.assertEqual(problems, ["en plural lacks one (its plural rules use one, other)"])

    def test_drafts_need_no_plural_coverage(self):
        catalog = plural_catalog(ru=plural("other"))
        self.assertEqual(problems_for(catalog, [], ["ru"]), {})

    def test_a_plural_without_other_is_malformed_in_any_language(self):
        catalog = plural_catalog(ru=plural("one", "few", "many"))
        problems = problems_for(catalog, [], ["ru"])["%lld files"]
        self.assertEqual(problems, ["ru plural has no 'other' form"])

    def test_a_plural_nested_in_a_device_variant_is_held_to_the_rules(self):
        def on_iphone(localization):
            return {"variations": {"device": {"iphone": localization}}}
        catalog = plural_catalog(en=on_iphone(plural("one", "other")),
                                 fr=on_iphone(plural("one", "other")))
        self.assertEqual(problems_for(catalog, ["fr"])["%lld files"],
                         ["fr plural lacks many (its plural rules use one, many, other)"])
        self.assertFalse(check_l10n_coverage.language_is_complete(catalog, "fr"))

        catalog = plural_catalog(en=on_iphone(plural("one", "other")),
                                 ru=on_iphone(plural("one", "few", "many")))
        problems = problems_for(catalog, [], ["ru"])["%lld files"]
        self.assertEqual(problems, ["ru plural has no 'other' form"])

    def test_keys_the_source_does_not_vary_need_no_plural(self):
        catalog = {"sourceLanguage": "en", "strings": {
            "%lld files": {"localizations": {"fr": unit("%lld fichiers")}}}}
        self.assertEqual(problems_for(catalog, ["fr"]), {})

    def test_the_table_follows_current_cldr(self):
        # Spot checks against unicode-org/cldr plurals.xml, including rules
        # that changed in recent CLDR versions (he lost many, gl gained it).
        expected = {
            "he": ("one", "two", "other"),
            "gl": ("one", "many", "other"),
            "vi": ("one", "other"),
            "pt-PT": ("one", "many", "other"),
            "mt": ("one", "two", "few", "many", "other"),
            "zh-Hans": ("other",),
            "ar": ("zero", "one", "two", "few", "many", "other"),
        }
        for language, categories in expected.items():
            self.assertEqual(check_l10n_coverage.plural_categories(language),
                             categories, language)

    def test_an_incomplete_plural_keeps_a_draft_from_being_ready(self):
        catalog = plural_catalog(ru=plural("one", "other"))
        self.assertFalse(check_l10n_coverage.language_is_complete(catalog, "ru"))
        catalog = plural_catalog(ru=plural("one", "few", "many", "other"))
        self.assertTrue(check_l10n_coverage.language_is_complete(catalog, "ru"))


class DraftLanguageTests(unittest.TestCase):
    """A draft may be partial and unreviewed, but never malformed."""

    def test_partial_draft_is_not_required(self):
        catalog = {"strings": {
            "Hello": {"localizations": {"ja": unit("こんにちは")}},
            "Bye": {"localizations": {}}}}
        self.assertEqual(problems_for(catalog, [], ["ja"]), {})

    def test_unreviewed_draft_units_are_allowed(self):
        catalog = catalog_with("Hello", "こんにちは", state="needs_review", language="ja")
        self.assertEqual(problems_for(catalog, [], ["ja"]), {})
        catalog = catalog_with("Hello", "", state="new", language="ja")
        self.assertEqual(problems_for(catalog, [], ["ja"]), {})

    def test_draft_matching_ignores_identifier_spelling(self):
        catalog = catalog_with("Hello", "Olá", state="new", language="pt-BR")
        self.assertEqual(problems_for(catalog, [], ["pt_br"]), {})

    def test_draft_placeholder_mismatch_is_reported(self):
        catalog = catalog_with("%lld files", "%@ ファイル", state="needs_review", language="ja")
        problems = problems_for(catalog, [], ["ja"])
        self.assertTrue(any("ja placeholders" in p for p in problems["%lld files"]))

    def test_draft_malformed_escape_is_reported(self):
        catalog = catalog_with("Hello", "\\u3053", language="ja")
        problems = problems_for(catalog, [], ["ja"])
        self.assertTrue(any("Unicode escape" in p for p in problems["Hello"]))

    def test_draft_translated_but_empty_is_reported(self):
        catalog = catalog_with("Hello", " ", language="ja")
        problems = problems_for(catalog, [], ["ja"])
        self.assertEqual(problems["Hello"], ["ja value is empty"])

    def test_nested_variation_units_are_checked(self):
        # A plural inside a device variant: its units count for coverage and
        # get the same integrity checks as top-level ones.
        nested = {"variations": {"device": {"iphone": {"variations": {"plural": {
            "other": {"stringUnit": {"state": "translated", "value": "%@ 件"}}}}}}}}
        catalog = {"strings": {"%lld items": {"localizations": {"ja": nested}}}}
        problems = problems_for(catalog, [], ["ja"])
        self.assertTrue(any("ja placeholders" in p for p in problems["%lld items"]))

    def test_a_malformed_draft_is_not_ready_to_ship(self):
        for key, value in (("%lld files", "%@ ファイル"), ("Hello", "\\u3053")):
            catalog = catalog_with(key, value, language="ja")
            self.assertFalse(check_l10n_coverage.language_is_complete(catalog, "ja"), value)
        catalog = catalog_with("%lld files", "%lld ファイル", language="ja")
        self.assertTrue(check_l10n_coverage.language_is_complete(catalog, "ja"))

    def test_the_same_partial_language_fails_once_it_ships(self):
        catalog = {"strings": {
            "Hello": {"localizations": {"ja": unit("こんにちは")}},
            "Bye": {"localizations": {}}}}
        self.assertEqual(problems_for(catalog, ["ja"]),
                         {"Bye": ["missing ja localization"]})


def catalogs_with(languages_by_key, source="en"):
    return {check_l10n_coverage.SOURCE_CATALOG: {
        "sourceLanguage": source,
        "strings": {key: {"localizations": {language: unit(value)
                                             for language, value in values.items()}}
                    for key, values in languages_by_key.items()}}}


class LanguagePlanTests(unittest.TestCase):
    plan = check_l10n_coverage.LanguagePlan

    def test_every_catalog_language_ships_unless_drafted(self):
        catalogs = catalogs_with({"Hello": {"en": "Hello", "fr": "Bonjour",
                                            "ja": "こんにちは", "de": "Hallo"}})
        plan = self.plan(catalogs, ["ja"])
        self.assertEqual(plan.source, "en")
        self.assertEqual(plan.shipped, ["de", "fr"])
        self.assertEqual(plan.drafts, ["ja"])
        self.assertEqual(plan.problems, [])

    def test_languages_in_secondary_catalogs_count(self):
        catalogs = catalogs_with({"Hello": {"fr": "Bonjour"}})
        catalogs["InfoPlist.xcstrings"] = {"sourceLanguage": "en", "strings": {
            "CFBundleName": {"localizations": {"ko": unit("콘듀잇")}}}}
        self.assertEqual(self.plan(catalogs, []).shipped, ["fr", "ko"])

    def test_the_source_language_cannot_be_a_draft(self):
        plan = self.plan(catalogs_with({"Hello": {"fr": "Bonjour"}}), ["EN"])
        self.assertTrue(any("source language" in p for p in plan.problems))

    def test_base_cannot_be_a_draft(self):
        plan = self.plan(catalogs_with({"Hello": {"fr": "Bonjour"}}), ["Base"])
        self.assertTrue(any("lists Base" in p for p in plan.problems))

    def test_catalogs_must_share_a_source_language(self):
        catalogs = catalogs_with({"Hello": {"fr": "Bonjour"}})
        catalogs["InfoPlist.xcstrings"] = {"sourceLanguage": "fr", "strings": {}}
        plan = self.plan(catalogs, [])
        self.assertTrue(any("sourceLanguage" in p for p in plan.problems))

    def test_a_complete_draft_is_flagged_ready_to_ship(self):
        plan = self.plan(catalogs_with({"Hello": {"ja": "こんにちは"}}), ["ja"])
        self.assertTrue(any("'ja' is complete" in note for note in plan.notes))

    def test_a_partial_draft_is_not_flagged(self):
        catalogs = catalogs_with({"Hello": {"ja": "こんにちは"}, "Bye": {"fr": "Au revoir"}})
        self.assertEqual(self.plan(catalogs, ["ja"]).notes, [])

    def test_one_language_needs_one_spelling_across_catalogs(self):
        catalogs = catalogs_with({"Hello": {"zh-Hans": "你好"}})
        catalogs["InfoPlist.xcstrings"] = {"sourceLanguage": "en", "strings": {
            "CFBundleName": {"localizations": {"zh_Hans": unit("Conduit")}}}}
        plan = self.plan(catalogs, [])
        self.assertEqual(plan.shipped, ["zh-Hans"])
        self.assertTrue(any("spelled ['zh-Hans', 'zh_Hans']" in p for p in plan.problems))

    def test_a_shipped_language_without_plural_rules_on_file_is_noted(self):
        plan = self.plan(catalogs_with({"Hello": {"xx": "Hi"}}), [])
        self.assertTrue(any("no plural rules on file for 'xx'" in n for n in plan.notes))
        plan = self.plan(catalogs_with({"Hello": {"fr": "Salut"}}), [])
        self.assertEqual(plan.notes, [])

    def test_a_draft_with_no_entries_yet_is_noted(self):
        plan = self.plan(catalogs_with({"Hello": {"fr": "Bonjour"}}), ["ja"])
        self.assertEqual(plan.drafts, [])
        self.assertTrue(any("no catalog entries" in note for note in plan.notes))


class CatalogFileTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def write(self, name, content, mode="w"):
        path = os.path.join(self.directory.name, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, mode) as handle:
            handle.write(content)
        return path

    def test_duplicate_catalog_keys_are_detected(self):
        path = self.write("Localizable.xcstrings",
                          '{"strings": {"A": {"localizations": {}}, '
                          '"A": {"localizations": {}}}}')
        catalog, duplicates = check_l10n_coverage.load_catalog(path)
        self.assertEqual(list(duplicates), ["A"])
        self.assertIn("more than once", duplicates["A"][0])
        self.assertEqual(list(catalog["strings"]), ["A"])

    def test_a_repeat_inside_an_entry_is_reported_on_that_entry(self):
        path = self.write("Localizable.xcstrings",
                          '{"strings": {"A": {"localizations": {'
                          '"fr": {"stringUnit": {"state": "translated", "value": "x"}},'
                          '"fr": {"stringUnit": {"state": "translated", "value": "y"}}}}}}')
        _catalog, duplicates = check_l10n_coverage.load_catalog(path)
        self.assertEqual(duplicates, {"A": [
            "repeats 'localizations/fr' in its JSON (only one copy survives)"]})

    def test_a_catalog_without_repeats_has_no_duplicates(self):
        path = self.write("Localizable.xcstrings",
                          '{"strings": {"A": {"localizations": {}}, '
                          '"B": {"localizations": {}}}, "version": "1.0"}')
        self.assertEqual(check_l10n_coverage.load_catalog(path)[1], {})

    def test_draft_languages_are_read_from_info_plist(self):
        import plistlib
        path = self.write("Info.plist", plistlib.dumps(
            {"ConduitDraftLanguages": ["ja", "pt-BR"]}), mode="wb")
        self.assertEqual(check_l10n_coverage.read_draft_languages(path), ["ja", "pt-BR"])

    def test_a_missing_draft_list_means_no_drafts(self):
        import plistlib
        path = self.write("Info.plist", plistlib.dumps({}), mode="wb")
        self.assertEqual(check_l10n_coverage.read_draft_languages(path), [])
        self.assertEqual(check_l10n_coverage.read_draft_languages(
            os.path.join(self.directory.name, "absent.plist")), [])

    def test_a_malformed_draft_list_is_rejected(self):
        import plistlib
        path = self.write("Info.plist", plistlib.dumps(
            {"ConduitDraftLanguages": "ja"}), mode="wb")
        with self.assertRaises(ValueError):
            check_l10n_coverage.read_draft_languages(path)

    def test_a_corrupt_info_plist_is_a_value_error(self):
        for content in ("not a plist", '<?xml version="1.0"?><plist><dict>'):
            path = self.write("Info.plist", content)
            with self.assertRaises(ValueError, msg=content):
                check_l10n_coverage.read_draft_languages(path)

    def write_repo(self, drafts):
        import plistlib
        catalog = {"sourceLanguage": "en", "strings": {
            "Hello": {"localizations": {"fr": unit("Bonjour"), "ja": unit("こんにちは")}},
            "Bye": {"localizations": {"fr": unit("Au revoir")}}}}
        for key in check_l10n_coverage.REGRESSION_KEYS:
            catalog["strings"][key] = {"localizations": {"fr": unit(key)}}
        self.write("Conduit/Localizable.xcstrings", json.dumps(catalog))
        self.write("Conduit/Info.plist", plistlib.dumps(
            {"ConduitDraftLanguages": drafts}), mode="wb")
        self.write("Conduit/View.swift", 'Text("Hello")\nText("Bye")\n')

    def test_a_corrupt_catalog_fails_the_check_cleanly(self):
        self.write_repo(drafts=[])
        self.write("Conduit/Localizable.xcstrings", '{"strings": {\n<<<<<<< HEAD\n')
        with self.assertRaises(check_l10n_coverage.CatalogError) as caught:
            check_l10n_coverage.check(self.directory.name)
        self.assertIn("Conduit/Localizable.xcstrings", str(caught.exception))

    def test_a_catalog_of_the_wrong_shape_fails_the_check_cleanly(self):
        for content in ("[]", '{"sourceLanguage": "en"}', '{"strings": []}'):
            self.write_repo(drafts=[])
            self.write("Conduit/Localizable.xcstrings", content)
            with self.assertRaises(check_l10n_coverage.CatalogError, msg=content) as caught:
                check_l10n_coverage.check(self.directory.name)
            self.assertIn("not a String Catalog", str(caught.exception))

    def test_an_unreadable_info_plist_fails_the_check_cleanly(self):
        self.write_repo(drafts=[])
        self.write("Conduit/Info.plist", "not a plist")
        _checked, _missing, key_problems, _plan = check_l10n_coverage.check(
            self.directory.name)
        self.assertIn("Conduit/Info.plist: ConduitDraftLanguages", key_problems)

    def test_a_new_partial_language_fails_until_marked_draft(self):
        self.write_repo(drafts=[])
        checked, missing, key_problems, plan = check_l10n_coverage.check(
            self.directory.name)
        self.assertEqual((checked, missing), (2, {}))
        self.assertEqual(plan.shipped, ["fr", "ja"])
        self.assertIn("missing ja localization", key_problems["Bye"])

        self.write_repo(drafts=["ja"])
        _checked, _missing, key_problems, plan = check_l10n_coverage.check(
            self.directory.name)
        self.assertEqual(plan.shipped, ["fr"])
        self.assertEqual(plan.drafts, ["ja"])
        self.assertEqual(key_problems, {})


class CheckIntegrationTests(unittest.TestCase):
    def test_repo_catalog_covers_every_call_site(self):
        checked, missing, key_problems, plan = check_l10n_coverage.check(
            os.path.dirname(SCRIPTS_DIR))
        self.assertEqual(
            missing, {},
            f"localizable keys missing from the catalog: {sorted(missing)}")
        self.assertGreater(checked, 1000)
        self.assertEqual(
            key_problems, {},
            f"catalog keys with localization problems: {sorted(key_problems)}")
        self.assertIn(plan.source, ("en",))
        self.assertTrue(plan.shipped, "the repo ships at least one translation")
        catalog_path = os.path.join(os.path.dirname(SCRIPTS_DIR),
                                    "Conduit", "Localizable.xcstrings")
        with open(catalog_path, encoding="utf-8") as handle:
            catalog_keys = set(json.load(handle)["strings"])
        for key in check_l10n_coverage.REGRESSION_KEYS:
            self.assertIn(key, catalog_keys)


if __name__ == "__main__":
    unittest.main()
