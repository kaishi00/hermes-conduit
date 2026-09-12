#!/usr/bin/env python3
"""Localization catalog coverage: every localizable call site must resolve.

Scans Conduit Swift sources for sites that look up String Catalog keys -

  1. String(localized: "...") / String(localized: "...\(expr)...") - the
     interpolated skeleton must exist in Localizable.xcstrings as a format
     string (either %@ or %lld placeholder forms are accepted).
  2. SwiftUI literal initializers (Text/Button/Label/TextField/SecureField/
     Toggle/NavigationLink/Picker) - a leading string literal is a
     LocalizedStringKey and is checked the same way.

A static (non-interpolated) key must exist verbatim. Any unresolved site is
reported with file:line and fails the run, so a translated call site can
never silently render English again. Sites that are intentionally dynamic
belong in EXEMPT_KEYS.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

# SwiftUI initializers whose first argument is a LocalizedStringKey when a
# string literal is passed directly. Variables/interpolations elsewhere are
# not statically checkable and are simply skipped.
SWIFTUI_LOCALIZED_INITIALIZERS = (
    "Text", "Button", "Label", "TextField", "SecureField",
    "Toggle", "NavigationLink", "Picker",
)

# Keys that are intentionally not statically present in the catalog: pure
# variable passthroughs, separators, brand/protocol names, and placeholder
# tokens that must never be translated.
EXEMPT_KEYS = frozenset({
    "%@",            # verbatim variable passthrough
    "%@ %@",         # two-variable passthrough
    "%@/%@",         # numeric done/total counters
    "%@.",           # numbered step prefix ("1.")
    "/", "•",        # separators
    "v%@",           # version prefix ("v1.2.3")
    "×%@",           # multiplier badge
    "A",             # typography size sample glyph
    "Conduit", "GitHub", "Hermes", "HTTP", "HTTPS",  # brand/protocol names
    "https://hermes.example", "https://push.milim.dev",  # literal URLs
    "skill-name",    # example placeholder token
})

CALL_RE = re.compile(r"\bString\s*\(\s*localized\s*:")
SWIFTUI_RE = re.compile(
    r"\b(" + "|".join(SWIFTUI_LOCALIZED_INITIALIZERS) + r")\s*\(")


def parse_swift_string_literal(source: str, start: int):
    """Parse a Swift string literal starting at source[start] == '"'.

    Returns (skeleton, end_index, has_interpolation) or None when the
    literal is unterminated at EOF. Interpolations \\(...) collapse to a
    single placeholder; nested strings inside them are skipped.
    """
    assert source[start] == '"'
    out = []
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
                while j < len(source) and depth:
                    if source[j] == '"':
                        parsed = parse_swift_string_literal(source, j)
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
                out.append("%@")
                i = j
            else:
                escapes = {"n": "\n", "t": "\t", "r": "\r", "0": "\0",
                           "\\": "\\", '"': '"', "'": "'"}
                out.append(escapes.get(nxt, nxt))
                i += 2
        elif ch == '"':
            return "".join(out), i + 1, "%@" in out
        else:
            out.append(ch)
            i += 1
    return None


def extract_sites(source: str):
    """Yield (key_skeleton, offset) for every checkable call site."""
    for match in CALL_RE.finditer(source):
        i = match.end()
        while i < len(source) and source[i] in " \t\n":
            i += 1
        if i < len(source) and source[i] == '"':
            parsed = parse_swift_string_literal(source, i)
            if parsed is not None and parsed[0]:
                yield parsed[0], match.start()
    for match in SWIFTUI_RE.finditer(source):
        i = match.end()
        while i < len(source) and source[i] in " \t\n":
            i += 1
        if i < len(source) and source[i] == '"':
            parsed = parse_swift_string_literal(source, i)
            if parsed is not None and parsed[0]:
                yield parsed[0], match.start()


def catalog_has(catalog_keys: set, skeleton: str) -> bool:
    if skeleton in catalog_keys:
        return True
    if "%@" in skeleton:
        return skeleton.replace("%@", "%lld") in catalog_keys
    return False


def check(repo_root: str):
    catalog_path = os.path.join(repo_root, "Conduit", "Localizable.xcstrings")
    with open(catalog_path, encoding="utf-8") as handle:
        catalog = json.load(handle)
    catalog_keys = set(catalog["strings"])

    missing = {}
    checked = 0
    source_root = os.path.join(repo_root, "Conduit")
    for dirpath, _dirnames, filenames in os.walk(source_root):
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
    return checked, missing


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify every localizable call site resolves in "
                    "Conduit/Localizable.xcstrings.")
    parser.add_argument("--repo-root", default=".",
                        help="Repository root (default: current directory).")
    args = parser.parse_args()

    checked, missing = check(args.repo_root)
    if missing:
        print(f"FAIL: {len(missing)} localizable key(s) missing from the "
              f"String Catalog ({checked} call sites checked):")
        for skeleton in sorted(missing):
            for location in missing[skeleton]:
                print(f"  {location}")
            print(f"    key: {skeleton!r}")
        return 1
    print(f"OK: {checked} localizable call sites all resolve in the catalog.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
