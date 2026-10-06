#!/usr/bin/env python3
"""Remove draft localizations from a built Conduit.app.

A draft language (Conduit/Info.plist's ConduitDraftLanguages array) has
translation work in the String Catalogs but is not complete yet. Xcode
compiles every catalog language into an lproj, and an lproj in the app is a
shipped language: the App Store lists it, iOS Settings offers it as
Conduit's language, and System Default shows it on devices set to it. The
Conduit target runs this as its last build phase, so a draft never reaches
the app; scripts/check-l10n-coverage.py holds every other language to
complete coverage.

To preview a draft in the simulator, take it out of ConduitDraftLanguages
locally (don't commit that until the checker passes for it).

Usage (Xcode build phase):
  strip-draft-localizations.py --info-plist "$SRCROOT/$INFOPLIST_FILE" \\
      --bundle "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH" \\
      --development-language "$DEVELOPMENT_LANGUAGE"
"""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import sys
import xml.parsers.expat

DRAFT_LANGUAGES_KEY = "ConduitDraftLanguages"


def normalized_language(identifier: str) -> str:
    """The app matches "zh_Hans", "zh-hans" and "zh-Hans" alike."""
    return identifier.replace("_", "-").lower()


def draft_languages(info_plist_path: str) -> list:
    with open(info_plist_path, "rb") as handle:
        info = plistlib.load(handle)
    drafts = info.get(DRAFT_LANGUAGES_KEY, [])
    if not isinstance(drafts, list) or not all(
            isinstance(language, str) and language.strip() for language in drafts):
        raise ValueError(f"{DRAFT_LANGUAGES_KEY} must be an array of "
                         f"localization identifiers")
    return drafts


def strip(bundle_path: str, drafts) -> list:
    """Delete the lproj of every draft language from the bundle. Returns the
    removed directory names."""
    wanted = {normalized_language(language) for language in drafts}
    removed = []
    if not wanted:
        return removed
    for name in sorted(os.listdir(bundle_path)):
        stem, extension = os.path.splitext(name)
        if extension == ".lproj" and normalized_language(stem) in wanted:
            shutil.rmtree(os.path.join(bundle_path, name))
            removed.append(name)
    return removed


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Remove draft localizations from a built app bundle.")
    parser.add_argument("--info-plist", required=True,
                        help="Info.plist that lists the draft languages.")
    parser.add_argument("--bundle", required=True,
                        help="The built app's resources folder.")
    parser.add_argument("--development-language", default="",
                        help="The source language, which can never be a draft.")
    args = parser.parse_args()

    try:
        drafts = draft_languages(args.info_plist)
    except (OSError, ValueError, plistlib.InvalidFileException,
            xml.parsers.expat.ExpatError) as error:
        print(f"error: {args.info_plist}: {error}")
        return 1
    source = normalized_language(args.development_language)
    if source and any(normalized_language(language) == source for language in drafts):
        print(f"error: {args.info_plist}: {DRAFT_LANGUAGES_KEY} lists the "
              f"development language {args.development_language!r}; it always ships")
        return 1
    try:
        removed = strip(args.bundle, drafts)
    except OSError as error:
        print(f"error: {args.bundle}: {error}")
        return 1
    for name in removed:
        print(f"note: removed draft localization {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
