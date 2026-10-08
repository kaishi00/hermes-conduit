#!/usr/bin/env python3
"""Move translations in and out of Conduit's String Catalogs.

The catalogs are large JSON files that Xcode also edits, so hand-editing
them for one language at a time is slow and easy to get wrong. This tool
exports what a language needs as a small JSON worksheet and writes a
filled-in worksheet back, in the layout Xcode writes, so the diff holds
only the translation.

  export LANGUAGE [--all] [-o FILE]
      Every entry LANGUAGE lacks (all entries with --all), with its English
      source, the plural forms the language needs, and where the app uses
      it. Fill in each "translation" and import the file.

  import FILE [FILE ...] [--create]
      Write each entry's "translation" into its catalog for the worksheet's
      language. An empty or null translation is skipped. Importing "en"
      replaces the source's own value, for example to give it plural forms.
      --create adds keys the catalog lacks, which is how a new UI string
      gets its translations in every shipped language at once.

  rename OLD NEW [--catalog PATH]
      Give a key a new spelling and keep its translations: for a call site
      whose wording or placeholder types changed (`%lld` became `%@`). Each
      value's placeholders change the same way the key's did.

  remove KEY [KEY ...] [--catalog PATH]
      Delete keys no call site uses any more.

After any change, run scripts/check-l10n-coverage.py. See
docs/LOCALIZATION.md.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Every catalog the app and its targets ship, in the order worksheets list
# them.
CATALOGS = (
    "Conduit/Localizable.xcstrings",
    "Conduit/AppShortcuts.xcstrings",
    "Conduit/InfoPlist.xcstrings",
    "ConduitWatch/Localizable.xcstrings",
    "ConduitWatch/InfoPlist.xcstrings",
)

# The Swift sources whose call sites each Localizable catalog serves, for
# the worksheet's "where" hints.
SITE_ROOTS = {
    "Conduit/Localizable.xcstrings": ("Conduit", "Shared"),
    "ConduitWatch/Localizable.xcstrings": ("ConduitWatch", "Shared"),
}


def _checker():
    spec = importlib.util.spec_from_file_location(
        "check_l10n_coverage", os.path.join(REPO_ROOT, "scripts", "check-l10n-coverage.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECKER = _checker()


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def save(path: str, catalog: dict) -> None:
    """Write a catalog the way Xcode does: two-space indent, " : " between
    key and value, unescaped Unicode, trailing newline."""
    text = json.dumps(catalog, indent=2, separators=(",", " : "), ensure_ascii=False)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text + "\n")


def source_text(key: str, entry: dict, source: str):
    """The source's text for a key: its plural forms as a dict, else its
    value, which defaults to the key."""
    localization = CHECKER.localization_for(entry.get("localizations", {}), source)
    plural = localization.get("variations", {}).get("plural")
    if plural:
        return {form: case.get("stringUnit", {}).get("value", "")
                for form, case in plural.items()}
    return localization.get("stringUnit", {}).get("value") or key


def translation_of(localization: dict):
    """A localization's current text in worksheet form, or None."""
    plural = localization.get("variations", {}).get("plural")
    if plural:
        return {form: case.get("stringUnit", {}).get("value", "")
                for form, case in plural.items()}
    value = localization.get("stringUnit", {}).get("value")
    return value if value else None


def _unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def localization_from(translation) -> dict:
    """Catalog form of a worksheet translation: a plain value, or plural
    forms listed in CLDR order."""
    if isinstance(translation, str):
        return _unit(translation)
    order = ("zero", "one", "two", "few", "many", "other")
    forms = {form: _unit(translation[form]) for form in order if translation.get(form)}
    unknown = set(translation) - set(order)
    if unknown:
        raise ValueError(f"unknown plural forms {sorted(unknown)}")
    return {"variations": {"plural": forms}}


def set_localization(entry: dict, language: str, localization: dict) -> None:
    """Store `localization` under the catalog's existing spelling of
    `language` (or `language` itself), keeping languages in Xcode's
    alphabetical order."""
    localizations = entry.setdefault("localizations", {})
    wanted = CHECKER.normalized_language(language)
    spelling = next((existing for existing in localizations
                     if CHECKER.normalized_language(existing) == wanted), language)
    localizations[spelling] = localization
    entry["localizations"] = dict(sorted(localizations.items()))


def call_sites(catalog_path: str) -> dict:
    """{key: ["file:line", ...]} for the catalog's Swift call sites."""
    sites = {}
    for root in SITE_ROOTS.get(catalog_path, ()):
        for dirpath, _dirnames, filenames in os.walk(os.path.join(REPO_ROOT, root)):
            for name in sorted(filenames):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, name)
                with open(path, encoding="utf-8") as handle:
                    # Offsets index the comment-blanked text, which keeps
                    # the file's line breaks.
                    source = CHECKER.strip_comment_lines(handle.read())
                for skeleton, offset in CHECKER.extract_sites(source):
                    line = source.count("\n", 0, offset) + 1
                    sites.setdefault(skeleton, []).append(
                        f"{os.path.relpath(path, REPO_ROOT)}:{line}")
    return sites


def export(language: str, include_all: bool) -> dict:
    entries = []
    for catalog_path in CATALOGS:
        path = os.path.join(REPO_ROOT, catalog_path)
        if not os.path.exists(path):
            continue
        catalog = load(path)
        source = catalog.get("sourceLanguage", "en")
        sites = call_sites(catalog_path)
        forms = list(CHECKER.plural_categories(language) or ("other",))
        for key, entry in catalog.get("strings", {}).items():
            if key in CHECKER.EXEMPT_KEYS or entry.get("shouldTranslate") is False:
                continue
            localization = CHECKER.localization_for(entry.get("localizations", {}), language)
            current = translation_of(localization)
            complete = current is not None and CHECKER.language_is_complete(
                {"sourceLanguage": source, "strings": {key: entry}}, language)
            if complete and not include_all:
                continue
            item = {"catalog": catalog_path, "key": key,
                    "source": source_text(key, entry, source)}
            if isinstance(item["source"], dict):
                item["forms"] = forms
            if entry.get("comment"):
                item["comment"] = entry["comment"]
            if sites.get(key):
                item["where"] = sites[key][:3]
            item["translation"] = current
            entries.append(item)
    return {"language": language, "entries": entries}


def import_worksheets(paths, create: bool = False) -> int:
    catalogs = {}
    written = 0
    for worksheet_path in paths:
        worksheet = load(worksheet_path)
        language = worksheet["language"]
        for item in worksheet["entries"]:
            translation = item.get("translation")
            if not translation:
                continue
            catalog_path = item["catalog"]
            if catalog_path not in catalogs:
                catalogs[catalog_path] = load(os.path.join(REPO_ROOT, catalog_path))
            strings = catalogs[catalog_path]["strings"]
            if item["key"] not in strings:
                if not create:
                    raise KeyError(f"{catalog_path}: no key {item['key']!r} (pass --create for a new string)")
                strings[item["key"]] = {"localizations": {}}
            set_localization(strings[item["key"]], language, localization_from(translation))
            written += 1
    for catalog_path, catalog in catalogs.items():
        save(os.path.join(REPO_ROOT, catalog_path), catalog)
    return written


def _placeholders(text: str):
    """(start, end, position, kind) of each printf placeholder, read the
    way the coverage checker reads them ("%%" and prose like "100%ig"
    are not placeholders)."""
    found = []
    i = 0
    while i < len(text):
        match = CHECKER._PLACEHOLDER_RE.match(text, i) if text[i] == "%" else None
        if not match:
            i += 1
            continue
        if match.group(0) != "%%":
            found.append((match.start(), match.end(), match.group(1), match.group(2)))
        i = match.end()
    return found


def _argument_kinds(key: str) -> list:
    """The key's placeholder kinds ("@", "lld") in argument order."""
    found = _placeholders(key)
    if found and all(position for _, _, position, _ in found):
        found = sorted(found, key=lambda spec: int(spec[2]))
    return [kind for _, _, _, kind in found]


def _retyped(value: str, kinds: list) -> str:
    """`value` with each placeholder given the kind `kinds` lists for the
    argument it formats, keeping any positional index."""
    out = []
    last = 0
    for order, (start, end, position, _kind) in enumerate(_placeholders(value)):
        index = int(position) - 1 if position else order
        if index >= len(kinds):
            continue
        out.append(value[last:start])
        out.append(f"%{position}${kinds[index]}" if position else f"%{kinds[index]}")
        last = end
    out.append(value[last:])
    return "".join(out)


def _rewrite_values(localization: dict, rewrite) -> dict:
    copy = json.loads(json.dumps(localization))
    for unit in CHECKER.string_unit_leaves(copy):
        if unit.get("value"):
            unit["value"] = rewrite(unit["value"])
    return copy


def rename(old: str, new: str, catalog_path: str) -> None:
    path = os.path.join(REPO_ROOT, catalog_path)
    catalog = load(path)
    strings = catalog["strings"]
    if old not in strings:
        raise KeyError(f"{catalog_path}: no key {old!r}")
    if new in strings:
        raise KeyError(f"{catalog_path}: {new!r} already exists")
    kinds = _argument_kinds(new)
    if len(_argument_kinds(old)) != len(kinds):
        raise ValueError("the new key must keep the old key's number of placeholders")
    renamed = {}
    for key, entry in strings.items():
        if key != old:
            renamed[key] = entry
            continue
        entry = json.loads(json.dumps(entry))
        for language, localization in entry.get("localizations", {}).items():
            entry["localizations"][language] = _rewrite_values(
                localization, lambda value: _retyped(value, kinds))
        renamed[new] = entry
    catalog["strings"] = renamed
    save(path, catalog)


def remove(keys, catalog_path: str) -> None:
    path = os.path.join(REPO_ROOT, catalog_path)
    catalog = load(path)
    for key in keys:
        if key not in catalog["strings"]:
            raise KeyError(f"{catalog_path}: no key {key!r}")
        del catalog["strings"][key]
    save(path, catalog)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    export_parser = commands.add_parser("export", help="write a language's worksheet")
    export_parser.add_argument("language")
    export_parser.add_argument("--all", action="store_true",
                               help="include entries the language already translates")
    export_parser.add_argument("-o", "--output", help="worksheet path (default: stdout)")
    import_parser = commands.add_parser("import", help="write worksheets into the catalogs")
    import_parser.add_argument("worksheets", nargs="+")
    import_parser.add_argument("--create", action="store_true",
                               help="add keys the catalog doesn't have yet (a new UI string)")
    rename_parser = commands.add_parser("rename", help="respell a key, keeping its translations")
    rename_parser.add_argument("old")
    rename_parser.add_argument("new")
    rename_parser.add_argument("--catalog", default=CATALOGS[0])
    remove_parser = commands.add_parser("remove", help="delete unused keys")
    remove_parser.add_argument("keys", nargs="+")
    remove_parser.add_argument("--catalog", default=CATALOGS[0])
    args = parser.parse_args(argv)

    try:
        if args.command == "export":
            text = json.dumps(export(args.language, args.all), indent=2, ensure_ascii=False) + "\n"
            if args.output:
                with open(args.output, "w", encoding="utf-8") as handle:
                    handle.write(text)
            else:
                sys.stdout.write(text)
        elif args.command == "import":
            print(f"Wrote {import_worksheets(args.worksheets, args.create)} translation(s).")
        elif args.command == "rename":
            rename(args.old, args.new, args.catalog)
        elif args.command == "remove":
            remove(args.keys, args.catalog)
    except (KeyError, ValueError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
