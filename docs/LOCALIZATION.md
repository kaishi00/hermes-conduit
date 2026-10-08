# Localization

Conduit's UI languages are data, not code. Adding a language means adding
its translations to the String Catalogs and passing CI; no Swift or tooling
change is needed.

## Where the languages come from

- **Source language**: `en`, the catalogs' `sourceLanguage` and the app's
  development region. Catalog keys are the English source strings, and any
  key a language lacks falls back to them.
- **Shipped languages**: every other language that appears in
  `Conduit/Localizable.xcstrings`, `AppShortcuts.xcstrings` or
  `InfoPlist.xcstrings`, except drafts. At runtime `AppLocalizations` reads
  them from the built app's lproj folders, and the App language picker
  offers System Default plus each one, labelled by its own translation of
  the `Name of this language` entry.
- **Draft languages**: identifiers listed in `Conduit/Info.plist` under
  `ConduitDraftLanguages`. A draft can be partial. The last build phase
  (`scripts/strip-draft-localizations.py`) removes its lproj from the app,
  so it is not listed on the App Store, not offered in iOS Settings or the
  picker, and never shown under System Default.

## Adding a language

1. Add the language to `Localizable.xcstrings` in Xcode's catalog editor.
   Use the identifier Xcode offers: the bare language code (`ja`, `fr`)
   unless a regional or script variant is deliberate (`pt-BR`, `zh-Hant`).
2. While the translation is incomplete, add the identifier to
   `ConduitDraftLanguages`. Drafts can land on `main` in small pieces.
3. Translate every entry in all three catalogs. Translate
   `Name of this language` as the language's own name (for example 日本語).
4. Run `python3 scripts/check-l10n-coverage.py --repo-root .`. It lists
   what is missing or malformed and says when a draft is complete.
5. Remove the identifier from `ConduitDraftLanguages`. The language now
   ships. If a local build doesn't show it in the picker, clean the build
   folder once: the strip phase deleted its lproj from the earlier build.

To preview a draft in the simulator, remove it from `ConduitDraftLanguages`
in your working copy only.

## Translating with worksheets

The catalogs are large JSON files, so translate through
`scripts/l10n.py` rather than editing them by hand:

```sh
python3 scripts/l10n.py export de -o de.json   # what German still lacks
# fill in each entry's "translation", then:
python3 scripts/l10n.py import de.json
python3 scripts/check-l10n-coverage.py --repo-root .
```

Each worksheet entry carries the English `source`, the plural `forms` the
language needs when the source varies by plural, and `where` the app uses
the string. A plural translation is an object with one value per form
(`{"one": "%lld Datei", "other": "%lld Dateien"}`). `export --all`
includes what is already translated, which is the easy way to hand a
whole language to a reviewer. `rename` and `remove` keep translations in
step when a call site's wording or placeholder types change.

## Counts and plurals

A number the text counts goes into the key as an `Int` (`%lld`) and the
English source varies it by plural, even when both English forms read
the same: other languages need their own forms (Russian and Polish have
four). One plural drives a whole string, so a key holds at most one
count. Everything else stays out of plural rules:

- A number that isn't counted (an HTTP status, a process id, a
  position) goes in as `String(x)`, a `%@`.
- In a string with two numbers, the one that isn't counted goes in as
  `String(x)` ("Show %lld more rows (%@ of %@ left)"), or the string is
  split into two keys, each with its own plural ("%lld active",
  "%lld inactive").
- A number shown as a label needs no plural forms: alone in parentheses
  ("Runs (%lld)") or ending the string after a colon ("Jobs: %lld").

Never build the singular in code (`count == 1 ? "1 task" : "…tasks"`):
put both forms in the catalog. The checker reads an interpolation as an
`Int` from its shape (`.count`, a name ending in `Count`, `Int(…)`), so
write counts that way; a plain `\(remaining)` is read as `%@` and never
finds its key at runtime.

Durations and lists Conduit formats itself use
`AppLocalization.formattingLocale`, so they follow the UI language
(`DateComponentsFormatter`, `.formatted(.list(…))`).

## What CI checks

`check-l10n-coverage.py` runs in the `Plan & validate` job:

- every localizable call site resolves to a catalog key whose placeholder
  types (`%@` vs `%lld`) match what the code passes;
- every shipped language translates every key in every catalog, with
  state `translated` and a non-empty value;
- every integer placeholder is a count with English plural forms, one per
  key (labels excepted, see above), and no count is passed as
  `String(count)` in front of a plural noun;
- where the English source varies a key by plural, every shipped language
  provides each plural form its own rules use (French: one, many, other;
  Japanese: other). The table is `PLURAL_CATEGORIES` in the checker,
  generated from CLDR; a language CLDR doesn't know only needs `other`, and
  the checker says so;
- each language is spelled the same way in every catalog;
- every value in every language, drafts included, keeps the key's
  placeholders in the same order, or reorders all of them with positional
  ones (`%2$lld … %1$@`; mixing `%1$@` with a bare `%lld` fails), and has no
  literal `\uXXXX` escapes;
- no catalog repeats a key.

The unit tests in `AppLanguageTests` run over whatever languages the build
ships, so a new language is covered without editing them.

## What never localizes

Protocol and configuration values stay byte-identical in every language:
slash command names, config option values such as `auto`, `native`,
`manual` and `smart`, and speech, transcription and provider language
settings. Only their display labels go through the catalog (for config
values, `ProfileConfigValueDisplay`). `ConfigFieldLocalizationTests` and
`AppLanguageTests` check this under every shipped language.
