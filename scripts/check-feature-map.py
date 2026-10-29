#!/usr/bin/env python3
"""Fail when docs/FEATURE_MAP.md names a file that isn't there, or an entry
is missing a part.

The feature map lists, for each feature with siblings, where each sibling's
code lives, so a thread changing one finds the rest. A path that no longer
exists sends that thread to the wrong place, so every path in backticks is
checked: Conduit's in this checkout, and those starting notifier/ on
hermes-conduit-notifier main. Every entry (a `## ` section) has its parts in
one order, so each reads the same: Siblings (listed on that line), Code
(naming at least one path), Rulings, Open gaps, and a Checked line with the
date and the PR or commit it was checked at.

On a pull request, CI also passes the PR's number and the base's copy of the
map: an entry the PR adds or edits names that PR on its Checked line, so the
line says who checked it last, not the commit the branch started from. A PR
into another branch (`pulse`, `linked-rooms`) that merges main also gets
main's copies where the PR meets main and where its base did: an entry main
changed between the two that matches main's copy came in with the merge and
keeps main's Checked line.

A notifier file missing on main fails. If GitHub can't be reached for that
lookup, the check warns and skips it, so an outage doesn't block every PR.
"""

import argparse
import http.client
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

MAP = os.path.join("docs", "FEATURE_MAP.md")
NOTIFIER_PREFIX = "notifier/"
NOTIFIER_RAW = "https://raw.githubusercontent.com/kaishi00/hermes-conduit-notifier/main/"
UNREACHABLE = (OSError, http.client.HTTPException)

CODE_SPAN = re.compile(r"`([^`\n]+)`")
# A file named without a directory: README.md, project.yml.
FILE_NAME = re.compile(r"^[\w.+-]+\.(swift|py|md|mjs|js|json|ya?ml|xcstrings|sh|plist|txt|entitlements)$")
# What every entry has, as the line each part starts with, in this order.
PARTS = ["**Siblings:**", "**Code**", "**Rulings**", "**Open gaps**", "**Checked:**"]
DATE = re.compile(r"\b\d{4}-\d{2}-\d{2}\b")
# A PR (#1167) or a commit (64d53c3): hex with a digit in it, so not a word.
CHECKED_AT = re.compile(r"#\d+|\b(?=[a-f]*\d)[0-9a-f]{7,40}\b")


class Unreachable(Exception):
    """GitHub couldn't be asked."""


def is_path(span):
    """Whether a code span names a file or directory rather than a symbol, a
    method or a route: `Conduit/Voice/VoiceTypes.swift`, `docs/`,
    `.github/workflows/ci.yml`, `.coderabbit.yaml` and `notifier/events.py`
    are paths; `session.steer`, `answer_approval`, `.interrupted` and
    `/voice-tools` are not."""
    if any(char.isspace() for char in span) or "://" in span or span.startswith(("/", "-")):
        return False
    return "/" in span or FILE_NAME.match(span) is not None


def paths(text):
    """[(line number, path)] for every path in a code span, outside fenced blocks."""
    found = []
    fenced = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
        elif not fenced:
            found += [(number, span) for span in CODE_SPAN.findall(line) if is_path(span)]
    return found


def entries(text):
    """[(line number, name, [(line number, line)])] for each `## ` section."""
    found = []
    fenced = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
        elif fenced:
            continue
        elif line.startswith("## "):
            found.append((number, line[3:].strip(), []))
        elif found:
            found[-1][2].append((number, line))
    return found


def shape_problems(text):
    """[(line number, problem)] for entries that miss a part, repeat or
    reorder one, or repeat another entry's name."""
    problems = []
    found = entries(text)
    if not found:
        return [(1, "No entries: each feature is a `## ` section.")]
    seen = {}
    for number, name, lines in found:
        if name.lower() in seen:
            problems.append((number, f"Two entries are called {name!r} (the other is on line "
                                     f"{seen[name.lower()]}): give each its own name, or merge them."))
        seen.setdefault(name.lower(), number)
        starts = {part: [n for n, line in lines if line.startswith(part)] for part in PARTS}
        missing = [part.strip("*:") for part in PARTS if not starts[part]]
        if missing:
            problems.append((number, f"{name!r} has no {', '.join(missing)}: every entry has "
                                     "Siblings, Code, Rulings, Open gaps and Checked, in that "
                                     "order (write \"- None known.\" when there's nothing)."))
            continue
        repeated = [part.strip("*:") for part in PARTS if len(starts[part]) > 1]
        if repeated:
            problems.append((number, f"{name!r} has {', '.join(repeated)} more than once."))
            continue
        order = [starts[part][0] for part in PARTS]
        if order != sorted(order):
            problems.append((number, f"{name!r} has its parts out of order: Siblings, Code, "
                                     "Rulings, Open gaps, Checked."))
            continue
        siblings = next(line for n, line in lines if n == order[0])
        if not siblings[len(PARTS[0]):].strip():
            problems.append((order[0], f"{name!r} names no siblings: list them on the Siblings "
                                       "line, after **Siblings:**."))
        code = "\n".join(line for n, line in lines if order[1] <= n < order[2])
        if not any(is_path(span) for span in CODE_SPAN.findall(code)):
            problems.append((order[1], f"{name!r} names no path under Code: list where each "
                                       "sibling's code lives, in backticks."))
        checked = next(line for n, line in lines if n == order[4])
        if not (DATE.search(checked) and CHECKED_AT.search(checked)):
            problems.append((order[4], f"{name!r}: the Checked line needs the date it was "
                                       "checked against the code (YYYY-MM-DD) and the PR or "
                                       "commit (#1167, 64d53c3)."))
    return problems


def unchecked_edits(base_text, text, pr, main_text=None, main_base_text=None):
    """[(line number, problem)] for entries the PR adds or edits whose Checked
    line doesn't name it. Given main's map where the PR meets main and where
    its base did (a PR into another branch that merges main), an entry main
    changed between the two that matches main's copy came in with main, not
    from the PR."""
    def body(lines):
        # Blank lines at the end come and go as entries are added after it.
        return "\n".join(line.rstrip() for _, line in lines).strip()

    def bodies(map_text):
        return {name.lower(): body(lines) for _, name, lines in entries(map_text)}

    before = bodies(base_text)
    from_main = {}
    if main_text is not None and main_base_text is not None:
        main_before = bodies(main_base_text)
        from_main = {name: copy for name, copy in bodies(main_text).items()
                     if main_before.get(name) != copy}
    named = re.compile(rf"#{pr}\b")
    problems = []
    for _, name, lines in entries(text):
        if body(lines) in (before.get(name.lower()), from_main.get(name.lower())):
            continue
        checked = [(n, line) for n, line in lines if line.startswith(PARTS[4])]
        if checked and not named.search(checked[0][1]):
            problems.append((checked[0][0], f"{name!r} changes in this PR, so its Checked line "
                                            f"names it: \"**Checked:** <today>, #{pr}.\""))
    return problems


def on_notifier_main(path, attempts=3):
    """Whether hermes-conduit-notifier main has this file."""
    request = urllib.request.Request(NOTIFIER_RAW + urllib.parse.quote(path), method="HEAD")
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=15):
                return True
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return False
            if attempt == attempts - 1:
                raise Unreachable(error) from error
            print(f"fetch failed ({error}), retrying", file=sys.stderr)
        except UNREACHABLE as error:
            if attempt == attempts - 1:
                raise Unreachable(error) from error
            print(f"fetch failed ({error}), retrying", file=sys.stderr)
        time.sleep(2 ** attempt)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--notifier-root",
                        help="check notifier/ paths in this checkout instead of on GitHub")
    parser.add_argument("--pr", type=int,
                        help="the pull request's number: entries it adds or edits name it")
    parser.add_argument("--base-map", help="the map on the PR's base, to tell which entries it edits")
    parser.add_argument("--main-map",
                        help="for a PR into another branch that merges main, the map on main where "
                             "the PR meets it")
    parser.add_argument("--main-base-map",
                        help="with --main-map, the map on main where the PR's base meets it: an entry "
                             "main changed since then that matches --main-map came in with main")
    args = parser.parse_args(argv)
    if bool(args.pr) != bool(args.base_map):
        parser.error("--pr and --base-map go together")
    if bool(args.main_map) != bool(args.main_base_map):
        parser.error("--main-map and --main-base-map go together")
    if args.main_map and not args.pr:
        parser.error("--main-map and --main-base-map go with --pr and --base-map")

    try:
        with open(os.path.join(args.repo_root, MAP), encoding="utf-8") as fh:
            text = fh.read()
    except OSError as error:
        print(f"::error::Couldn't read {MAP} in {os.path.abspath(args.repo_root)} "
              f"({error.strerror}).")
        return 1
    problems = shape_problems(text)
    if args.pr:
        try:
            with open(args.base_map, encoding="utf-8") as fh:
                base_text = fh.read()
        except OSError as error:
            print(f"::error::Couldn't read the base's map {args.base_map} ({error.strerror}).")
            return 1
        main_text = main_base_text = None
        if args.main_map:
            try:
                with open(args.main_map, encoding="utf-8") as fh:
                    main_text = fh.read()
                with open(args.main_base_map, encoding="utf-8") as fh:
                    main_base_text = fh.read()
            except OSError as error:
                print(f"::error::Couldn't read main's map {error.filename} ({error.strerror}).")
                return 1
        problems += unchecked_edits(base_text, text, args.pr, main_text, main_base_text)
    notifier = {}
    found = paths(text)
    for number, path in found:
        if path.startswith(NOTIFIER_PREFIX):
            notifier.setdefault(path[len(NOTIFIER_PREFIX):], number)
            continue
        local = os.path.join(args.repo_root, path)
        if not (os.path.isdir(local) if path.endswith("/") else os.path.isfile(local)):
            problems.append((number, f"{path} isn't in this repo. Point the entry at where "
                                     "that code lives now."))

    for path, number in notifier.items():
        if not path or path.endswith("/"):
            problems.append((number, f"notifier/{path}: name a file in hermes-conduit-notifier, "
                                     "not a directory."))
            continue
        if args.notifier_root:
            there = os.path.isfile(os.path.join(args.notifier_root, path))
        else:
            try:
                there = on_notifier_main(path)
            except Unreachable as error:
                print(f"::warning::Couldn't check hermes-conduit-notifier on GitHub ({error}); "
                      "its paths in the feature map weren't checked.")
                break
        if not there:
            problems.append((number, f"notifier/{path} isn't on hermes-conduit-notifier main. "
                                     "Point the entry at where that code lives now, or merge "
                                     "the notifier change first."))

    for number, problem in sorted(problems):
        print(f"::error file={MAP},line={number}::{problem}")
    if problems:
        return 1
    print(f"{MAP}: {len(entries(text))} entries, {len(found)} paths, all there.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
