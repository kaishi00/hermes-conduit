#!/usr/bin/env python3
"""Localization catalog coverage: every localizable call site must resolve
against a runtime-accurate key, and every SHIPPED language must carry a
real translation of every key.

Languages are data, not code. The checker reads them from the String
Catalogs and Conduit/Info.plist, so adding a language is a catalog change:

  * source language - the catalogs' "sourceLanguage". Keys are its strings
    and every other language falls back to them.
  * draft languages - Info.plist's ConduitDraftLanguages array: translation
    still in progress. The build strips their lprojs
    (scripts/strip-draft-localizations.py) and the app never offers them,
    so only their integrity is checked, not their completeness.
  * shipped languages - every other language that appears in any catalog.

Scans Conduit Swift sources for sites that look up String Catalog keys -

  1. AppLocalization.string("...") / String(localized: "...") - the
     skeleton must exist in Localizable.xcstrings with the SAME placeholder
     types the runtime will request: `\\(String(x))`-style interpolations
     request %@, integer-shaped expressions (Int casts, .count/.index/
     .total, count-like identifiers, digit arithmetic) request %lld.
     Placeholders are never normalized across type families, so a source
     Int interpolation against a %@ catalog key (or vice versa) fails.
  2. SwiftUI literal initializers (Text/Button/Label/TextField/SecureField/
     Toggle/NavigationLink/Picker/ProgressView/ContentUnavailableView/
     Section/Menu/GroupBox) - a leading string literal is a
     LocalizedStringKey and is checked the same way.
  3. LocalizedStringKey modifiers (.alert / .confirmationDialog /
     .navigationTitle / .accessibilityLabel / .accessibilityHint /
     .accessibilityValue).
  4. Raw user-facing String assignments/arguments that flow into
     Text/Label/alert rendering: `errorMessage = "..."`, `help: "..."`,
     `purposeText: "..."`.

For every required key (static call sites plus the explicit REGRESSION_KEYS
below - dynamic/ternary sites that cannot be extracted statically), the
checker then validates every catalog (Localizable, AppShortcuts,
InfoPlist):

  * the key must exist, and appear only once in the catalog JSON;
  * every shipped non-source language must have a localization (a key
    with only some languages fails);
  * every stringUnit leaf of a shipped language (source included) - direct
    or inside plural/device variations - must have state == "translated"
    and a non-empty value;
  * the printf placeholders of every value in ANY language, drafts
    included, must match the key's placeholder TYPE FAMILIES (object vs
    integer vs float) in count, order, and positional index validity -
    %@ and %lld are never interchangeable;
  * no value may contain malformed literal Unicode escape sequences (e.g.
    the text "\\u4e00") - those are double-escaped authoring bugs, not
    legitimate backslash content.

Any violation is reported with file:line (call sites) or by key and
language (catalog) and fails the run.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import sys
import xml.parsers.expat

# Info.plist array of draft localization identifiers. The app reads the
# same key (AppLocalizations.draftLanguagesInfoKey), and so does the build's
# draft-stripping phase.
DRAFT_LANGUAGES_KEY = "ConduitDraftLanguages"

# SwiftUI initializers whose first argument is a LocalizedStringKey when a
# string literal is passed directly. Variables/interpolations elsewhere are
# not statically checkable and are simply skipped.
SWIFTUI_LOCALIZED_INITIALIZERS = (
    "Text", "Button", "Label", "TextField", "SecureField",
    "Toggle", "NavigationLink", "Picker",
    "ProgressView", "ContentUnavailableView", "Section", "Menu", "GroupBox",
)

# Modifier-style APIs whose first argument is a LocalizedStringKey when a
# string literal is passed directly (there are String overloads too, but a
# raw literal in a String-position branch is exactly the bug class this
# checker exists for, so literal sites are always required to be keys).
SWIFTUI_LOCALIZED_MODIFIERS = (
    "alert", "confirmationDialog", "navigationTitle",
    "accessibilityLabel", "accessibilityHint", "accessibilityValue",
)

# Raw user-facing String assignments/arguments that later flow into
# Text/Label/alert rendering. Only literal right-hand sides are flagged.
RAW_STRING_ASSIGNMENT_RE = re.compile(
    r"\b(?:errorMessage|help|purposeText)\s*[:=]\s*\"")

# Keys that are intentionally not statically present in the catalog: pure
# variable passthroughs, separators, brand/protocol names, and placeholder
# tokens that must never be translated.
EXEMPT_KEYS = frozenset({
    "%@",            # verbatim variable passthrough
    "%lld",          # bare numeric counter chip
    "%@ %@",         # two-variable passthrough
    "%@: %@",        # speaker/field label passthrough ("You: text")
    "%@/%@",         # numeric done/total counters (string-wrapped)
    "%lld/%lld",     # numeric done/total counters (int interpolation)
    "%@.",           # numbered step prefix ("1.")
    "/", "•",        # separators
    "v%@",           # version prefix ("v1.2.3")
    "×%@",           # multiplier badge
    "×%lld",         # multiplier badge (int interpolation)
    "A",             # typography size sample glyph
    "Conduit", "GitHub", "Hermes", "HTTP", "HTTPS",  # brand/protocol names
    "https://hermes.example", "https://push.milim.dev",  # literal URLs
    "skill-name",    # example placeholder token
})

# Dynamic sites the extractor cannot see: variable-key lookups where the
# catalog key is computed at runtime. Conditional-branch literals are NOT
# here anymore — they are wrapped in AppLocalization.string at the source
# (Text(condition ? "A" : "B") binds the verbatim String overload, so raw
# ternary branches never localize) and are statically extracted now. When
# adding a new dynamic localizable site, add its key here.
REGRESSION_KEYS = (
    # ProfileConfigValueDisplay table (value → display label map)
    "Manual",
    "Smart",
    "YOLO mode",
    "Automatic",
    "Native images",
    "Text only",
    "Default",
    "Helpful",
    "Concise",
    "Technical",
    "Creative",
    "Teacher",
    "Kawaii",
    "Catgirl",
    "Pirate",
    "Shakespeare",
    "Surfer",
    "Noir",
    "Philosopher",
    "Hype",
    "Session",
    "Skills & extensions",
    # archive/restore ternary passed as a variable argument
    "archive",
    "restore",
    # Cron action verb display map (wire tokens stay raw in the URL path)
    "pause",
    "resume",
    "trigger",
)

CALL_RE = re.compile(
    r"\b(?:String\s*\(\s*localized\s*:|AppLocalization\s*\.\s*string\s*\()")
SWIFTUI_RE = re.compile(
    r"\b(" + "|".join(SWIFTUI_LOCALIZED_INITIALIZERS) + r")\s*\(")
MODIFIER_RE = re.compile(
    r"\.\s*(" + "|".join(SWIFTUI_LOCALIZED_MODIFIERS) + r")\s*\(")

# Malformed literal Unicode escapes in catalog VALUES, e.g. the text
# "\u91cd" arriving as six visible characters instead of 重. Only the
# backslash-u-hex shape is targeted; ordinary backslashes stay legal.
MALFORMED_ESCAPE_RE = re.compile("\\\\u[0-9a-fA-F]{4}")

# Optional width and precision (%.1f, %5lld, %-8@) count like the bare form.
# No space or "+" flag: "5% increase" is prose, not "% i".
_PLACEHOLDER_RE = re.compile(
    r"%(?:(\d+)\$)?(?:-?\d*(?:\.\d+)?(?=[@dfilu]))?"
    r"([@df]|l{1,2}[diu]|lf|@|d|i|u|%)")

# Interpolation expressions that request an INTEGER runtime placeholder
# (%lld) rather than an object (%@). String-hint wins: the documented
# Conduit convention is to String()-wrap integers (avoids locale digit
# grouping), so an explicit String(...) means %@.
_STRING_HINT_RE = re.compile(
    r"\bString\s*\(|localizedDescription|\.description\b|\.name\b|\.id\b"
    r"|\.title\b|\.text\b|\.message\b|\.displayName\b|\.key\b")
_INT_HINT_RE = re.compile(
    r"\b(?:Int|UInt|Int8|Int16|Int32|Int64)\s*\("
    r"|\.\s*count\b|\.\s*index\b|\.\s*total\b"
    r"|\w*[Cc]ount\b|\w*[Ii]ndex\b|\w*[Tt]otal\b"
    r"|^\s*[\d\s+\-*/().]+\s*$")


def is_int_interpolation(expression: str) -> bool:
    """Focused heuristic: does this interpolation request %lld at runtime?

    Conservative by design - anything not matching the integer shapes below
    is treated as an object (%@) placeholder, matching the codebase
    convention of String()-wrapping non-plural interpolations.
    """
    if _STRING_HINT_RE.search(expression):
        return False
    return bool(_INT_HINT_RE.search(expression))


def typed_skeleton(literal: str, expressions) -> str:
    """Rebuild a literal with one placeholder per interpolation, typed by
    the runtime argument family (%@ object / %lld integer)."""
    parts = literal.split("%@")
    if len(parts) - 1 != len(expressions):
        return literal
    out = []
    for i, part in enumerate(parts):
        out.append(part)
        if i < len(expressions):
            out.append("%lld" if is_int_interpolation(expressions[i]) else "%@")
    return "".join(out)


def placeholder_specs(formatted: str) -> list:
    """Extract (position, type) pairs from a printf-style format string.

    %% escapes are ignored. Positional forms (%1$@) keep their index;
    non-positional forms get None. Type families: object / int / float.
    """
    specs = []
    i = 0
    while i < len(formatted):
        if formatted[i] != "%":
            i += 1
            continue
        match = _PLACEHOLDER_RE.match(formatted, i)
        if not match:
            i += 1
            continue
        i = match.end()
        if match.group(0) == "%%":
            continue
        position = int(match.group(1)) if match.group(1) else None
        body = match.group(2)
        if body == "@":
            kind = "object"
        elif body in ("f", "lf"):
            kind = "float"
        else:
            kind = "int"
        specs.append((position, kind))
    return specs


def parse_swift_string_literal(source: str, start: int):
    """Parse a Swift string literal starting at source[start] == '"'.

    Returns (skeleton, end_index, has_interpolation) or None when the
    literal is unterminated at EOF. Interpolations \\(...) collapse to a
    single placeholder; nested strings inside them are skipped.
    """
    parsed = parse_swift_literal_parts(source, start)
    if parsed is None:
        return None
    skeleton, end, exprs = parsed
    return skeleton, end, bool(exprs)


def parse_swift_literal_parts(source: str, start: int):
    """Like parse_swift_string_literal but also returns the raw text of each
    \\(...) interpolation expression, in order: (skeleton, end, exprs)."""
    assert source[start] == '"'
    out = []
    exprs = []
    i = start + 1
    while i < len(source):
        ch = source[i]
        if ch == "\\":
            if i + 1 >= len(source):
                return None
            nxt = source[i + 1]
            if nxt == "(":
                # Interpolation: skip to the matching close paren.
                depth = 1
                j = i + 2
                expr_start = j
                while j < len(source) and depth:
                    if source[j] == '"':
                        parsed = parse_swift_literal_parts(source, j)
                        if parsed is None:
                            return None
                        j = parsed[1] - 1
                    elif source[j] == "(":
                        depth += 1
                    elif source[j] == ")":
                        depth -= 1
                    j += 1
                if depth:
                    return None
                exprs.append(source[expr_start:j - 1])
                out.append("%@")
                i = j
            else:
                escapes = {"n": "\n", "t": "\t", "r": "\r", "0": "\0",
                           "\\": "\\", '"': '"', "'": "'"}
                out.append(escapes.get(nxt, nxt))
                i += 2
        elif ch == '"':
            return "".join(out), i + 1, exprs
        else:
            out.append(ch)
            i += 1
    return None


def strip_comment_lines(source: str) -> str:
    """Drop full-line // comments so doc diagrams can't look like call sites.

    Only WHOLE-LINE comments are removed - code with trailing comments is
    kept intact, and '//' inside string literals lives on code lines.
    """
    kept = []
    for line in source.split("\n"):
        if line.lstrip().startswith("//"):
            continue
        kept.append(line)
    return "\n".join(kept)


def extract_sites(source: str):
    """Yield (key_skeleton, offset) for every checkable call site.

    Skeletons are runtime-accurate: each interpolation contributes %@ or
    %lld according to the argument's type family.
    """
    source = strip_comment_lines(source)
    for regex in (CALL_RE, SWIFTUI_RE, MODIFIER_RE):
        for match in regex.finditer(source):
            i = match.end()
            while i < len(source) and source[i] in " \t\n":
                i += 1
            if i < len(source) and source[i] == '"':
                parsed = parse_swift_literal_parts(source, i)
                if parsed is not None and parsed[0]:
                    skeleton = typed_skeleton(parsed[0], parsed[2])
                    yield skeleton, match.start()
    for match in RAW_STRING_ASSIGNMENT_RE.finditer(source):
        i = match.end() - 1  # position of the opening quote
        if source[i] != '"':
            continue
        parsed = parse_swift_literal_parts(source, i)
        if parsed is not None and parsed[0]:
            skeleton = typed_skeleton(parsed[0], parsed[2])
            yield skeleton, match.start()


def catalog_has(catalog_keys: set, skeleton: str) -> bool:
    """Exact runtime-key match only. %@ and %lld are distinct type
    families and never normalized into each other."""
    return skeleton in catalog_keys


def string_unit_leaves(localization) -> list:
    """Flatten a localization dict into every stringUnit leaf, including
    variations nested in a variation (a plural inside a device variant)."""
    if "stringUnit" in localization:
        return [localization["stringUnit"]]
    leaves = []
    for variation in localization.get("variations", {}).values():
        for unit in variation.values():
            leaves.extend(string_unit_leaves(unit))
    return leaves


def argument_types(specs) -> list:
    """Argument types in the order printf consumes them: by index when every
    placeholder is positional, otherwise in order of appearance."""
    if specs and all(position is not None for position, _ in specs):
        return [kind for _, kind in sorted(specs)]
    return [kind for _, kind in specs]


def placeholders_compatible(key_specs, value_specs) -> bool:
    """A translation's placeholders must substitute like the key's.

    The argument types must match as a multiset. A non-positional
    translation consumes the arguments in order, so its types must also
    follow the key's argument order ("%lld and %@" for "%@ and %lld"
    misformats). A fully positional translation (%2$lld ... %1$@) may
    reorder, but each index must name an argument of the same type, and
    every argument must appear ("%1$@ and %1$@" drops the second). A
    translation that mixes positional and non-positional placeholders is
    rejected: Foundation's argument numbering is ambiguous there.
    """
    key_types = sorted(kind for _, kind in key_specs)
    value_types = sorted(kind for _, kind in value_specs)
    if key_types != value_types:
        return False
    key_order = argument_types(key_specs)
    positions = [position for position, _ in value_specs]
    if all(position is None for position in positions):
        return [kind for _, kind in value_specs] == key_order
    if all(position is not None for position in positions):
        return (set(positions) == set(range(1, len(key_order) + 1))
                and all(key_order[position - 1] == kind
                        for position, kind in value_specs))
    return False


def normalized_language(identifier: str) -> str:
    """Comparison form of a localization identifier: the app matches
    "zh_Hans", "zh-hans" and "zh-Hans" alike, so the checker does too."""
    return identifier.replace("_", "-").lower()


# CLDR cardinal plural categories by locale (normalized), generated from
# unicode-org/cldr common/supplemental/plurals.xml (October 2026). When the
# source varies a key by plural, every shipped language must provide each
# category its rules use (Xcode's catalog editor shows the same set). An
# older iOS whose CLDR lacks a category ignores that form, so requiring the
# current set is safe. A language CLDR doesn't know only needs "other", and
# the checker says so.
PLURAL_CATEGORIES = {
    language: categories
    for categories, languages in (
        (("other",),
         "bm bo dz hnj id ig ii in ja jbo jv jw kde kea km ko lkt lo ms my "
         "nqo osa sah ses sg su th to tpi wo yo yue zh"),
        (("one", "other"),
         "af ak am an as asa ast az bal bem bez bg bho bn brx ce ceb cgg chr "
         "ckb csw da de doi dv ee el en eo et eu fa ff fi fil fo fur fy gsw "
         "gu guw ha haw hi hu hy ia ie io is jgo ji jmc ka kab kaj kcg kk "
         "kkj kl kn kok kok-latn ks ksb ku ky lb lg lij ln mas mg mgo mk ml "
         "mn mr nah nb nd ne nl nn nnh no nr nso ny nyn om or os pa pap pcm "
         "ps rm rof rwk saq sc sd sdh seh si sn so sq ss ssy st sv sw syr ta "
         "te teo tg ti tig tk tl tn tr ts tzm ug ur uz ve vi vo vun wa wae "
         "xh xog yi zu"),
        (("zero", "one", "other"),
         "blo cv ksh lag lv prg"),
        (("one", "two", "other"),
         "he iu iw naq sat se sma smi smj smn sms"),
        (("one", "few", "other"),
         "bs hr mo ro sh shi sr"),
        (("one", "many", "other"),
         "ca es fr gl it lld pt pt-pt scn vec"),
        (("one", "two", "few", "other"),
         "dsb gd hsb sl"),
        (("one", "few", "many", "other"),
         "be cs lt pl ru sk uk"),
        (("one", "two", "few", "many", "other"),
         "br ga gv mt sgs"),
        (("zero", "one", "two", "few", "many", "other"),
         "ar ars cy kw"),
    )
    for language in languages.split()
}


def plural_categories(language: str):
    """The plural categories `language` uses, or None when not on file."""
    key = normalized_language(language)
    return PLURAL_CATEGORIES.get(key) or PLURAL_CATEGORIES.get(key.split("-")[0])


def localization_for(localizations: dict, language: str) -> dict:
    """`language`'s localization, matched in any identifier spelling."""
    wanted = normalized_language(language)
    for candidate, localization in localizations.items():
        if normalized_language(candidate) == wanted:
            return localization
    return {}


def plural_variations(localization) -> list:
    """Every plural variation in a localization dict, including one nested
    in another variation (a plural inside a device variant)."""
    found = []
    for dimension, variation in localization.get("variations", {}).items():
        if dimension == "plural":
            found.append(variation)
        else:
            for unit in variation.values():
                found.extend(plural_variations(unit))
    return found


def plural_gap(entry: dict, language: str, source: str) -> list:
    """Plural categories `language` still lacks for a key the source varies
    by plural, at any depth. A localization with no plural variation stands
    for the "other" form only; a missing localization is reported
    elsewhere."""
    localizations = entry.get("localizations", {})
    if not plural_variations(localization_for(localizations, source)):
        return []
    localization = localization_for(localizations, language)
    provided = [set(plural) for plural in plural_variations(localization)]
    if not provided:
        if not string_unit_leaves(localization):
            return []
        provided = [{"other"}]
    required = plural_categories(language) or ("other",)
    return [category for category in required
            if any(category not in forms for forms in provided)]


def value_problem(language: str, value: str, key_specs):
    """What makes a non-empty value malformed, or None."""
    if MALFORMED_ESCAPE_RE.search(value):
        return (f"{language} value contains malformed literal Unicode escape "
                f"sequences (double-escaped authoring bug)")
    if not placeholders_compatible(key_specs, placeholder_specs(value)):
        return (f"{language} placeholders {placeholder_specs(value)} "
                f"do not match key placeholders {key_specs}")
    return None


def catalog_problems(catalog: dict, required_languages=(),
                     draft_languages=()) -> dict:
    """Return {key: [problems]} for every localization violation.

    Every language in `required_languages` (the shipped non-source ones)
    must localize every key, and where the source varies a key by plural,
    every shipped language (source included) must provide each plural
    category its rules use. Units of every non-draft language - the source
    included, so a stale en value like "%lld" under a "%@" key cannot
    survive (it misformats at runtime) - must be translated and non-empty.
    Draft languages may be partial or unreviewed. Whatever value ANY
    language carries must still be well-formed: no malformed escapes,
    placeholders compatible with the key, and an "other" plural form.
    """
    drafts = {normalized_language(language) for language in draft_languages}
    source = catalog.get("sourceLanguage", "en")
    shipped = sorted(set(required_languages) | {source})
    problems = {}
    for key, entry in catalog.get("strings", {}).items():
        if key in EXEMPT_KEYS:
            continue
        localizations = entry.get("localizations", {})
        for language in sorted(required_languages):
            if not string_unit_leaves(localization_for(localizations, language)):
                problems.setdefault(key, []).append(
                    f"missing {language} localization")
        for language in shipped:
            gap = plural_gap(entry, language, source)
            if gap:
                rules = plural_categories(language) or ("other",)
                problems.setdefault(key, []).append(
                    f"{language} plural lacks {', '.join(gap)} "
                    f"(its plural rules use {', '.join(rules)})")
        key_specs = placeholder_specs(key)
        for language, localization in localizations.items():
            draft = normalized_language(language) in drafts
            if any("other" not in plural
                   for plural in plural_variations(localization)):
                problems.setdefault(key, []).append(
                    f"{language} plural has no 'other' form")
            for unit in string_unit_leaves(localization):
                value = unit.get("value") or ""
                state = unit.get("state")
                problem = None
                if state != "translated" and not draft:
                    problem = f"{language} state is {state!r}, not 'translated'"
                elif not value.strip():
                    if state == "translated":
                        problem = f"{language} value is empty"
                else:
                    problem = value_problem(language, value, key_specs)
                if problem:
                    problems.setdefault(key, []).append(problem)
    return problems


def language_is_complete(catalog: dict, language: str) -> bool:
    """Would `language` pass as a shipped language in this catalog?"""
    source = catalog.get("sourceLanguage", "en")
    for key, entry in catalog.get("strings", {}).items():
        if key in EXEMPT_KEYS:
            continue
        localization = localization_for(entry.get("localizations", {}), language)
        units = string_unit_leaves(localization)
        if not units or plural_gap(entry, language, source):
            return False
        if any("other" not in plural for plural in plural_variations(localization)):
            return False
        key_specs = placeholder_specs(key)
        for unit in units:
            value = unit.get("value") or ""
            if (unit.get("state") != "translated" or not value.strip()
                    or value_problem(language, value, key_specs)):
                return False
    return True


def required_key_problems(catalog: dict, required_keys) -> dict:
    """Problems for keys the extractor cannot see (REGRESSION_KEYS). Their
    per-language problems are already in catalog_problems; this only
    reports keys missing from the catalog altogether."""
    problems = {}
    strings = catalog.get("strings", {})
    for key in required_keys:
        if key not in strings:
            problems.setdefault(key, []).append(
                "regression key absent from the catalog")
    return problems


# Every Conduit-owned catalog, in check order. Key existence is validated
# only against Localizable (call-site extraction); the others carry
# OS-resolved Siri/InfoPlist content but must cover the same languages.
SOURCE_CATALOG = "Localizable.xcstrings"
SECONDARY_CATALOGS = ("AppShortcuts.xcstrings", "InfoPlist.xcstrings")
INFO_PLIST = os.path.join("Conduit", "Info.plist")


class _JSONObject(dict):
    """A decoded JSON object that remembers which of its keys repeated."""
    repeated = ()


def _remember_repeats(pairs):
    seen = set()
    repeated = []
    for key, _value in pairs:
        if key in seen:
            repeated.append(key)
        seen.add(key)
    decoded = _JSONObject(pairs)
    decoded.repeated = repeated
    return decoded


def _repeated_keys(value, path=()):
    """Yield (path, key) for every key a JSON object in `value` repeats."""
    if isinstance(value, _JSONObject):
        for key in value.repeated:
            yield path, key
        for key, child in value.items():
            yield from _repeated_keys(child, path + (key,))
    elif isinstance(value, list):
        for child in value:
            yield from _repeated_keys(child, path)


def load_catalog(path: str):
    """Load a String Catalog. Returns (catalog, duplicates), where
    duplicates maps a catalog key to its problems: plain JSON loading
    silently keeps only the last copy of a repeated key, which hides a
    second, conflicting translation."""
    with open(path, encoding="utf-8") as handle:
        catalog = json.load(handle, object_pairs_hook=_remember_repeats)
    if not isinstance(catalog, dict) or not isinstance(catalog.get("strings"), dict):
        raise ValueError('not a String Catalog (no "strings" object)')
    duplicates = {}
    for where, key in _repeated_keys(catalog):
        if where == ("strings",):
            duplicates.setdefault(key, []).append(
                "appears more than once in the catalog JSON (only one copy "
                "survives); keep a single entry")
        elif len(where) >= 2 and where[0] == "strings":
            inner = "/".join(where[2:] + (key,))
            duplicates.setdefault(where[1], []).append(
                f"repeats {inner!r} in its JSON (only one copy survives)")
        else:
            duplicates.setdefault("/".join(where + (key,)), []).append(
                "appears more than once in the catalog JSON")
    return catalog, duplicates


def read_draft_languages(info_plist_path: str) -> list:
    """The draft localization identifiers Info.plist lists (may be empty)."""
    if not os.path.exists(info_plist_path):
        return []
    try:
        with open(info_plist_path, "rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException,
            xml.parsers.expat.ExpatError) as error:
        raise ValueError(f"unreadable: {error}") from error
    drafts = info.get(DRAFT_LANGUAGES_KEY, [])
    if not isinstance(drafts, list) or not all(
            isinstance(language, str) and language.strip() for language in drafts):
        raise ValueError(f"{DRAFT_LANGUAGES_KEY} must be an array of "
                         f"localization identifiers")
    return drafts


def catalog_languages(catalog: dict) -> set:
    """Every language with at least one localization in the catalog."""
    languages = set()
    for entry in catalog.get("strings", {}).values():
        languages.update(entry.get("localizations", {}))
    return languages


class LanguagePlan:
    """Which catalog languages ship, which are drafts, and which is the
    source. `problems` are configuration errors; `notes` are advice."""

    def __init__(self, catalogs: dict, drafts: list):
        self.problems = []
        self.notes = []
        sources = {catalog.get("sourceLanguage", "en")
                   for catalog in catalogs.values()}
        primary = catalogs.get(SOURCE_CATALOG) or next(iter(catalogs.values()), {})
        self.source = primary.get("sourceLanguage", "en")
        if len(sources) > 1:
            self.problems.append(
                f"catalogs disagree on sourceLanguage: {sorted(sources)}")
        draft_keys = {normalized_language(language) for language in drafts}
        if normalized_language(self.source) in draft_keys:
            self.problems.append(
                f"{DRAFT_LANGUAGES_KEY} lists the source language "
                f"{self.source!r}; it always ships")
        if "base" in draft_keys:
            self.problems.append(
                f"{DRAFT_LANGUAGES_KEY} lists Base; Base.lproj holds "
                f"unlocalized resources, not a language")
        # One spelling per language: Xcode builds a separate lproj for each
        # spelling, so "zh_Hans" in one catalog and "zh-Hans" in another
        # would split that language's strings across two folders.
        spellings = {}
        for catalog in catalogs.values():
            for language in catalog_languages(catalog):
                spellings.setdefault(normalized_language(language), set()).add(language)
        for forms in spellings.values():
            if len(forms) > 1:
                self.problems.append(
                    f"one language is spelled {sorted(forms)} across the "
                    f"catalogs; use a single spelling")
        present = {sorted(forms)[0] for forms in spellings.values()}
        source_key = normalized_language(self.source)
        self.shipped = sorted(
            language for language in present
            if normalized_language(language) != source_key
            and normalized_language(language) not in draft_keys)
        self.drafts = sorted(
            language for language in present
            if normalized_language(language) in draft_keys)
        for language in self.shipped:
            if plural_categories(language) is None:
                self.notes.append(
                    f"no plural rules on file for {language!r}, so only its "
                    f"'other' form is required: check its plural forms in "
                    f"Xcode, and add it to PLURAL_CATEGORIES")
        present_keys = {normalized_language(language) for language in present}
        for language in drafts:
            if normalized_language(language) not in present_keys:
                self.notes.append(
                    f"draft {language!r} has no catalog entries yet")
        for language in self.drafts:
            if all(language_is_complete(catalog, language)
                   for catalog in catalogs.values()):
                self.notes.append(
                    f"draft {language!r} is complete: remove it from "
                    f"{DRAFT_LANGUAGES_KEY} in {INFO_PLIST} to ship it")


class CatalogError(Exception):
    """A String Catalog that can't be read or parsed (for example one left
    with merge-conflict markers)."""


def check(repo_root: str):
    """Full check. Returns (checked_site_count, missing_sites,
    key_problems, language_plan). Raises CatalogError for a catalog that
    can't be read."""
    conduit = os.path.join(repo_root, "Conduit")
    catalogs = {}
    duplicates = {}
    for name in (SOURCE_CATALOG,) + SECONDARY_CATALOGS:
        path = os.path.join(conduit, name)
        if name != SOURCE_CATALOG and not os.path.exists(path):
            continue
        try:
            catalogs[name], duplicates[name] = load_catalog(path)
        except (OSError, ValueError) as error:
            # json.JSONDecodeError and UnicodeDecodeError are ValueErrors.
            raise CatalogError(f"Conduit/{name}: {error}") from error
    catalog = catalogs[SOURCE_CATALOG]
    catalog_keys = set(catalog["strings"])

    key_problems = {}
    try:
        drafts = read_draft_languages(os.path.join(repo_root, INFO_PLIST))
    except ValueError as error:
        drafts = []
        key_problems[f"{INFO_PLIST}: {DRAFT_LANGUAGES_KEY}"] = [str(error)]
    plan = LanguagePlan(catalogs, drafts)
    if plan.problems:
        key_problems.setdefault("languages", []).extend(plan.problems)

    missing = {}
    checked = 0
    for dirpath, _dirnames, filenames in os.walk(conduit):
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
            for skeleton, offset in extract_sites(source):
                checked += 1
                if skeleton in EXEMPT_KEYS:
                    continue
                if catalog_has(catalog_keys, skeleton):
                    continue
                line = source.count("\n", 0, offset) + 1
                rel = os.path.relpath(path, repo_root)
                missing.setdefault(skeleton, []).append(f"{rel}:{line}")

    for name, current in catalogs.items():
        prefix = "" if name == SOURCE_CATALOG else f"{name}: "
        for key, problems in duplicates[name].items():
            key_problems.setdefault(f"{prefix}{key}", []).extend(problems)
        for key, problems in catalog_problems(
                current, plan.shipped, plan.drafts).items():
            key_problems.setdefault(f"{prefix}{key}", []).extend(problems)
    for key, problems in required_key_problems(catalog, REGRESSION_KEYS).items():
        key_problems.setdefault(key, []).extend(problems)
    return checked, missing, key_problems, plan


def describe(languages) -> str:
    return ", ".join(languages) if languages else "none"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify every localizable call site resolves in "
                    "Conduit/Localizable.xcstrings and every shipped "
                    "language has a complete, well-formed translation.")
    parser.add_argument("--repo-root", default=".",
                        help="Repository root (default: current directory).")
    args = parser.parse_args()

    try:
        checked, missing, key_problems, plan = check(args.repo_root)
    except CatalogError as error:
        print(f"FAIL: {error}")
        return 1
    print(f"Languages: source {plan.source}; shipped {describe(plan.shipped)}; "
          f"drafts {describe(plan.drafts)}.")

    failed = False
    if missing:
        failed = True
        print(f"FAIL: {len(missing)} localizable key(s) missing from the "
              f"String Catalog ({checked} call sites checked):")
        for skeleton in sorted(missing):
            for location in missing[skeleton]:
                print(f"  {location}")
            print(f"    key: {skeleton!r}")
    else:
        print(f"OK: {checked} localizable call sites all resolve in the catalog.")

    if key_problems:
        failed = True
        print(f"FAIL: {len(key_problems)} catalog key(s) have localization "
              f"problems (shipped: {describe(plan.shipped)}):")
        for key in sorted(key_problems):
            print(f"    {key!r}")
            for problem in key_problems[key]:
                print(f"        {problem}")
    else:
        print(f"OK: every catalog key is translated in every shipped language "
              f"({describe(plan.shipped)}) with type-matched placeholders.")
    for note in plan.notes:
        print(f"NOTE: {note}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
