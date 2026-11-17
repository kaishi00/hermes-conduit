#!/usr/bin/env python3
"""Fail on a hand-written `static func ==` in the app's Swift sources.

A type with a hand-written `==` makes adding any member to it (stored or
computed, even one nothing reads) recompile nearly the whole app: almost
every file uses `==`, and Swift resolves the operator across all of them.
Measured with Xcode 27.2 on 2026-11-17: 718 of 766 app files for one such
type; synthesized, 3-16 for the types measured. One PR touching such a
type (#2665) made the next Smoke builds recompile from scratch.

So let Swift synthesize `==`, and wrap a field that needs another comparison
in Conduit/Services/EquatableWrappers.swift's `@EqualityIgnored`,
`@IdentityEquatable` or `@OptionalIdentityEquatable`. Those wrappers keep
their own `==`; they are generic and never change, so they cost nothing.

ALLOWED lists the files that still hold one, and how many: the views
converted in a later PR, and types that can't take a wrapper yet. A file
over its allowance fails, and so does one under it, so the list only
shrinks.
"""

import argparse
import os
import re
import sys

SOURCE_DIRS = (
    "Conduit",
    "Shared",
    "ConduitWatch",
    "ConduitWidgets",
    "ConduitShareExtension",
    "ConduitNotificationService",
    "ConduitLocationPush",
)

WRAPPERS = "Conduit/Services/EquatableWrappers.swift"

# Path -> how many hand-written `==` it may still hold.
ALLOWED = {
    # Views: comparing only some inputs lets SwiftUI skip their bodies.
    # Converting them needs the compared inputs split from their @State,
    # @Environment and closures.
    "Conduit/Views/BotCapabilitiesView.swift": 1,
    "Conduit/Views/ChatView.swift": 6,
    "Conduit/Views/V2/V2ChatsView.swift": 1,
    "Conduit/Views/V2/V2ProjectPage.swift": 1,
    "Conduit/Views/V2/V2VoiceButton.swift": 1,
    # A class, compared by instance where views store it.
    "Conduit/Views/ChatRowDisclosure.swift": 1,
    # Enums whose payload compares another way (an id, NSArray equality),
    # and a struct whose cards compare through RichCard.
    "Conduit/Views/V2/V2Shell.swift": 1,
    "Conduit/Services/NativeAuthClient.swift": 1,
    "Conduit/Services/PresentedScreens.swift": 1,
    # Codable and shared with the widgets, which don't build the wrappers.
    "Shared/Widgets/WidgetSnapshot.swift": 1,
}

HAND_WRITTEN = re.compile(r"\bstatic\s+func\s+==\s*(<[^>]*>)?\s*\(")
STRING_START = re.compile(r'(#*)("""|")')
# The wrappers file holds exactly these, one per wrapper; a fourth there
# would be a type that slipped past the check.
WRAPPER_EQUALITIES = 3


def code_only(text):
    """`text` with Swift comments and string literals blanked to spaces
    (newlines kept), as the compiler reads them: a declaration in a comment
    or a string doesn't count, and one with a comment between its words
    does. Block comments nest; a string's interpolations stay code."""
    out = []
    i, n = 0, len(text)
    # Each entry: ("code", paren depth) or ("string", hashes, multiline).
    stack = [("code", 0)]

    def blank(segment):
        out.append("".join("\n" if ch == "\n" else " " for ch in segment))

    while i < n:
        mode = stack[-1]
        if mode[0] == "code":
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = n if end < 0 else end
                blank(text[i:end])
                i = end
            elif text.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if text.startswith("/*", j):
                        depth, j = depth + 1, j + 2
                    elif text.startswith("*/", j):
                        depth, j = depth - 1, j + 2
                    else:
                        j += 1
                blank(text[i:j])
                i = j
            else:
                m = STRING_START.match(text, i) if text[i] in '"#' else None
                if m and (m.group(1) or text[i] == '"'):
                    hashes, multiline = len(m.group(1)), m.group(2) == '"""'
                    blank(m.group(0))
                    i += len(m.group(0))
                    stack.append(("string", hashes, multiline))
                elif text[i] == "(":
                    stack[-1] = ("code", mode[1] + 1)
                    out.append("(")
                    i += 1
                elif text[i] == ")":
                    if mode[1] == 0 and len(stack) > 1:
                        stack.pop()  # an interpolation ends: back in its string
                        out.append(" ")
                    else:
                        stack[-1] = ("code", mode[1] - 1)
                        out.append(")")
                    i += 1
                else:
                    out.append(text[i])
                    i += 1
        else:
            _, hashes, multiline = mode
            closer = ('"""' if multiline else '"') + "#" * hashes
            escape = "\\" + "#" * hashes
            if text.startswith(closer, i):
                blank(closer)
                i += len(closer)
                stack.pop()
            elif text.startswith(escape + "(", i):
                blank(escape + "(")
                i += len(escape) + 1
                stack.append(("code", 0))
            elif text.startswith(escape, i) and i + len(escape) < n:
                blank(text[i:i + len(escape) + 1])
                i += len(escape) + 1
            elif text[i] == "\n" and not multiline:
                stack.pop()  # an unterminated string: the compiler rejects it anyway
                out.append("\n")
                i += 1
            else:
                blank(text[i])
                i += 1
    return "".join(out)


def count(text):
    return len(HAND_WRITTEN.findall(code_only(text)))


def find_problems(sources, allowed=None):
    allowed = ALLOWED if allowed is None else allowed
    problems = []
    counts = {path: count(text) for path, text in sources.items() if path != WRAPPERS}
    if WRAPPERS in sources and count(sources[WRAPPERS]) != WRAPPER_EQUALITIES:
        problems.append(
            f"{WRAPPERS}: {count(sources[WRAPPERS])} hand-written `static func ==`, expected "
            f"{WRAPPER_EQUALITIES} (one per wrapper). Only the generic wrappers go there."
        )
    for path in sorted(counts):
        found, limit = counts[path], allowed.get(path, 0)
        if found > limit:
            problems.append(
                f"{path}: {found} hand-written `static func ==` (allowed {limit}). Let Swift "
                f"synthesize it and wrap fields in {WRAPPERS}'s wrappers; a hand-written `==` "
                f"makes any new member of its type recompile nearly the whole app."
            )
        elif found < limit:
            problems.append(
                f"{path}: {found} hand-written `static func ==`, allowed {limit}: lower its entry "
                f"in scripts/check-hand-written-equality.py's ALLOWED (or drop it at 0)."
            )
    for path in sorted(set(allowed) - set(counts)):
        problems.append(f"{path}: listed in ALLOWED but not found; drop its entry.")
    return problems


def load_sources(repo_root):
    sources = {}
    for top in SOURCE_DIRS:
        for dirpath, _, files in os.walk(os.path.join(repo_root, top)):
            for name in files:
                if name.endswith(".swift"):
                    full = os.path.join(dirpath, name)
                    with open(full, encoding="utf-8") as f:
                        sources[os.path.relpath(full, repo_root).replace(os.sep, "/")] = f.read()
    return sources


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo-root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = parser.parse_args(argv)
    problems = find_problems(load_sources(args.repo_root))
    for problem in problems:
        print(problem)
    if problems:
        print(f"FAIL: {len(problems)} file(s) off the hand-written `==` allowance.")
        return 1
    print(f"OK: no new hand-written `static func ==` ({sum(ALLOWED.values())} left, in {len(ALLOWED)} files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
